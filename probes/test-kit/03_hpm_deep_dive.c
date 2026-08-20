// Deep dive into AppleHPM - walk the full parent/child tree,
// look for any hidden properties, user client classes, or
// notification ports we can register on.
// Compile: clang -framework IOKit -framework CoreFoundation -o hpm_deep_dive 03_hpm_deep_dive.c

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>

static void printDataHex(CFDataRef data) {
    CFIndex len = CFDataGetLength(data);
    const UInt8 *bytes = CFDataGetBytePtr(data);
    for (CFIndex i = 0; i < len && i < 128; i++) {
        if (i > 0 && i % 16 == 0) printf("\n        ");
        printf("%02x ", bytes[i]);
    }
    if (len > 128) printf("... (%ld total)", len);
    printf("\n");
}

// Registry entry IDs already dumped, so the IOAccessoryManager walk added
// below (for M1/M2 coverage) doesn't re-print a node the
// AppleHPMARMSPMI walk already reached on hardware where both roots exist.
// Mirrors probes 01/17's recordAndCheck (46ca65b1): errs towards a duplicate
// over a silent drop, since a duplicate is visible and a drop is not.
#define kMaxSeen 4096
static uint64_t g_seen[kMaxSeen];
static int g_seenCount = 0;
static int g_seenOverflow = 0;
static int g_seenLookupFailures = 0;

// Record a node as visited. Returns 1 if it had already been recorded.
static int recordAndCheck(io_service_t service) {
    uint64_t entryID = 0;
    if (IORegistryEntryGetRegistryEntryID(service, &entryID) != KERN_SUCCESS) {
        g_seenLookupFailures++;
        return 0;
    }
    for (int i = 0; i < g_seenCount; i++) if (g_seen[i] == entryID) return 1;
    if (g_seenCount < kMaxSeen) g_seen[g_seenCount++] = entryID;
    else g_seenOverflow++;
    return 0;
}

// `suppress` is 0 for the original AppleHPMARMSPMI walk (so its output is
// byte-identical to before this change: nodes are always recorded but never
// skipped) and 1 for the appended IOAccessoryManager and AppleHPMARM walks (so
// they contribute only nodes the SPMI walk didn't already reach).
static void walkTree(io_service_t service, int depth, const char *plane, int suppress) {
    if (depth > 8) return;

    int alreadySeen = recordAndCheck(service);

    io_name_t className = {0}, name = {0};
    IOObjectGetClass(service, className);
    IORegistryEntryGetName(service, name);

    for (int i = 0; i < depth; i++) printf("  ");
    printf("[%s] %s", className, name);

    // A suppressed, already-seen node skips its OWN body (UserClient/bundle
    // ID header, and the interesting-property scan below) but still walks
    // into its children. The two walks reach a shared node from different
    // planes (IOService vs IOPower), and a plane's child set is not the
    // same set: an IOPower-plane hit recording a node must not swallow
    // children that only the IOService-plane walk would ever reach, and
    // vice versa. Review caught an earlier version that `return`ed here,
    // which would have dropped exactly that class of descendant silently,
    // the same silent-drop failure mode this dedup exists to avoid.
    int skipBody = suppress && alreadySeen;
    if (skipBody) {
        printf(" (already dumped above)\n");
    } else {
        // Check for "UserClientClass" property - tells us what user client exists
        CFTypeRef ucClass = IORegistryEntryCreateCFProperty(
            service, CFSTR("IOUserClientClass"), kCFAllocatorDefault, 0);
        if (ucClass) {
            char buf[256];
            buf[0] = '\0';
            if (CFStringGetCString(ucClass, buf, sizeof(buf), kCFStringEncodingUTF8)) {
                printf(" (UserClient: %s)", buf);
            } else {
                printf(" (UserClient: <unconvertible>)");
            }
            CFRelease(ucClass);
        }

        // Check for bundle ID
        CFTypeRef bundleID = IORegistryEntryCreateCFProperty(
            service, CFSTR("CFBundleIdentifier"), kCFAllocatorDefault, 0);
        if (bundleID) {
            char buf[256];
            buf[0] = '\0';
            if (CFStringGetCString(bundleID, buf, sizeof(buf), kCFStringEncodingUTF8)) {
                printf(" [%s]", buf);
            } else {
                printf(" [<unconvertible>]");
            }
            CFRelease(bundleID);
        }

        printf("\n");

        // Look for interesting VDM/PD-related properties
        const char *interesting[] = {
            "VDMs", "VDOs", "Metadata", "PDRevision", "SpecRevision",
            "PortPartnerIdentity", "CableIdentity", "PDContract",
            "PowerRole", "DataRole", "VCONNSource",
            "SourceCapabilities", "SinkCapabilities",
            "RequestDataObject", "ActiveContract",
            "AlternateMode", "SVIDs", "Modes",
            "DisplayPortStatus", "DisplayPortConfig",
            "RawVDM", "VDMResponse", "VDMHistory",
            "MessageLog", "PDMessageLog", "TraceBuffer",
            NULL
        };

        for (int i = 0; interesting[i]; i++) {
            CFStringRef key = CFStringCreateWithCString(
                kCFAllocatorDefault, interesting[i], kCFStringEncodingUTF8);
            CFTypeRef val = IORegistryEntryCreateCFProperty(
                service, key, kCFAllocatorDefault, 0);
            if (val) {
                for (int j = 0; j < depth + 1; j++) printf("  ");
                printf(">>> %s: ", interesting[i]);

                CFTypeID tid = CFGetTypeID(val);
                if (tid == CFDataGetTypeID()) {
                    printf("<data %ld bytes> ", CFDataGetLength(val));
                    printDataHex(val);
                } else if (tid == CFNumberGetTypeID()) {
                    long long num;
                    CFNumberGetValue(val, kCFNumberLongLongType, &num);
                    printf("%lld (0x%llx)\n", num, num);
                } else if (tid == CFStringGetTypeID()) {
                    char buf[512];
                    buf[0] = '\0';
                    if (CFStringGetCString(val, buf, sizeof(buf), kCFStringEncodingUTF8)) {
                        printf("\"%s\"\n", buf);
                    } else {
                        printf("<unconvertible string>\n");
                    }
                } else if (tid == CFDictionaryGetTypeID()) {
                    printf("<dict with %ld keys>\n", CFDictionaryGetCount(val));
                } else if (tid == CFArrayGetTypeID()) {
                    printf("<array with %ld items>\n", CFArrayGetCount(val));
                } else if (tid == CFBooleanGetTypeID()) {
                    printf("%s\n", CFBooleanGetValue(val) ? "true" : "false");
                } else {
                    printf("<type %lu>\n", CFGetTypeID(val));
                }
                CFRelease(val);
            }
            CFRelease(key);
        }
    }

    // Recurse into children, even for a suppressed node: a plane's child set
    // is plane-specific, so an unseen descendant reached only through THIS
    // plane must still get its own walk.
    io_iterator_t childIter;
    kern_return_t kr = IORegistryEntryGetChildIterator(service, plane, &childIter);
    if (kr == KERN_SUCCESS) {
        io_service_t child;
        int sawAny = 0;
        while ((child = IOIteratorNext(childIter))) {
            sawAny = 1;
            walkTree(child, depth + 1, plane, suppress);
            IOObjectRelease(child);
        }
        if (sawAny && !IOIteratorIsValid(childIter))
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(childIter);
    }
}

int main(void) {
    printf("=== Walking from AppleHPMARMSPMI in IOService plane ===\n\n");

    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("AppleHPMARMSPMI"),
        &iter
    );

    if (kr == KERN_SUCCESS) {
        io_service_t service;
        int sawAny = 0;
        while ((service = IOIteratorNext(iter))) {
            sawAny = 1;
            walkTree(service, 0, kIOServicePlane, 0);
            IOObjectRelease(service);
        }
        if (sawAny && !IOIteratorIsValid(iter))
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(iter);
    } else {
        printf("No AppleHPMARMSPMI found\n");
    }

    // Also try IOPower plane - might show different hierarchy
    printf("\n\n=== Walking AppleHPMARMSPMI in IOPower plane ===\n\n");
    kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("AppleHPMARMSPMI"),
        &iter
    );
    if (kr == KERN_SUCCESS) {
        io_service_t service;
        int sawAny = 0;
        while ((service = IOIteratorNext(iter))) {
            sawAny = 1;
            walkTree(service, 0, "IOPower", 0);
            IOObjectRelease(service);
        }
        if (sawAny && !IOIteratorIsValid(iter))
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(iter);
    }

    // Check for any notification-related properties on the PD services
    printf("\n\n=== Checking IOPortTransportComponentCCUSBPDSOPp notification support ===\n");
    kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("IOPortTransportComponentCCUSBPDSOPp"),
        &iter
    );
    if (kr == KERN_SUCCESS) {
        io_service_t service;
        int sawAny = 0;
        while ((service = IOIteratorNext(iter))) {
            sawAny = 1;
            // Try to register for interest notifications
            IONotificationPortRef notifyPort = IONotificationPortCreate(kIOMainPortDefault);
            if (notifyPort) {
                io_object_t notifier;
                kr = IOServiceAddInterestNotification(
                    notifyPort, service,
                    kIOGeneralInterest,
                    NULL, NULL, &notifier
                );
                printf("  General interest notification: kr=0x%x %s\n",
                    kr, kr == KERN_SUCCESS ? "SUCCESS" : "FAILED");
                if (kr == KERN_SUCCESS) IOObjectRelease(notifier);

                kr = IOServiceAddInterestNotification(
                    notifyPort, service,
                    kIOBusyInterest,
                    NULL, NULL, &notifier
                );
                printf("  Busy interest notification: kr=0x%x %s\n",
                    kr, kr == KERN_SUCCESS ? "SUCCESS" : "FAILED");
                if (kr == KERN_SUCCESS) IOObjectRelease(notifier);

                IONotificationPortDestroy(notifyPort);
            }
            IOObjectRelease(service);
        }
        if (sawAny && !IOIteratorIsValid(iter))
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(iter);
    }

    // Appended for M1/M2 coverage: AppleHPMARMSPMI (the walk above) is SPMI bus
    // hardware that does not exist before M3, so every M1 and M2 machine got
    // an empty capture from this probe. Confirmed against the corpus
    // (research/customer-probes/m1_*, m2_*): those machines' USB-C port
    // controller node is a sibling class under IOAccessoryManager instead,
    // named AppleTCControllerType10 (M1) or AppleTCControllerType11 (M2).
    //
    // There is no "AppleTCController" base class to match on: probe 04's raw
    // registry dump prints the real class ancestry as
    // "AppleTCControllerType10 -> IOService -> IORegistryEntry -> IOPort ->
    // IOAccessoryManager", i.e. it subclasses IOAccessoryManager directly,
    // the same way AppleHPMInterfaceType10/11/18 (M3+'s equivalent node, on
    // machines that use that driver instead) also subclasses
    // IOAccessoryManager directly, as siblings, not through one another.
    // IOAccessoryManager is therefore the correct base class to walk from:
    // IOServiceMatching matches subclasses, so this reaches every generation's
    // port controller, present or future.
    //
    // Kept as an appended, separately-suppressed walk (not merged into the
    // AppleHPMARMSPMI section above) so the original output stays byte-
    // identical: existing corpus sweeps that read this probe's original two
    // headers keep working unchanged. Deduped by registry entry ID against
    // the AppleHPMARMSPMI walk above, so on hardware that publishes both
    // (any M3+ machine, since IOAccessoryManager sits in both walks' reach)
    // this only prints nodes not already dumped.
    printf("\n\n=== Walking from IOAccessoryManager in IOService plane "
           "(added for M1/M2 coverage) ===\n\n");
    kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("IOAccessoryManager"),
        &iter
    );
    if (kr == KERN_SUCCESS) {
        io_service_t service;
        int sawAny = 0;
        while ((service = IOIteratorNext(iter))) {
            sawAny = 1;
            walkTree(service, 0, kIOServicePlane, 1);
            IOObjectRelease(service);
        }
        if (sawAny && !IOIteratorIsValid(iter))
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(iter);
    } else {
        printf("No IOAccessoryManager found\n");
    }

    // Appended for I2C-transport coverage, same reasoning and same shape as the
    // IOAccessoryManager walk above. The two walks at the top of this probe
    // match the AppleHPMARMSPMI leaf, but the HPM bus transport is per-machine:
    // of the 98 corpus machines that ran probe 41, 58 publish AppleHPMARMSPMI
    // and the other 40 publish AppleHPMARMI2C, never both. Measured directly on
    // probe 27 output, the AppleHPMARMSPMI section is empty on 500 of 1177
    // Apple Silicon folders. AppleHPMARM is the shared parent, so matching it
    // reaches both transports and any future one.
    //
    // Appended and separately suppressed, NOT merged into the walks above, so
    // the original two headers and their output stay byte-identical for
    // existing corpus sweeps. Deduped by registry entry ID, so on an SPMI
    // machine this section prints nothing new.
    printf("\n\n=== Walking from AppleHPMARM in IOService plane "
           "(added for I2C-transport coverage) ===\n\n");
    kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("AppleHPMARM"),
        &iter
    );
    if (kr == KERN_SUCCESS) {
        io_service_t service;
        int sawAny = 0;
        while ((service = IOIteratorNext(iter))) {
            sawAny = 1;
            walkTree(service, 0, kIOServicePlane, 1);
            IOObjectRelease(service);
        }
        if (sawAny && !IOIteratorIsValid(iter))
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(iter);
    } else {
        printf("No AppleHPMARM found\n");
    }

    if (g_seenLookupFailures > 0 || g_seenOverflow > 0) {
        printf("\n[dedup] entry ID lookup failures: %d, seen-table overflow: %d\n",
               g_seenLookupFailures, g_seenOverflow);
    }

    return 0;
}
