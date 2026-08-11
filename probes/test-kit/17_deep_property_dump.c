// Deep dump of every property on every service in the HPM/IOPort tree,
// with full recursion into nested dictionaries and arrays.
// Previous probes showed <dict> and <array> but didn't unpack them.
//
// Focus areas:
// 1. AppleHPMInterfaceType10 "Metadata" dict (unexplored)
// 2. "Pin Configuration" dict
// 3. "CF VID Status Reg" raw bytes decoded
// 4. IOPortTransportStateUSB3 full dump (SuperSpeedSignaling, etc)
// 5. IOPortTransportStateDisplayPort full dump (MaxLaneCount, LinkRate)
// 6. IOPortFeaturePowerSource "PowerSourceOptions" array
// 7. IOPortFeaturePowerSource "WinningPowerSourceOption" dict
// 8. Every "Metadata" dict on every service
// 9. "TransportsSupported/Active/Provisioned" arrays
// 10. "FeaturesEnabled/Supported" arrays
//
// Compile: clang -framework IOKit -framework CoreFoundation -o deep_dump 17_deep_property_dump.c
// Run: sudo ./deep_dump
// IMPORTANT: Have a USB-C cable plugged in!

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static void printIndent(int depth) {
    for (int i = 0; i < depth; i++) printf("  ");
}

static void dumpCFType(CFTypeRef value, int depth);

static void dumpDict(CFDictionaryRef dict, int depth) {
    CFIndex count = CFDictionaryGetCount(dict);
    const void **keys = malloc(sizeof(void*) * count);
    const void **vals = malloc(sizeof(void*) * count);
    CFDictionaryGetKeysAndValues(dict, keys, vals);

    for (CFIndex i = 0; i < count; i++) {
        char keyBuf[256] = {0};
        if (CFGetTypeID(keys[i]) == CFStringGetTypeID()) {
            if (!CFStringGetCString(keys[i], keyBuf, sizeof(keyBuf), kCFStringEncodingUTF8))
                snprintf(keyBuf, sizeof(keyBuf), "<unconvertible key>");
        } else {
            snprintf(keyBuf, sizeof(keyBuf), "<non-string key>");
        }
        printIndent(depth);
        printf("%s: ", keyBuf);
        dumpCFType(vals[i], depth);
    }

    free(keys);
    free(vals);
}

static void dumpArray(CFArrayRef arr, int depth) {
    CFIndex count = CFArrayGetCount(arr);
    for (CFIndex i = 0; i < count; i++) {
        printIndent(depth);
        printf("[%ld] ", i);
        dumpCFType(CFArrayGetValueAtIndex(arr, i), depth);
    }
}

static void dumpCFType(CFTypeRef value, int depth) {
    if (!value) { printf("(null)\n"); return; }

    CFTypeID tid = CFGetTypeID(value);

    if (tid == CFStringGetTypeID()) {
        char buf[1024];
        buf[0] = '\0';
        if (CFStringGetCString(value, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            printf("\"%s\"\n", buf);
        } else {
            printf("<unconvertible string>\n");
        }
    } else if (tid == CFNumberGetTypeID()) {
        int64_t val = 0;
        CFNumberGetValue(value, kCFNumberSInt64Type, &val);
        if (val >= -256 && val <= 65535)
            printf("%lld (0x%llx)\n", val, val);
        else
            printf("%lld (0x%llx)\n", val, val);
    } else if (tid == CFBooleanGetTypeID()) {
        printf("%s\n", CFBooleanGetValue(value) ? "true" : "false");
    } else if (tid == CFDataGetTypeID()) {
        CFDataRef data = (CFDataRef)value;
        CFIndex len = CFDataGetLength(data);
        const uint8_t *bytes = CFDataGetBytePtr(data);
        printf("<data %ld bytes> [", len);
        for (CFIndex j = 0; j < len && j < 128; j++) {
            printf(" %02x", bytes[j]);
        }
        if (len > 128) printf(" ...");
        printf(" ]\n");

        // If small data, also try interpreting as uint32 array (VDOs are 32-bit)
        if (len >= 4 && len <= 32 && len % 4 == 0) {
            printIndent(depth + 1);
            printf("(as uint32[]: ");
            const uint32_t *words = (const uint32_t *)bytes;
            for (CFIndex j = 0; j < len / 4; j++) {
                printf("0x%08x ", words[j]);
            }
            printf(")\n");
        }
    } else if (tid == CFDictionaryGetTypeID()) {
        printf("{\n");
        dumpDict((CFDictionaryRef)value, depth + 1);
        printIndent(depth);
        printf("}\n");
    } else if (tid == CFArrayGetTypeID()) {
        printf("[\n");
        dumpArray((CFArrayRef)value, depth + 1);
        printIndent(depth);
        printf("]\n");
    } else {
        printf("<CFType %lu>\n", tid);
    }
}

// Registry entry IDs already dumped. Needed now that the root list includes
// base classes as well as leaves: without it, a node matched by both a leaf and
// its base would have its entire subtree emitted twice, and this probe is the
// one that has historically hit the output cap.
#define kMaxSeen 8192
static uint64_t g_seen[kMaxSeen];
static int g_seenCount = 0;

static int g_seenOverflow = 0;
static int g_seenLookupFailures = 0;

// When 0 (phase 0, the original roots) nodes are recorded but never suppressed,
// so historical output is reproduced byte for byte. When 1 (phase 1, appended
// base classes) an already-recorded node is suppressed.
static int g_suppressDuplicates = 0;

static int isRecorded(io_service_t service) {
    uint64_t entryID = 0;
    if (IORegistryEntryGetRegistryEntryID(service, &entryID) != KERN_SUCCESS) return 0;
    for (int i = 0; i < g_seenCount; i++) if (g_seen[i] == entryID) return 1;
    return 0;
}

static void recordNode(io_service_t service) {
    uint64_t entryID = 0;
    if (IORegistryEntryGetRegistryEntryID(service, &entryID) != KERN_SUCCESS) {
        g_seenLookupFailures++;
        return;
    }
    for (int i = 0; i < g_seenCount; i++) if (g_seen[i] == entryID) return;
    if (g_seenCount < kMaxSeen) g_seen[g_seenCount++] = entryID;
    else g_seenOverflow++;
}

static void dumpServiceFull(io_service_t service, int depth) {
    io_name_t className = {0};
    IOObjectGetClass(service, className);

    if (g_suppressDuplicates && isRecorded(service)) {
        // Named, not silent: a reader must be able to tell "covered elsewhere"
        // from "not present". Absence and deduplication are different facts.
        printIndent(depth);
        printf("=== %s (already dumped) ===\n", className);
        return;
    }

    printIndent(depth);
    printf("=== %s ===\n", className);

    CFMutableDictionaryRef props = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(
        service, &props, kCFAllocatorDefault, 0);
    if (kr == KERN_SUCCESS && props) {
        dumpDict(props, depth + 1);
        CFRelease(props);
    }

    // Recurse into children
    io_iterator_t childIter;
    int childrenWalked = 0;
    kr = IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIter);
    if (kr == KERN_SUCCESS) {
        io_service_t child;
        int sawAnyChild = 0;
        while ((child = IOIteratorNext(childIter))) {
            sawAnyChild = 1;
            dumpServiceFull(child, depth + 1);
            IOObjectRelease(child);
        }
        // IOIteratorIsValid reads false for an iterator that matched nothing
        // at all (measured on macOS 26, see 42_typec_phy_subtree.c), not only
        // for one invalidated mid-walk, so a leaf node with zero children must
        // not be treated as truncated: only sawAnyChild-and-invalid counts.
        if (sawAnyChild && !IOIteratorIsValid(childIter)) {
            printIndent(depth + 1);
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        }
        // Only a completed walk counts. If the registry changed underneath us
        // the iterator goes invalid and we may have seen only part of the
        // subtree, so this node must stay eligible for a later root to emit in
        // full rather than be marked covered.
        childrenWalked = !sawAnyChild || IOIteratorIsValid(childIter);
        IOObjectRelease(childIter);
    }

    // Recorded only AFTER the subtree is fully emitted. Marking on entry (the
    // earlier version) meant a node whose child iterator failed was permanently
    // flagged as covered, so a later overlapping root could not retry it and a
    // never-emitted subtree would be pruned. Review caught this.
    if (childrenWalked) recordNode(service);
}

int main(void) {
    printf("Running as uid=%d\n\n", getuid());

    // Dump the full tree under each AppleHPMInterfaceType10/11
    printf("============================================================\n");
    printf("  FULL PROPERTY DUMP: HPM Interface -> all children\n");
    printf("============================================================\n\n");

    // Two phases. Phase 0 replays the ORIGINAL roots with suppression OFF, so
    // historical output is reproduced exactly even where two roots reach the
    // same node. Phase 1 runs the appended base classes with suppression ON, so
    // they add only what the originals missed. See the longer note in
    // 01_walk_pd_tree.c: deduping across the original roots would remove a
    // duplicate that old captures contain, and the corpus sweeps parse this.
    //
    // IOServiceMatching matches subclasses, so AppleHPMInterface picks up
    // controller variants that are not named here. This probe's root list is
    // genuinely blind to anything that is not a Type10/Type11 subclass, which
    // is the gap the base classes close.
    const char *rootClasses[] = {
        "AppleHPMInterfaceType10",
        "AppleHPMInterfaceType11",
        NULL
    };
    const char *baseRootClasses[] = {
        "AppleHPMInterface",      // any future/unknown HPM controller variant
        "AppleTCController",      // the Type-C controller layer above it
        "IOPortTransportState",   // transports NOT under an HPM interface, e.g. Port-SD Card
        NULL
    };

    for (int phase = 0; phase < 2; phase++) {
    const char **roots = phase == 0 ? rootClasses : baseRootClasses;
    g_suppressDuplicates = (phase == 1);
    for (int c = 0; roots[c]; c++) {
        io_iterator_t iter;
        kern_return_t kr = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching(roots[c]),
            &iter);
        if (kr != KERN_SUCCESS) continue;

        io_service_t svc;
        int idx = 0;
        int sawAny = 0;
        while ((svc = IOIteratorNext(iter))) {
            sawAny = 1;
            printf("\n--- %s[%d] ---\n", roots[c], idx);
            dumpServiceFull(svc, 0);
            IOObjectRelease(svc);
            idx++;
        }
        if (sawAny && !IOIteratorIsValid(iter)) {
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        }
        IOObjectRelease(iter);
    }
    }  // end phase loop
    g_suppressDuplicates = 0;

    if (g_seenLookupFailures || g_seenOverflow)
        printf("\n--- dedup: %d entry-ID lookup failures, %d table overflows (table %d/%d) ---\n",
               g_seenLookupFailures, g_seenOverflow, g_seenCount, kMaxSeen);

    // Also dump DeviceHAL for the CF VID Status Reg
    printf("\n============================================================\n");
    printf("  FULL PROPERTY DUMP: AppleHPMDeviceHALType3\n");
    printf("============================================================\n\n");
    {
        io_iterator_t iter;
        kern_return_t kr = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleHPMDeviceHALType3"),
            &iter);
        if (kr == KERN_SUCCESS) {
            io_service_t svc;
            int idx = 0;
            int sawAny = 0;
            while ((svc = IOIteratorNext(iter))) {
                sawAny = 1;
                printf("--- DeviceHAL[%d] ---\n", idx);

                CFMutableDictionaryRef props = NULL;
                kr = IORegistryEntryCreateCFProperties(
                    svc, &props, kCFAllocatorDefault, 0);
                if (kr == KERN_SUCCESS && props) {
                    dumpDict(props, 1);
                    CFRelease(props);
                }

                IOObjectRelease(svc);
                idx++;
            }
            if (sawAny && !IOIteratorIsValid(iter)) {
                printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
            }
            IOObjectRelease(iter);
        }
    }

    // Dump USB device tree for connected devices
    printf("\n============================================================\n");
    printf("  IOUSBHostDevice properties (connected USB devices)\n");
    printf("============================================================\n\n");
    {
        io_iterator_t iter;
        kern_return_t kr = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOUSBHostDevice"),
            &iter);
        if (kr == KERN_SUCCESS) {
            io_service_t svc;
            int sawAny = 0;
            while ((svc = IOIteratorNext(iter))) {
                sawAny = 1;
                io_name_t className = {0};
                IOObjectGetClass(svc, className);

                CFNumberRef vid = (CFNumberRef)IORegistryEntryCreateCFProperty(
                    svc, CFSTR("idVendor"), kCFAllocatorDefault, 0);
                CFNumberRef pid = (CFNumberRef)IORegistryEntryCreateCFProperty(
                    svc, CFSTR("idProduct"), kCFAllocatorDefault, 0);
                CFStringRef name = (CFStringRef)IORegistryEntryCreateCFProperty(
                    svc, CFSTR("USB Product Name"), kCFAllocatorDefault, 0);
                CFNumberRef speed = (CFNumberRef)IORegistryEntryCreateCFProperty(
                    svc, CFSTR("Device Speed"), kCFAllocatorDefault, 0);
                CFNumberRef bcdUSB = (CFNumberRef)IORegistryEntryCreateCFProperty(
                    svc, CFSTR("bcdUSB"), kCFAllocatorDefault, 0);

                int v = 0, p = 0, s = 0, bcd = 0;
                if (vid) { CFNumberGetValue(vid, kCFNumberIntType, &v); CFRelease(vid); }
                if (pid) { CFNumberGetValue(pid, kCFNumberIntType, &p); CFRelease(pid); }
                if (speed) { CFNumberGetValue(speed, kCFNumberIntType, &s); CFRelease(speed); }
                if (bcdUSB) { CFNumberGetValue(bcdUSB, kCFNumberIntType, &bcd); CFRelease(bcdUSB); }

                char nameBuf[256] = "?";
                // Keep the "?" fallback if the string can't be converted, rather
                // than leaving nameBuf in whatever state a failed copy left it.
                if (name) { if (!CFStringGetCString(name, nameBuf, sizeof(nameBuf), kCFStringEncodingUTF8)) snprintf(nameBuf, sizeof(nameBuf), "?"); CFRelease(name); }

                printf("  %s VID=0x%04x PID=0x%04x speed=%d bcdUSB=0x%04x\n",
                    nameBuf, v, p, s, bcd);

                IOObjectRelease(svc);
            }
            if (sawAny && !IOIteratorIsValid(iter)) {
                printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
            }
            IOObjectRelease(iter);
        }
    }

    // Look for any IOPortTransportState* services and dump them
    printf("\n============================================================\n");
    printf("  All IOPortTransportState* services\n");
    printf("============================================================\n\n");
    {
        const char *transportClasses[] = {
            "IOPortTransportStateCC",
            "IOPortTransportStateUSB2",
            "IOPortTransportStateUSB3",
            "IOPortTransportStateDisplayPort",
            "IOPortTransportStateThunderbolt",
            "IOPortTransportStatePCIe",
            NULL
        };

        for (int i = 0; transportClasses[i]; i++) {
            io_iterator_t iter;
            kern_return_t kr = IOServiceGetMatchingServices(
                kIOMainPortDefault,
                IOServiceMatching(transportClasses[i]),
                &iter);
            if (kr != KERN_SUCCESS) continue;

            io_service_t svc;
            int idx = 0;
            int sawAny = 0;
            while ((svc = IOIteratorNext(iter))) {
                sawAny = 1;
                printf("--- %s[%d] ---\n", transportClasses[i], idx);
                CFMutableDictionaryRef props = NULL;
                kr = IORegistryEntryCreateCFProperties(
                    svc, &props, kCFAllocatorDefault, 0);
                if (kr == KERN_SUCCESS && props) {
                    dumpDict(props, 1);
                    CFRelease(props);
                }

                // Also dump children (SOP/SOPp/SOPpp components)
                io_iterator_t childIter;
                kr = IORegistryEntryGetChildIterator(svc, kIOServicePlane, &childIter);
                if (kr == KERN_SUCCESS) {
                    io_service_t child;
                    int sawAnyChild = 0;
                    while ((child = IOIteratorNext(childIter))) {
                        sawAnyChild = 1;
                        io_name_t childClass = {0};
                        IOObjectGetClass(child, childClass);
                        printf("  child: %s\n", childClass);
                        CFMutableDictionaryRef childProps = NULL;
                        kr = IORegistryEntryCreateCFProperties(
                            child, &childProps, kCFAllocatorDefault, 0);
                        if (kr == KERN_SUCCESS && childProps) {
                            dumpDict(childProps, 2);
                            CFRelease(childProps);
                        }
                        IOObjectRelease(child);
                    }
                    if (sawAnyChild && !IOIteratorIsValid(childIter)) {
                        printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
                    }
                    IOObjectRelease(childIter);
                }

                IOObjectRelease(svc);
                idx++;
            }
            if (sawAny && !IOIteratorIsValid(iter)) {
                printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
            }
            IOObjectRelease(iter);
        }
    }

    // Look for IOPortFeature* services
    printf("\n============================================================\n");
    printf("  All IOPortFeature* services\n");
    printf("============================================================\n\n");
    {
        const char *featureClasses[] = {
            "IOPortFeaturePowerIn",
            "IOPortFeaturePowerSource",
            "IOPortFeatureLDCM",
            NULL
        };

        for (int i = 0; featureClasses[i]; i++) {
            io_iterator_t iter;
            kern_return_t kr = IOServiceGetMatchingServices(
                kIOMainPortDefault,
                IOServiceMatching(featureClasses[i]),
                &iter);
            if (kr != KERN_SUCCESS) continue;

            io_service_t svc;
            int idx = 0;
            int sawAny = 0;
            while ((svc = IOIteratorNext(iter))) {
                sawAny = 1;
                printf("--- %s[%d] ---\n", featureClasses[i], idx);
                CFMutableDictionaryRef props = NULL;
                kr = IORegistryEntryCreateCFProperties(
                    svc, &props, kCFAllocatorDefault, 0);
                if (kr == KERN_SUCCESS && props) {
                    dumpDict(props, 1);
                    CFRelease(props);
                }
                IOObjectRelease(svc);
                idx++;
            }
            if (sawAny && !IOIteratorIsValid(iter)) {
                printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
            }
            IOObjectRelease(iter);
        }
    }

    return 0;
}
