// Capture the IOUSB device tree with the ancestor walk WhatCable's classifier
// actually consumes, so the "which device shows, and where" logic can be
// replayed offline against real machines.
//
// Why this exists: WhatCable decides where each USB device appears (under a
// physical port, behind a Thunderbolt dock, or on a desktop front panel) in
// USBWatcher.controllerInfo, which walks UP the IOService plane from each
// IOUSBHostDevice to its host controller, reading the class name, USBPortType,
// and UsbIOPort of every ancestor along the way. The existing probes dump
// device properties flat and throw that ancestor chain away, so the
// classification can never be tested against real hardware. This probe records,
// for every connected USB device, the exact ancestor walk the classifier reads:
//
//     device -> hub(s) -> ... -> host controller (AppleT*USBXHCI / AppleUSBXHCITR
//                                / dock XHCI)
//
// With this, an offline replay can reconstruct reachedNativeController,
// tunnelled, portName, and hubPortType and run the real classifier, plus rebuild
// the device tree from the locationIDs. Property keys mirror USBWatcher exactly
// (idVendor, idProduct, locationID, Device Speed, bDeviceClass, USB Product /
// Vendor Name, USB Serial Number; UsbIOPort and USBPortType on ancestors).
//
// The serial is captured because USBWatcher reads it into USBDevice.serialNumber:
// omitting it meant this fixture could not replay a field production populates.
// It identifies a peripheral, not a person, and it is the only thing separating
// two identical devices (same VID/PID) on one machine.
//
// Compile: clang -framework IOKit -framework CoreFoundation -o 38_usb_device_tree 38_usb_device_tree.c

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

// Read a CFNumber property as long long. Returns sentinel if absent.
static long long readNumber(io_service_t s, CFStringRef key, long long sentinel) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    long long out = sentinel;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
        CFNumberGetValue(v, kCFNumberLongLongType, &out);
    }
    if (v) CFRelease(v);
    return out;
}

// Copy a CFString property into buf. Returns 1 on success, 0 if absent.
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

// Read UsbIOPort, which macOS stores as either a CFString or UTF-8 CFData
// (the path tail "Port-USB-C@N" is what matters). Returns 1 if present.
static int readUsbIOPort(io_service_t s, char *buf, size_t n) {
    buf[0] = '\0';
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, CFSTR("UsbIOPort"), kCFAllocatorDefault, 0);
    int ok = 0;
    if (v) {
        CFTypeID t = CFGetTypeID(v);
        if (t == CFStringGetTypeID()) {
            ok = CFStringGetCString(v, buf, n, kCFStringEncodingUTF8) ? 1 : 0;
        } else if (t == CFDataGetTypeID()) {
            CFIndex len = CFDataGetLength(v);
            if (len > 0) {
                if ((size_t)len >= n) len = n - 1;
                memcpy(buf, CFDataGetBytePtr(v), len);
                buf[len] = '\0';
                ok = 1;
            }
        }
        CFRelease(v);
    }
    return ok;
}

// Print the ancestor walk for one device: every IOService-plane parent up to
// the host controller, capturing the fields the classifier reads. Bounded at 20
// hops to match USBWatcher.controllerInfo and guard against a cyclic registry.
static void dumpAncestors(io_service_t device) {
    printf("  Ancestors (device -> controller):\n");
    io_service_t current = device;
    IOObjectRetain(current);
    for (int hop = 0; hop < 20; hop++) {
        io_service_t parent = 0;
        if (IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) != KERN_SUCCESS) {
            IOObjectRelease(current);
            current = 0;
            break;
        }
        IOObjectRelease(current);
        current = parent;

        io_name_t cls = {0};
        IOObjectGetClass(current, cls);

        long long loc = readNumber(current, CFSTR("locationID"), -1);
        long long portType = readNumber(current, CFSTR("USBPortType"), -1);
        // The classifier only honours USBPortType on nodes conforming to
        // IOUSBHostDevice (the hubs and devices). Record that gate explicitly
        // so an offline replay never has to infer it from the class name:
        // today only the exact class "IOUSBHostDevice" carries the key
        // (766/766 ancestor lines across the corpus), but a subclass could.
        int usbHostDevice = IOObjectConformsTo(current, "IOUSBHostDevice") ? 1 : 0;
        // 512 so a deep nested-hub UsbIOPort path is never truncated: the
        // classifier reads the "Port-*" tail, which a short buffer could drop.
        char ioPort[512];
        int hasPort = readUsbIOPort(current, ioPort, sizeof(ioPort));

        // Registry entry ID (Stage B v2): unique per boot, never reused, and
        // the instance-identity half of the PCI-Path-prefix join
        // (planning/pcie-tunnelled-usb-attribution.md). Cheap: one IOKit
        // call, same cost class as the properties already read here.
        uint64_t entryID = 0;
        int hasEntryID = IORegistryEntryGetRegistryEntryID(current, &entryID) == KERN_SUCCESS;

        // UsbIOPort stays the LAST token on purpose: its value is a registry
        // path, so a parser that takes the rest of the line after "UsbIOPort="
        // must keep working. New tokens (entryID included) go before it,
        // never after.
        printf("    [%d] class=%s", hop, cls);
        if (loc >= 0) printf(" locationID=0x%llx", (unsigned long long)loc);
        if (portType >= 0) printf(" USBPortType=%lld", portType);
        if (usbHostDevice) printf(" usbHostDevice=1");
        if (hasEntryID) printf(" entryID=%llu", (unsigned long long)entryID);
        if (hasPort && ioPort[0]) printf(" UsbIOPort=%s", ioPort);
        printf("\n");

        // Stop at the host controller, mirroring USBWatcher.classifyAncestry's
        // stop BOUNDARY so an offline replay reaches the same node production
        // does:
        //   tunnel = AppleUSBXHCITR prefix
        //   native = AppleT* prefix AND ends with "USBXHCI" (so the M5 Pro/Max
        //            AppleT6050USBXHCIAUSS, which does NOT end in USBXHCI, is not
        //            treated as native, exactly as production)
        //   dock   = contains "USBXHCI" and is none of AppleT* / AppleUSBXHCITR /
        //            AppleIntel*
        // Swift splits this dock bucket further (AppleEmbedded* = the Mac's own
        // built-in wiring, discussion #417), but the union of stop classes is
        // identical, which is all the replay cross-check needs. The probe
        // deliberately records the boundary, not the category.
        const char *c = cls;
        size_t clen = strlen(c);
        int hasXHCI = strstr(c, "USBXHCI") != NULL;
        int endsXHCI = clen >= 7 && strcmp(c + clen - 7, "USBXHCI") == 0;
        int isTunnel = strncmp(c, "AppleUSBXHCITR", 14) == 0;
        int isNative = strncmp(c, "AppleT", 6) == 0 && endsXHCI;
        int isDock = hasXHCI
            && strncmp(c, "AppleT", 6) != 0
            && strncmp(c, "AppleUSBXHCITR", 14) != 0
            && strncmp(c, "AppleIntel", 10) != 0;
        if (isTunnel || isNative || isDock) {
            // Tunnel continuation, mirroring USBWatcher.walkContinuation: for
            // the native USB tunnel (AppleUSBXHCITR) AND a dock-supplied PCIe
            // xHCI (the dock bucket minus AppleEmbedded*, the Mac's own
            // board-mounted controllers), keep walking to the apciecN PCIe-C
            // host bridge root, printing each hop's IOService NAME (the
            // classifier counts "pci-bridge" names and stops at strict
            // "apciec"+digits). This is what lets a replay compute
            // tunnelBridgeDepth/tunnelRootName for FL1100-class controllers,
            // the LG UltraFine case; before this the probe stopped here and
            // the bridge chain above dock controllers was never captured.
            //
            // FORMAT: continuation rows keep the "[N]" numbering and stay
            // ABOVE the "(reached host controller: ...)" marker, because the
            // replay parsers treat that marker as the end of the ancestor
            // section (review finding); a "name=" token carries the
            // IOService name the classifier reads. The marker still ends the
            // block and still names the CONTROLLER class, exactly as before,
            // so pre-existing parsers of old captures are unaffected.
            int isEmbedded = strncmp(c, "AppleEmbedded", 13) == 0 && hasXHCI;
            char controllerClass[sizeof(io_name_t)];
            strlcpy(controllerClass, cls, sizeof(controllerClass));

            // Capture-timing rule (Stage B v2): save the controller's OWN
            // registry path HERE, before the continuation loop below
            // advances `current` toward apciecN. Printed after the
            // "(reached host controller: ...)" token so parsers that don't
            // expect it are unaffected (append-only format change).
            // io_string_t is 512 bytes, plenty for any registry path seen
            // in the corpus.
            io_string_t controllerPath = {0};
            int hasControllerPath = IORegistryEntryGetPath(current, kIOServicePlane, controllerPath) == KERN_SUCCESS;

            if ((isTunnel || isDock) && !isEmbedded) {
                for (int extra = 0; extra < 20; extra++) {
                    io_service_t bridgeParent = 0;
                    if (IORegistryEntryGetParentEntry(current, kIOServicePlane, &bridgeParent) != KERN_SUCCESS) break;
                    IOObjectRelease(current);
                    current = bridgeParent;
                    io_name_t bcls = {0};
                    IOObjectGetClass(current, bcls);
                    io_name_t bname = {0};
                    IORegistryEntryGetName(current, bname);
                    uint64_t bridgeEntryID = 0;
                    int hasBridgeEntryID = IORegistryEntryGetRegistryEntryID(current, &bridgeEntryID) == KERN_SUCCESS;
                    printf("    [%d] class=%s name=%s", hop + 1 + extra, bcls, bname);
                    if (hasBridgeEntryID) printf(" entryID=%llu", (unsigned long long)bridgeEntryID);
                    printf("\n");
                    // Strict apciec + digits, matching RegistryRootNaming.
                    if (strncmp(bname, "apciec", 6) == 0) {
                        const char *digits = bname + 6;
                        int allDigits = digits[0] != '\0';
                        for (const char *d = digits; *d; d++) {
                            if (*d < '0' || *d > '9') { allDigits = 0; break; }
                        }
                        if (allDigits) break;
                    }
                }
            }
            printf("    (reached host controller: %s)", controllerClass);
            if (hasControllerPath) printf(" path=%s", controllerPath);
            printf("\n");
            IOObjectRelease(current);
            current = 0;
            break;
        }
    }
    if (current) IOObjectRelease(current);
}

int main(void) {
    printf("=== USB device tree (per-device ancestor walk for classification replay) ===\n");
    printf("Mirrors USBWatcher.controllerInfo: each device, then its IOService-plane\n");
    printf("ancestors up to the host controller, with class / USBPortType / UsbIOPort.\n\n");

    io_iterator_t iter;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching("IOUSBHostDevice"), &iter) != KERN_SUCCESS) {
        printf("(IOUSBHostDevice match failed)\n");
        return 0;
    }

    io_service_t s;
    int n = 0;
    while ((s = IOIteratorNext(iter))) {
        char product[256], vendor[256], serial[256];
        if (!readString(s, CFSTR("USB Product Name"), product, sizeof(product)) || !product[0]) {
            io_name_t nm = {0};
            IORegistryEntryGetName(s, nm);
            snprintf(product, sizeof(product), "%s", nm);
        }
        if (!readString(s, CFSTR("USB Vendor Name"), vendor, sizeof(vendor))) vendor[0] = '\0';
        if (!readString(s, CFSTR("USB Serial Number"), serial, sizeof(serial))) serial[0] = '\0';

        long long loc   = readNumber(s, CFSTR("locationID"), -1);
        long long vid   = readNumber(s, CFSTR("idVendor"), -1);
        long long pid   = readNumber(s, CFSTR("idProduct"), -1);
        long long speed = readNumber(s, CFSTR("Device Speed"), -1);
        long long klass = readNumber(s, CFSTR("bDeviceClass"), -1);
        // The device's OWN USBPortType (the kind of port it is plugged
        // into). The classifier uses it to tell the Mac's own hub silicon
        // (value 2, internal board port) from user-attached devices on an
        // embedded controller. -1 when absent; older captures lack this
        // line, and the sweep then derives hub values from ancestor rows.
        long long ownPT = readNumber(s, CFSTR("USBPortType"), -1);

        printf("--- Device[%d] ---\n", n);
        printf("  USB Product Name = \"%s\"\n", product);
        printf("  USB Vendor Name = \"%s\"\n", vendor);
        printf("  USB Serial Number = \"%s\"\n", serial);
        printf("  locationID = 0x%llx\n", (unsigned long long)(loc < 0 ? 0 : loc));
        printf("  idVendor = 0x%llx\n", (unsigned long long)(vid < 0 ? 0 : vid));
        printf("  idProduct = 0x%llx\n", (unsigned long long)(pid < 0 ? 0 : pid));
        printf("  Device Speed = %lld\n", speed);
        printf("  bDeviceClass = %lld\n", klass);
        if (ownPT >= 0) printf("  USBPortType = %lld\n", ownPT);
        dumpAncestors(s);
        printf("\n");

        n++;
        IOObjectRelease(s);
    }
    if (n == 0) printf("(no USB devices connected)\n");
    if (n > 0 && !IOIteratorIsValid(iter))
        printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
    IOObjectRelease(iter);
    return 0;
}
