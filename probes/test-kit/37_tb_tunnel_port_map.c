// Map a Thunderbolt-tunnelled USB device back to its physical USB-C port.
//
// Why this exists: when a Thunderbolt display or dock is connected (e.g. an
// Apple Studio Display), the USB devices behind it (mouse, keyboard, hub) do
// NOT sit under the native Apple Silicon USB bus for that port. They arrive over
// the Thunderbolt PCIe tunnel and surface under a tunnelled host controller,
// `AppleUSBXHCITR`, in a separate registry subtree with no `UsbIOPort` ancestor.
// So WhatCable's normal device->port correlation (probe 36's locationID match,
// plus the `UsbIOPort` walk) misses them entirely, and the device is orphaned
// (public issue #274, AORUS / Studio Display reports).
//
// The join that DOES tie them to a port runs through the Thunderbolt fabric, not
// the USB tree. Apple Silicon exposes each Thunderbolt port as two sibling
// `AppleARMIODevice` roots that share an index N:
//
//     apciecN@...   the PCIe-C tunnel   (hosts AppleUSBXHCITR -> tunnelled USB)
//     acioN@...     the Thunderbolt HAL (hosts the host IOThunderboltSwitch)
//
// The host switch under acioN carries a `UID`, which is the same value WhatCable
// already computes per port as `thunderboltSwitchUID`. So the attribution chain
// is: tunnelled device -> AppleUSBXHCITR -> apciecN  ==(by index)==  acioN ->
// host switch UID -> the Port-USB-C@N whose thunderboltSwitchUID matches.
//
// This was confirmed end to end on ONE 2-port laptop (issue #274 dump). It is
// NOT yet proven on 3-4 port Macs (Studio / Pro / larger MBP), and the existing
// test-kit probes don't capture the apciec/acio/XHCITR side at all. This probe
// captures exactly that subtree as raw data:
//
//   1. apciecN roots          (via ApplePCIECHostBridge paths)   - idle-safe
//   2. acioN roots + host UID  (via IOThunderboltSwitch)          - idle-safe
//   3. tunnelled controllers   (AppleUSBXHCITR path + locationID) - when attached
//   4. tunnelled USB devices   (IOUSBHostDevice under a TR)       - when attached
//
// Sections 1+2 confirm the apciecN<->acioN index pairing even with nothing
// plugged in; 3+4 confirm the device->port chain end to end when a TB dock or
// display is attached. Pairing is by index N, parsed offline from the paths; do
// not assume it here. No serial numbers or EDID are read (model name only).
//
// Compile: clang -framework IOKit -framework CoreFoundation -o 37_tb_tunnel_port_map 37_tb_tunnel_port_map.c

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>

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

// The IOService-plane path. Starts at the plane root, so the apciecN / acioN
// token sits near the front and survives truncation of a long path.
static void readPath(io_service_t s, char *buf, size_t n) {
    io_string_t path = {0};
    if (IORegistryEntryGetPath(s, kIOServicePlane, path) == KERN_SUCCESS) {
        snprintf(buf, n, "%s", path);
    } else {
        snprintf(buf, n, "(path unavailable)");
    }
}

// True if any ancestor in the IOService plane is an AppleUSBXHCITR controller,
// i.e. this device arrived over a Thunderbolt PCIe tunnel rather than the native
// USB bus. Walks up to the plane root, releasing each node on the way (no leak on
// any exit path, including loop exhaustion).
static int hasTunnelAncestor(io_service_t s) {
    io_service_t cur = s;
    IOObjectRetain(cur);
    int tunnelled = 0;
    for (int depth = 0; depth < 64; depth++) {
        io_service_t parent = 0;
        kern_return_t kr = IORegistryEntryGetParentEntry(cur, kIOServicePlane, &parent);
        IOObjectRelease(cur);
        if (kr != KERN_SUCCESS || !parent) { cur = 0; break; }
        cur = parent;
        io_name_t name = {0};
        IORegistryEntryGetName(cur, name);
        if (strstr(name, "XHCITR")) { tunnelled = 1; break; }
    }
    if (cur) IOObjectRelease(cur);
    return tunnelled;
}

// Print name + path for every instance of a class. Used for the idle-safe
// structural roots (PCIe-C bridges -> apciecN, TB switches -> acioN). Returns the
// number of instances printed so callers can report "(none)" across several
// candidate class names. Does not print "(none)" itself.
static int dumpPaths(const char *cls, int withUID) {
    io_iterator_t iter;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching(cls), &iter) != KERN_SUCCESS) {
        return 0;
    }
    io_service_t s;
    int n = 0;
    while ((s = IOIteratorNext(iter))) {
        io_name_t name = {0};
        IORegistryEntryGetName(s, name);
        char path[1024];
        readPath(s, path, sizeof(path));
        if (withUID) {
            long long uid = readNumber(s, CFSTR("UID"));
            printf("  %-28s UID=%llu (0x%llx)\n      %s\n",
                   name, (unsigned long long)uid, (unsigned long long)uid, path);
        } else {
            printf("  %-28s %s\n", name, path);
        }
        n++;
        IOObjectRelease(s);
    }
    if (n > 0 && !IOIteratorIsValid(iter))
        printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
    IOObjectRelease(iter);
    return n;
}

// ===========================================================================
// Appended 2026-07 (probe-uuid audit): HPM controller UUID map, copied from
// probe 35 (35_hpm_port_uuid.c). @N alone is confirmed unreliable as a
// cross-subsystem join key (base M4/M5: HPM @1/@2/@4 vs xHCI 1/2/3, see
// research/cross-class-identifiers.md #3), so this section captures the HPM
// side of a UUID-canonical join in the SAME probe run as the TB-fabric data
// above. Kept as a self-contained copy since these probes are standalone
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

int main(void) {
    printf("=== Thunderbolt-tunnelled USB -> physical port map (issue #274) ===\n");
    printf("Pair apciecN with acioN by index N (offline). Host-switch UID matches WhatCable's per-port thunderboltSwitchUID. Tunnelled devices live under AppleUSBXHCITR, not the native bus.\n\n");

    // 1. PCIe-C tunnel roots. Paths contain apciecN@... (idle-safe).
    printf("--- PCIe-C host bridges (-> apciecN tunnel root) ---\n");
    if (dumpPaths("ApplePCIECHostBridge", 0) == 0) printf("  (none)\n");

    // 2. Thunderbolt switches. Host switches carry the UID and sit under acioN
    //    (idle-safe); a nested switch is an attached dock/display. Paths show
    //    which is which by depth. Apple uses the class prefix `IOIOThunderboltSwitch*`
    //    on some Macs/macOS (older, e.g. Type5) and `IOThunderboltSwitch*` on others
    //    (M5 / macOS 26, Type7), so match BOTH or the host UID goes missing on half
    //    the fleet (mirrors IOIOThunderboltSwitchWatcher.matchClasses).
    printf("\n--- IOThunderboltSwitch (host switch UID -> acioN root; nested = attached device) ---\n");
    {
        int n = dumpPaths("IOIOThunderboltSwitch", 1);
        n += dumpPaths("IOThunderboltSwitch", 1);
        if (n == 0) printf("  (none)\n");
    }

    // 3. Tunnelled USB host controllers. Present only with a TB device attached.
    printf("\n--- AppleUSBXHCITR (tunnelled USB host controllers) ---\n");
    {
        io_iterator_t iter;
        if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                         IOServiceMatching("AppleUSBXHCITR"), &iter) == KERN_SUCCESS) {
            io_service_t s;
            int n = 0;
            while ((s = IOIteratorNext(iter))) {
                long long loc = readNumber(s, CFSTR("locationID"));
                char path[1024];
                readPath(s, path, sizeof(path));
                printf("  locationID=%lld (0x%llx)\n      %s\n",
                       loc, (unsigned long long)loc, path);
                n++;
                IOObjectRelease(s);
            }
            if (n == 0) printf("  (none - no Thunderbolt-tunnelled USB controller active)\n");
            if (n > 0 && !IOIteratorIsValid(iter))
                printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
            IOObjectRelease(iter);
        }
    }

    // 4. Tunnelled USB devices: those with an AppleUSBXHCITR ancestor. Match a
    //    device's path/locationID back to a controller above, and the controller's
    //    apciecN to an acioN host-switch UID, to close device -> port.
    printf("\n--- Tunnelled USB devices (IOUSBHostDevice under a TR controller) ---\n");
    {
        io_iterator_t iter;
        int tunnelled = 0, total = 0;
        if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                         IOServiceMatching("IOUSBHostDevice"), &iter) == KERN_SUCCESS) {
            io_service_t s;
            while ((s = IOIteratorNext(iter))) {
                total++;
                if (hasTunnelAncestor(s)) {
                    tunnelled++;
                    long long loc = readNumber(s, CFSTR("locationID"));
                    char product[256];
                    if (!readString(s, CFSTR("USB Product Name"), product, sizeof(product)) || !product[0]) {
                        io_name_t nm = {0};
                        IORegistryEntryGetName(s, nm);
                        snprintf(product, sizeof(product), "%s", nm);
                    }
                    char path[1024];
                    readPath(s, path, sizeof(path));
                    printf("  locationID=%lld (0x%llx)  %s\n      %s\n",
                           loc, (unsigned long long)loc, product, path);
                }
                IOObjectRelease(s);
            }
            if (total > 0 && !IOIteratorIsValid(iter))
                printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
            IOObjectRelease(iter);
        }
        if (tunnelled == 0) printf("  (none - no devices behind a Thunderbolt tunnel)\n");
        printf("\n  (%d of %d connected USB devices are tunnelled)\n", tunnelled, total);
    }

    // Appended 2026-07: HPM UUID map (side-table join by @N).
    dumpHPMUUIDMap();

    // Appended 2026-07: negative finding from the same audit. Unlike probe
    // 36's xHCI ports (which carry a "UsbIOPort" property pointing straight
    // at the matching HPM node), nothing in this Thunderbolt subtree
    // (ApplePCIECHostBridge / IOThunderboltSwitch / IOThunderboltPort /
    // AppleUSBXHCITR) carries an equivalent cross-tree reference, and a
    // plain ancestor walk from any of them never reaches an AppleHPM* node
    // either: confirmed via ioreg on this Mac (M5 Pro, macOS 26.5.1) that
    // the TB fabric (apciecN / acioN) and the HPM ports (nub-spmi-*) are
    // sibling subtrees under arm-io/AppleSoCIO, not parent/child. So no
    // per-record HPM UUID join is possible from this side; the only bridge
    // is the existing numeric one (TB Socket ID == HPM Port-USB-C@N),
    // cross-checked against the HPM UUID map above by @N.
    printf("\n=== HPM ancestor-join investigation (2026-07 probe-uuid audit) ===\n");
    printf("No per-record HPM UUID join found from this subtree: no UsbIOPort-style\n");
    printf("cross-tree property exists here, and a plain ancestor walk from any TB\n");
    printf("node never reaches an AppleHPM* node (sibling subtrees, not parent/child,\n");
    printf("confirmed via ioreg). Bridge to HPM stays the numeric one: TB Socket ID\n");
    printf("== HPM Port-USB-C@N, cross-checked against the HPM UUID map above.\n");

    return 0;
}
