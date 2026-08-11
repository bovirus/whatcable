// Map each USB host-controller port to its physical USB-C port number and
// locationID, so a USB device can be tied to the physical port it sits on.
//
// Why this exists: WhatCable correlates a connected USB device to its physical
// port today with string matching plus a bus index, which has documented edge
// cases. The macOS USB topology key `locationID` is shared across the whole USB
// device stack (host device, interface, hub, and the host-controller port), so
// a device can be tied to its host-controller port reliably:
//
//     IOUSBHostDevice.locationID  ->  AppleUSB*XHCIARMPort.locationID  (same base)
//
// The host-controller port also carries `usb-c-port-number`, the physical port
// index from the USB subsystem's point of view. IMPORTANT: this is NOT
// guaranteed to equal the HPM `Port-USB-C@N` number; the two subsystems can
// number the same physical ports differently (seen on M3+: XHCI 1/2/3 vs HPM
// @1/@2/@4). So this probe captures both numbering schemes as raw data; the
// real XHCI<->HPM correlation has to be worked out by comparing this probe with
// probe 35, not assumed. Probe 35 closes the power->port half (HPM UUID == SMC
// DxUI); this probe captures the device->port half plus the numbering data
// needed to bridge to the HPM side (the XHCI port tree is in no other probe).
//
// Compile: clang -framework IOKit -framework CoreFoundation -o 36_xhci_port_map 36_xhci_port_map.c

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>

// usb-c-port-number is stored as little-endian CFData (e.g. <01000000> = 1).
// Handle the CFNumber form too, defensively. Returns -1 if absent/unreadable.
static long long readPortNumber(io_service_t s, CFStringRef key) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    long long out = -1;
    if (v) {
        CFTypeID t = CFGetTypeID(v);
        if (t == CFDataGetTypeID()) {
            CFIndex len = CFDataGetLength(v);
            const UInt8 *b = CFDataGetBytePtr(v);
            out = 0;
            for (CFIndex i = 0; i < len && i < 8; i++) {
                out |= ((long long)b[i]) << (8 * i);
            }
        } else if (t == CFNumberGetTypeID()) {
            CFNumberGetValue(v, kCFNumberLongLongType, &out);
        }
        CFRelease(v);
    }
    return out;
}

// Read a CFNumber property as long long. Returns -1 if absent.
static long long readNumber(io_service_t s, CFStringRef key) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    long long out = -1;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
        CFNumberGetValue(v, kCFNumberLongLongType, &out);
    }
    if (v) CFRelease(v);
    return out;
}

// Copy a CFString property into buf. Returns 1 on success.
static int readString(io_service_t s, CFStringRef key, char *buf, size_t n) {
    buf[0] = '\0';
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    int ok = 0;
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
        ok = CFStringGetCString(v, buf, n, kCFStringEncodingUTF8) ? 1 : 0;
    }
    if (v) CFRelease(v);
    return ok;
}

// Print the host-controller ports for one class: name, physical USB-C port
// number, and locationID.
static void dumpPorts(const char *cls) {
    io_iterator_t iter;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching(cls), &iter) != KERN_SUCCESS) {
        printf("  (%s: match failed)\n", cls);
        return;
    }
    io_service_t s;
    int n = 0;
    while ((s = IOIteratorNext(iter))) {
        io_name_t name = {0};
        IORegistryEntryGetName(s, name);
        long long portNum = readPortNumber(s, CFSTR("usb-c-port-number"));
        long long loc = readNumber(s, CFSTR("locationID"));
        printf("  %-24s usb-c-port-number=%lld  locationID=%lld (0x%llx)\n",
               name, portNum, loc, (unsigned long long)loc);
        n++;
        IOObjectRelease(s);
    }
    if (n == 0) printf("  (%s: none)\n", cls);
    if (n > 0 && !IOIteratorIsValid(iter))
        printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
    IOObjectRelease(iter);
}

// ===========================================================================
// Appended 2026-07 (probe-uuid audit): HPM controller UUID map, copied from
// probe 35 (35_hpm_port_uuid.c). @N alone is confirmed unreliable as a
// cross-subsystem join key (base M4/M5: HPM @1/@2/@4 vs xHCI 1/2/3, see
// research/cross-class-identifiers.md #3), so this section captures the HPM
// side of a UUID-canonical join in the SAME probe run as the xHCI data
// above, rather than relying on two separate probe captures to agree.
// Kept as a self-contained copy since these probes are standalone
// single-file programs.
// ===========================================================================

// Copy of probe 35's readStringProp. Named distinctly from this file's
// existing readString() (different signature/behaviour is not the reason;
// keeping probe 35's logic byte-for-byte identical is).
static int readStringProp(io_service_t s, CFStringRef key, char *buf, size_t n) {
    buf[0] = '\0';
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    int ok = 0;
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
        ok = CFStringGetCString(v, buf, n, kCFStringEncodingUTF8) ? 1 : 0;
    }
    if (v) CFRelease(v);
    return ok;
}

// Walk descendants looking for a "Description" property that contains "@",
// e.g. "Port-USB-C@1/CC". Copy of probe 35's helper (same name/behaviour).
static int findDescriptionWithLocation(io_service_t service, int depth, char *out, size_t n) {
    if (depth > 4) return 0;

    char desc[256];
    if (readStringProp(service, CFSTR("Description"), desc, sizeof(desc))) {
        if (strchr(desc, '@') != NULL) {
            char *slash = strchr(desc, '/');
            if (slash) *slash = '\0';
            snprintf(out, n, "%s", desc);
            return 1;
        }
    }

    io_iterator_t childIter;
    if (IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIter) == KERN_SUCCESS) {
        io_service_t child;
        int found = 0;
        int sawAny = 0;
        while ((child = IOIteratorNext(childIter))) {
            sawAny = 1;
            if (!found && findDescriptionWithLocation(child, depth + 1, out, n)) {
                found = 1;
            }
            IOObjectRelease(child);
        }
        if (sawAny && !IOIteratorIsValid(childIter))
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(childIter);
        if (found) return 1;
    }
    return 0;
}

// Inspect a controller's child port. Copy of probe 35's resolvePort.
static void resolvePort(io_service_t hpm, char *label, size_t labelN,
                        char *connUUID, size_t connN) {
    snprintf(label, labelN, "(no port child)");
    snprintf(connUUID, connN, "(none)");

    io_iterator_t childIter;
    if (IORegistryEntryGetChildIterator(hpm, kIOServicePlane, &childIter) != KERN_SUCCESS) {
        return;
    }

    io_service_t child;
    int sawAny = 0;
    while ((child = IOIteratorNext(childIter))) {
        sawAny = 1;
        io_name_t name = {0};
        if (IORegistryEntryGetName(child, name) != KERN_SUCCESS) {
            IOObjectRelease(child);
            continue;
        }
        if (strncmp(name, "Port-", 5) == 0) {
            io_name_t loc = {0};
            IORegistryEntryGetLocationInPlane(child, kIOServicePlane, loc);
            if (loc[0] != '\0') {
                snprintf(label, labelN, "%s@%s", name, loc);
            } else if (!findDescriptionWithLocation(child, 0, label, labelN)) {
                snprintf(label, labelN, "%s", name);
            }
            char cu[128] = {0};
            if (readStringProp(child, CFSTR("ConnectionUUID"), cu, sizeof(cu)) && cu[0]) {
                snprintf(connUUID, connN, "%s", cu);
            }
            IOObjectRelease(child);
            IOObjectRelease(childIter);
            return;
        }
        IOObjectRelease(child);
    }
    if (sawAny && !IOIteratorIsValid(childIter))
        printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
    IOObjectRelease(childIter);
}

// Print, for every HPM port controller: class name, @N suffix, and UUID.
static void dumpHPMUUIDMap(void) {
    printf("\n=== HPM UUID map ===\n");
    printf("Per-port-controller join key for cross-subsystem port correlation.\n");
    printf("class=controller class  port=@N service name  UUID=stable per-port id (M3+).\n\n");

    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("AppleHPMDevice"),
        &iter);
    if (kr != KERN_SUCCESS) {
        printf("(no AppleHPMDevice found, kr=0x%x)\n", kr);
        return;
    }

    io_service_t hpm;
    int idx = 0;
    while ((hpm = IOIteratorNext(iter))) {
        io_name_t cls = {0};
        IOObjectGetClass(hpm, cls);

        char uuid[128] = "(none)";
        readStringProp(hpm, CFSTR("UUID"), uuid, sizeof(uuid));

        char portLabel[160], connUUID[128];
        resolvePort(hpm, portLabel, sizeof(portLabel), connUUID, sizeof(connUUID));

        printf("[%d] class=%-24s port=%-18s UUID=%s\n", idx, cls, portLabel, uuid);
        idx++;
        IOObjectRelease(hpm);
    }
    if (idx > 0 && !IOIteratorIsValid(iter))
        printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
    IOObjectRelease(iter);

    if (idx == 0) printf("(no power controllers matched)\n");
}

// ---------------------------------------------------------------------
// Per-record join: resolve each xHCI port's own "UsbIOPort" property (a
// full IOService-plane path string, confirmed present on this Mac via
// `ioreg -c AppleUSB30XHCIARMPort -r -l`) to the exact HPM Port-USB-C@N
// node it names, then take ONE step to that node's parent, the
// AppleHPMDeviceHALType3 controller, and read its UUID. This is a
// per-record join straight off the xHCI port, stronger than the side-table
// above matched by port number, because it needs no numbering agreement
// between the two subsystems at all.
//
// Investigated on this Mac (M5 Pro, macOS 26.5.1) before writing this: a
// plain ancestor walk (IORegistryEntryGetParentEntry, no property lookup)
// from an xHCI port node never reaches an AppleHPM* node. The xHCI port
// lives under arm-io/AppleSoCIO/usb-drd*, a sibling subtree to the HPM
// port under arm-io/AppleSoCIO/nub-spmi-*; they share a common ancestor
// several levels up the tree, not a parent/child relationship. UsbIOPort is
// a stored cross-tree path reference, not registry nesting, so
// IORegistryEntryFromPath (not a parent walk) is what actually bridges it.
// ---------------------------------------------------------------------
static void dumpUsbIOPortHPMJoin(const char *cls) {
    io_iterator_t iter;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching(cls), &iter) != KERN_SUCCESS) {
        printf("  (%s: match failed)\n", cls);
        return;
    }
    io_service_t s;
    int n = 0;
    while ((s = IOIteratorNext(iter))) {
        io_name_t name = {0};
        IORegistryEntryGetName(s, name);

        char usbIOPort[512] = "(none)";
        int hasPath = readStringProp(s, CFSTR("UsbIOPort"), usbIOPort, sizeof(usbIOPort));

        char hpmUUID[128] = "(none)";
        char hpmClass[128] = "(none)";
        if (hasPath && usbIOPort[0]) {
            io_registry_entry_t portNode = IORegistryEntryFromPath(kIOMainPortDefault, usbIOPort);
            if (portNode) {
                io_registry_entry_t hpmController = 0;
                if (IORegistryEntryGetParentEntry(portNode, kIOServicePlane, &hpmController) == KERN_SUCCESS
                    && hpmController) {
                    io_name_t cname = {0};
                    IOObjectGetClass(hpmController, cname);
                    snprintf(hpmClass, sizeof(hpmClass), "%s", cname);
                    readStringProp(hpmController, CFSTR("UUID"), hpmUUID, sizeof(hpmUUID));
                    IOObjectRelease(hpmController);
                }
                IOObjectRelease(portNode);
            } else {
                snprintf(hpmUUID, sizeof(hpmUUID), "(path unresolved)");
            }
        }

        printf("  %-24s UsbIOPort=%s\n      HPM-class=%s  HPM-UUID=%s\n",
               name, hasPath ? usbIOPort : "(none)", hpmClass, hpmUUID);
        n++;
        IOObjectRelease(s);
    }
    if (n == 0) printf("  (%s: none)\n", cls);
    if (n > 0 && !IOIteratorIsValid(iter))
        printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
    IOObjectRelease(iter);
}

int main(void) {
    printf("=== USB host-controller port -> physical USB-C port map ===\n");
    printf("device locationID -> XHCI port locationID (solid). usb-c-port-number may differ from HPM @N (probe 35); compare, do not assume equal.\n\n");

    printf("AppleUSB30XHCIARMPort (USB3 / SuperSpeed):\n");
    dumpPorts("AppleUSB30XHCIARMPort");
    printf("\nAppleUSB20XHCIARMPort (USB2):\n");
    dumpPorts("AppleUSB20XHCIARMPort");

    // Connected devices, so the bridge can be checked end to end from this one
    // probe: match a device's locationID base to a port above.
    printf("\nIOUSBHostDevice (connected devices, match locationID to a port above):\n");
    io_iterator_t iter;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching("IOUSBHostDevice"), &iter) == KERN_SUCCESS) {
        io_service_t s;
        int n = 0;
        while ((s = IOIteratorNext(iter))) {
            long long loc = readNumber(s, CFSTR("locationID"));
            char product[256];
            if (!readString(s, CFSTR("USB Product Name"), product, sizeof(product)) || !product[0]) {
                io_name_t nm = {0};
                IORegistryEntryGetName(s, nm);
                snprintf(product, sizeof(product), "%s", nm);
            }
            printf("  locationID=%lld (0x%llx)  %s\n", loc, (unsigned long long)loc, product);
            n++;
            IOObjectRelease(s);
        }
        if (n == 0) printf("  (none connected)\n");
        if (n > 0 && !IOIteratorIsValid(iter))
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(iter);
    }

    // Appended 2026-07: HPM UUID map (side-table join by @N), plus the
    // stronger per-record join resolved straight off each xHCI port's own
    // UsbIOPort property.
    dumpHPMUUIDMap();

    printf("\n=== XHCI port -> HPM UUID via UsbIOPort (per-record ancestor join) ===\n");
    printf("AppleUSB30XHCIARMPort (USB3 / SuperSpeed):\n");
    dumpUsbIOPortHPMJoin("AppleUSB30XHCIARMPort");
    printf("\nAppleUSB20XHCIARMPort (USB2):\n");
    dumpUsbIOPortHPMJoin("AppleUSB20XHCIARMPort");

    return 0;
}
