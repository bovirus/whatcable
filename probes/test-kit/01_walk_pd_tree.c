// Walk the IOKit tree around USB-PD services and dump everything we can see.
// Compile: clang -framework IOKit -framework CoreFoundation -o walk_pd_tree 01_walk_pd_tree.c

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

static void printCFValue(CFTypeRef value, int indent);

static void printCFDict(CFDictionaryRef dict, int indent) {
    CFIndex count = CFDictionaryGetCount(dict);
    const void **keys = malloc(sizeof(void*) * count);
    const void **vals = malloc(sizeof(void*) * count);
    CFDictionaryGetKeysAndValues(dict, keys, vals);

    for (CFIndex i = 0; i < count; i++) {
        for (int j = 0; j < indent; j++) printf("  ");

        char keyBuf[256] = {0};
        if (CFGetTypeID(keys[i]) == CFStringGetTypeID()) {
            // Zero the buffer first and check the return: CFStringGetCString
            // can fail (too long, lossy encoding) and leaves buf unspecified
            // on failure, not just untouched.
            if (!CFStringGetCString(keys[i], keyBuf, sizeof(keyBuf), kCFStringEncodingUTF8))
                snprintf(keyBuf, sizeof(keyBuf), "<unconvertible-key>");
        } else {
            snprintf(keyBuf, sizeof(keyBuf), "<non-string-key>");
        }
        printf("%s = ", keyBuf);
        printCFValue(vals[i], indent + 1);
    }
    free(keys);
    free(vals);
}

static void printCFValue(CFTypeRef value, int indent) {
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
        long long num;
        CFNumberGetValue(value, kCFNumberLongLongType, &num);
        printf("%lld (0x%llx)\n", num, num);
    } else if (tid == CFBooleanGetTypeID()) {
        printf("%s\n", CFBooleanGetValue(value) ? "true" : "false");
    } else if (tid == CFDataGetTypeID()) {
        CFIndex len = CFDataGetLength(value);
        const UInt8 *bytes = CFDataGetBytePtr(value);
        printf("<data %ld bytes:", len);
        for (CFIndex i = 0; i < len && i < 64; i++) {
            printf(" %02x", bytes[i]);
        }
        if (len > 64) printf(" ...");
        printf(">\n");
    } else if (tid == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(value);
        printf("[\n");
        for (CFIndex i = 0; i < count; i++) {
            for (int j = 0; j < indent; j++) printf("  ");
            printf("[%ld] ", i);
            printCFValue(CFArrayGetValueAtIndex(value, i), indent + 1);
        }
        for (int j = 0; j < indent - 1; j++) printf("  ");
        printf("]\n");
    } else if (tid == CFDictionaryGetTypeID()) {
        printf("{\n");
        printCFDict(value, indent);
        for (int j = 0; j < indent - 1; j++) printf("  ");
        printf("}\n");
    } else {
        CFStringRef desc = CFCopyDescription(value);
        char buf[512];
        buf[0] = '\0';
        if (!CFStringGetCString(desc, buf, sizeof(buf), kCFStringEncodingUTF8))
            snprintf(buf, sizeof(buf), "unconvertible");
        printf("<%s>\n", buf);
        CFRelease(desc);
    }
}

static void dumpService(io_service_t service, const char *label) {
    io_name_t className = {0};
    IOObjectGetClass(service, className);

    io_name_t name = {0};
    IORegistryEntryGetName(service, name);

    printf("\n=== %s ===\n", label);
    printf("  Class: %s\n", className);
    printf("  Name:  %s\n", name);

    // Get ALL properties
    CFMutableDictionaryRef props = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0);
    if (kr == KERN_SUCCESS && props) {
        printf("  Properties:\n");
        printCFDict(props, 2);
        CFRelease(props);
    } else {
        printf("  (no properties, kr=%d)\n", kr);
    }

    // Walk children in IOService plane
    io_iterator_t childIter;
    kr = IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIter);
    if (kr == KERN_SUCCESS) {
        io_service_t child;
        int sawAny = 0;
        while ((child = IOIteratorNext(childIter))) {
            sawAny = 1;
            io_name_t childClass = {0};
            IOObjectGetClass(child, childClass);
            printf("  Child: %s\n", childClass);
            IOObjectRelease(child);
        }
        if (sawAny && !IOIteratorIsValid(childIter))
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(childIter);
    }
}

// Registry entry IDs already dumped, so a node reachable from more than one
// search term (now likely, since we search base classes as well as leaves) is
// emitted once rather than duplicated.
#define kMaxSeen 4096
static uint64_t g_seen[kMaxSeen];
static int g_seenCount = 0;

static int g_seenOverflow = 0;
static int g_seenLookupFailures = 0;

// Record a node as emitted. Returns 1 if it had already been recorded.
//
// On failure to read the entry ID, or once the table is full, this returns 0
// ("not seen"). That errs towards emitting a node twice rather than dropping it
// silently, which is the right way round: a duplicate is visible in the output
// and can be filtered later, whereas a drop is indistinguishable from the
// hardware not being there. Both failure modes are counted and reported at the
// end so they cannot pass unnoticed.
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

int main(void) {
    // IOServiceMatching matches subclasses (documented on IOObjectConformsTo:
    // "if the object is of that class or a subclass"), so searching a BASE class
    // finds variants nobody has written down yet. Hardcoding leaf names makes
    // the probe blind to every controller Apple ships next.
    //
    // ORDER IS LOAD-BEARING, and not for the usual reasons. The original search
    // terms run FIRST, in their original order, so that every block header this
    // probe has ever emitted keeps its exact name and index. More than ten
    // corpus-replay sweeps split probe 01 output on the literal string
    // "=== IOAccessoryManager[", and the 1135 folders already on disk are all in
    // the old format. Had the base classes gone first they would have claimed
    // those nodes and relabelled them, so OLD captures would keep parsing while
    // NEW submissions quietly yielded fewer ports: a regression that reports
    // itself as clean data.
    //
    // The base classes therefore run LAST, where dedup means they contribute
    // only nodes no existing term matched. Purely additive.
    //
    // The leaves are also kept as a floor, so a base-class name that turns out
    // not to exist costs nothing. That is not hypothetical: the "AppleHPMInterfaceType"
    // entry below is not a real class and matched zero nodes on every one of the
    // 787 corpus machines that ran this probe. The port-controller data only
    // ever arrived via IOAccessoryManager. It is retained (harmless, and its
    // "iterator empty" line is part of the historic output shape) with the real
    // base class added at the bottom.
    const char *classes[] = {
        // --- original search terms, original order: DO NOT REORDER ---
        "IOPortTransportComponentCCUSBPDSOP",
        "IOPortTransportComponentCCUSBPDSOPp",
        "IOPortTransportComponentCCUSBPDSOPpp",
        "AppleHPMInterfaceType",            // not a real class; matches nothing, kept for output shape
        "AppleHPMARMSPMI",
        "IOPortTransportStateCC",
        "IOPortFeaturePowerIn",
        "AppleTypeCPort",
        "AppleT8132TypeCPhy",
        "AppleTypeCRetimer",
        "IOAccessoryManager",
        NULL
    };
    // Appended base classes. Kept in a SEPARATE list, not just later in the
    // same one, because the two phases behave differently: see below.
    const char *baseClasses[] = {
        "IOPortTransportState",             // adds SD, DisplayPort, USB2/3, PCIe, CIO, Thunderbolt
        "IOPortTransportComponentCCUSBPD",  // adds future SOP variants
        "AppleHPMInterface",                // adds Type18 (A-series) and future TypeNN
        "AppleTypeCPhy",                    // adds per-die PHYs beyond the T8132 variant
        "IOPortFeature",                    // adds LDCM, overcurrent, future features
        NULL
    };

    // Two phases, and the distinction is the whole basis of the
    // backward-compatibility claim.
    //
    // Phase 0 replays the ORIGINAL search terms with their historical emission
    // behaviour EXACTLY: every match is dumped, including one already dumped by
    // an earlier original term. Entry IDs are recorded but suppression is off.
    // Suppressing here would silently remove a duplicate that old captures
    // contain, which is a change to historical output however harmless the
    // duplicate looks. Review found this: an earlier version deduped across all
    // terms and its "nothing lost" check passed only because this particular
    // Mac happens to have no overlap among the original terms.
    //
    // Phase 1 runs the appended base classes with suppression ON, so they
    // contribute only genuinely new nodes.
    for (int phase = 0; phase < 2; phase++) {
        const char **list = phase == 0 ? classes : baseClasses;
        const int suppress = (phase == 1);

        for (int i = 0; list[i]; i++) {
            io_iterator_t iter;
            kern_return_t kr = IOServiceGetMatchingServices(
                kIOMainPortDefault,
                IOServiceMatching(list[i]),
                &iter
            );
            if (kr != KERN_SUCCESS) {
                printf("\n--- %s: no matches (kr=%d) ---\n", list[i], kr);
                continue;
            }

            io_service_t service;
            int idx = 0, dumped = 0, skipped = 0;
            while ((service = IOIteratorNext(iter))) {
                // The block header is ALWAYS printed, with n counting every
                // match, exactly as this probe has always emitted it: the corpus
                // sweeps split on that literal string. A suppressed body gets a
                // marker rather than the header vanishing. Review caught the
                // earlier version skipping the header outright, which made
                // indices disappear with no explanation at all -- a reader could
                // not tell "never existed" from "deduped".
                char label[512];
                int seen = recordAndCheck(service);
                snprintf(label, sizeof(label), "%s[%d]", list[i], idx++);
                if (suppress && seen) {
                    printf("\n=== %s (already dumped above) ===\n", label);
                    skipped++;
                } else {
                    dumpService(service, label);
                    dumped++;
                }
                IOObjectRelease(service);
            }
            // Three distinct states, all named. "iterator empty" is the search
            // term finding nothing; the others are dedup outcomes. Collapsing
            // any of them into another would read as absent hardware.
            if (idx == 0)
                printf("\n--- %s: iterator empty ---\n", list[i]);
            else if (skipped && dumped == 0)
                printf("\n--- %s: all %d already dumped ---\n", list[i], idx);
            else if (skipped)
                printf("\n--- %s: %d dumped, %d already dumped ---\n", list[i], dumped, skipped);
            if (idx > 0 && !IOIteratorIsValid(iter))
                printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
            IOObjectRelease(iter);
        }
    }

    // Dedup health. Both of these make the seen-set stop working, which would
    // show up as duplicated output rather than missing output, but neither
    // should ever be non-zero and a silent occurrence would be invisible.
    if (g_seenLookupFailures || g_seenOverflow)
        printf("\n--- dedup: %d entry-ID lookup failures, %d table overflows (table %d/%d) ---\n",
               g_seenLookupFailures, g_seenOverflow, g_seenCount, kMaxSeen);

    return 0;
}
