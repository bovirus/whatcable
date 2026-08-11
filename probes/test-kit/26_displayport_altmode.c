// Capture connected-display capability as a tree, from the real Apple Silicon
// display nodes, with IOReporting noise cut.
//
// History: the old version of this probe queried Intel-era framebuffer classes
// (IODisplayConnect / IOFramebuffer / IOBacklightDisplay) that do not exist on
// Apple Silicon, so it captured none of its intended data; it then fell back to
// "match every IOService and dump anything with 'DisplayPort' in the name",
// which produced ~640 KB of IOReporting event-log spam. This rewrite fixes it:
//
//   1. Roots at the display nodes that actually exist on Apple Silicon
//      (AppleCLCD2 / IOMobileFramebufferShim / DCPAVDevice) and walks each
//      subtree, so the display capability (DSC / HDR / colour / native modes /
//      timing) is actually captured.
//   2. Preserves the tree: every node records its RegistryEntryID and its
//      parent's, the same convention as probes 29 and 38, so the hierarchy is
//      reconstructable from data, not from indentation.
//   3. Skips the IOReporting event-log keys, so the output is the useful
//      capability data at a sane size.
//
// The panel serial and the raw EDID blob are KEPT, along with model identity
// (DisplayVendorID / DisplayProductID / ManufacturerID), manufacture date, and
// the EDID/IOMFB UUIDs. These identify a panel, not a person, and they are the
// join keys the research depends on: DisplayModeReader uses the serial to tell
// two identical displays apart, and the raw EDID is what the app's own EDID
// parser consumes. The probe submits to the private research KV.
//
// Compile: clang -framework IOKit -framework CoreFoundation -o 26_displayport_altmode 26_displayport_altmode.c

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <strings.h>

// The panel serial and the raw EDID blob are KEPT. The serial is the only thing
// that separates two identical displays, and DisplayModeReader uses exactly that
// to match a CoreGraphics display to the right IOKit port. The raw EDID blob is
// what the app's own EDID parser consumes, so redacting it made the corpus
// unable to replay that code path. Both identify a panel, not a person.

// IOReporting telemetry: high-volume event-log entries with no capability value
// (this is what bloated the old probe). Skip the key entirely.
static int isNoiseKey(const char *k) {
    return strncmp(k, "Event", 5) == 0
        || strcasestr(k, "IOReportLegend") || strcasestr(k, "IOReporting");
}

static void printValue(CFTypeRef value, int indent);

static void printDict(CFDictionaryRef dict, int indent) {
    CFIndex n = CFDictionaryGetCount(dict);
    if (n <= 0) return;
    // Guard the multiplication before it feeds malloc: newly exercised on the
    // Intel roots added below, and a huge or negative count (corrupt
    // property, future IOKit change) must not silently overflow into an
    // under-sized allocation.
    if ((size_t)n > SIZE_MAX / sizeof(void*)) {
        for (int j = 0; j < indent; j++) printf("  ");
        printf("[skipped: dictionary count %ld too large to allocate]\n", (long)n);
        return;
    }
    const void **keys = malloc((size_t)n * sizeof(void*));
    const void **vals = malloc((size_t)n * sizeof(void*));
    if (!keys || !vals) {
        for (int j = 0; j < indent; j++) printf("  ");
        printf("[skipped: dictionary allocation failed for %ld entries]\n", (long)n);
        free(keys); free(vals);
        return;
    }
    CFDictionaryGetKeysAndValues(dict, keys, vals);
    for (CFIndex i = 0; i < n; i++) {
        char kbuf[256] = {0};
        if (CFGetTypeID(keys[i]) != CFStringGetTypeID()) continue;
        if (!CFStringGetCString(keys[i], kbuf, sizeof(kbuf), kCFStringEncodingUTF8))
            snprintf(kbuf, sizeof(kbuf), "<unconvertible>");
        // Skip noise keys BEFORE printing the indent, or a suppressed key leaves
        // a stray blank-indent line that breaks a line-by-line parser.
        if (isNoiseKey(kbuf)) { continue; }
        for (int j = 0; j < indent; j++) printf("  ");
        printf("%s = ", kbuf);
        printValue(vals[i], indent + 1);
    }
    free(keys); free(vals);
}

static void printValue(CFTypeRef value, int indent) {
    if (!value) { printf("(null)\n"); return; }
    CFTypeID tid = CFGetTypeID(value);
    if (tid == CFStringGetTypeID()) {
        char buf[512] = {0};
        if (!CFStringGetCString(value, buf, sizeof(buf), kCFStringEncodingUTF8))
            snprintf(buf, sizeof(buf), "<unconvertible>");
        printf("\"%s\"\n", buf);
    } else if (tid == CFNumberGetTypeID()) {
        long long num = 0;
        CFNumberGetValue(value, kCFNumberLongLongType, &num);
        printf("%lld (0x%llx)\n", num, num);
    } else if (tid == CFBooleanGetTypeID()) {
        printf("%s\n", CFBooleanGetValue(value) ? "true" : "false");
    } else if (tid == CFDataGetTypeID()) {
        CFIndex len = CFDataGetLength(value);
        const UInt8 *b = CFDataGetBytePtr(value);
        printf("Data[%ld]: ", (long)len);
        for (CFIndex i = 0; i < len && i < 48; i++) printf("%02x ", b[i]);
        if (len > 48) printf("...");
        printf("\n");
    } else if (tid == CFDictionaryGetTypeID()) {
        printf("{\n");
        printDict((CFDictionaryRef)value, indent + 1);
        for (int j = 0; j < indent; j++) printf("  ");
        printf("}\n");
    } else if (tid == CFArrayGetTypeID()) {
        // Display nodes carry mode/timing tables with hundreds of entries, each
        // repeating the same capability flags. A sample is enough to characterise
        // the panel without dumping the whole table; the full count is recorded.
        CFIndex count = CFArrayGetCount(value);
        const CFIndex cap = 12;
        printf("[%ld]%s\n", (long)count, count > cap ? " (sampled)" : "");
        for (CFIndex i = 0; i < count && i < cap; i++) {
            for (int j = 0; j < indent + 1; j++) printf("  ");
            printValue(CFArrayGetValueAtIndex(value, i), indent + 1);
        }
    } else if (tid == CFSetGetTypeID()) {
        // e.g. NominalSignalingFrequenciesHz on a DisplayPort node is a CFSet of
        // numbers; without this it would print as an opaque type id.
        CFIndex count = CFSetGetCount(value);
        printf("set[%ld]\n", (long)count);
        if (count > 0) {
            // Same overflow guard as printDict: don't let a huge or negative
            // count overflow the malloc size, and don't hand CFSetGetValues a
            // NULL buffer if the allocation fails.
            if ((size_t)count > SIZE_MAX / sizeof(void*)) {
                for (int j = 0; j < indent + 1; j++) printf("  ");
                printf("[skipped: set count %ld too large to allocate]\n", (long)count);
            } else {
                const void **items = malloc((size_t)count * sizeof(void*));
                if (!items) {
                    for (int j = 0; j < indent + 1; j++) printf("  ");
                    printf("[skipped: set allocation failed for %ld entries]\n", (long)count);
                } else {
                    CFSetGetValues(value, items);
                    for (CFIndex i = 0; i < count && i < 32; i++) {
                        for (int j = 0; j < indent + 1; j++) printf("  ");
                        printValue(items[i], indent + 1);
                    }
                    free(items);
                }
            }
        }
    } else {
        printf("<type %lu>\n", (unsigned long)tid);
    }
}

// Registry entry IDs already dumped, so the Intel-era roots added below don't
// re-print a node the Apple Silicon roots above already reached. In practice
// the two class families never coexist on one Mac (confirmed empty on Intel
// for the Apple Silicon roots, and vice versa on Apple Silicon for the
// Intel roots), so this is a safety net rather than an expected hit. Mirrors
// probes 01/03/17's recordAndCheck (46ca65b1): a duplicate is visible in the
// output and can be filtered later; a silently dropped node cannot be told
// apart from hardware that was never there.
#define kMaxSeen 4096
static uint64_t g_seen[kMaxSeen];
static int g_seenCount = 0;
static int g_seenOverflow = 0;
static int g_seenLookupFailures = 0;

// Record a node as visited. Returns 1 if it had already been recorded, 0
// otherwise (including when the entry ID lookup itself fails, so a lookup
// failure never falsely suppresses a node). Writes the looked-up entry ID to
// *outEntryID (0 on failure), so callers get a single source of truth for the
// ID instead of a second, unchecked call to the same IOKit function. Mirrors
// probe 03's recordAndCheck: an explicit KERN_SUCCESS check, not an entryID==0
// sentinel (registry entry IDs are not documented as never zero, so treating
// zero as "lookup failed" could misclassify a real ID as a failure).
static int recordAndCheck(io_service_t service, uint64_t *outEntryID) {
    uint64_t entryID = 0;
    if (IORegistryEntryGetRegistryEntryID(service, &entryID) != KERN_SUCCESS) {
        g_seenLookupFailures++;
        *outEntryID = 0;
        return 0;
    }
    *outEntryID = entryID;
    for (int i = 0; i < g_seenCount; i++) if (g_seen[i] == entryID) return 1;
    if (g_seenCount < kMaxSeen) g_seen[g_seenCount++] = entryID;
    else g_seenOverflow++;
    return 0;
}

// Walk one display node and its subtree, recording the parent linkage so the
// tree is reconstructable from data. Bounded depth guards a pathological tree.
//
// `suppress` is 0 for the original three Apple Silicon roots (output stays
// byte-identical to before this change: every node is recorded but never
// skipped) and 1 for the Intel roots appended below (so they contribute only
// nodes not already dumped).
static void walk(io_service_t service, int depth, uint64_t parentEntryID, int suppress) {
    // The panel capability (DSC / HDR / colour / modes / timing) sits in the top
    // display nodes; deeper children are framebuffer-pipeline internals (planes,
    // scalers) that add bulk without capability value, so the walk stays shallow.
    if (depth > 5) return;

    io_name_t cls = {0}, name = {0};
    IOObjectGetClass(service, cls);
    IORegistryEntryGetName(service, name);
    uint64_t entryID = 0;
    int alreadySeen = recordAndCheck(service, &entryID);

    for (int j = 0; j < depth; j++) printf("  ");
    printf("--- %s \"%s\" (entryID=0x%llx parentEntryID=0x%llx) ---",
           cls, name, (unsigned long long)entryID, (unsigned long long)parentEntryID);

    // A suppressed, already-seen node skips its own property dump but still
    // recurses into children. The Apple Silicon and Intel root sets are each
    // walked from a different starting point, so even in the (unexpected)
    // case where the same entry ID shows up under both, that node's OWN
    // children are not guaranteed to have been fully covered by whichever
    // walk reached it first (a bounded depth-5 walk from a different root
    // can bottom out before reaching the same descendants). Returning here
    // instead of falling through to the child walk below would silently drop
    // any descendant the other walk didn't happen to cover, the exact
    // silent-drop failure mode this dedup exists to avoid.
    int skipBody = suppress && alreadySeen;
    if (skipBody) {
        printf(" (already dumped above)\n");
    } else {
        printf("\n");
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            printDict(props, depth + 1);
            CFRelease(props);
        }
    }

    io_iterator_t childIter;
    if (IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIter) == KERN_SUCCESS) {
        io_service_t child;
        int sawAny = 0;
        while ((child = IOIteratorNext(childIter))) {
            sawAny = 1;
            walk(child, depth + 1, entryID, suppress);
            IOObjectRelease(child);
        }
        if (sawAny && !IOIteratorIsValid(childIter))
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(childIter);
    }
}

int main(void) {
    printf("=== Connected display capability (tree) ===\n");
    printf("Roots at the Apple Silicon display nodes; each node carries its\n");
    printf("RegistryEntryID and parent's so the tree is reconstructable from data.\n\n");

    // The display-capability nodes that actually exist on Apple Silicon. The DCP
    // (display coprocessor) presents the panel attributes; AppleCLCD2 is the
    // on-die display controller above it.
    const char *roots[] = {
        "AppleCLCD2",
        "IOMobileFramebufferShim",
        "DCPAVDevice",
        NULL
    };

    for (int r = 0; roots[r]; r++) {
        printf("=== root: %s ===\n", roots[r]);
        io_iterator_t iter;
        if (IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching(roots[r]), &iter) != KERN_SUCCESS) {
            printf("  (match failed)\n\n");
            continue;
        }
        io_service_t svc;
        int n = 0;
        while ((svc = IOIteratorNext(iter))) {
            walk(svc, 0, 0, 0);
            IOObjectRelease(svc);
            n++;
        }
        if (n > 0 && !IOIteratorIsValid(iter))
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(iter);
        if (n == 0) printf("  (no instances)\n");
        printf("\n");
    }

    // Appended for Intel coverage: the three roots above are Apple-Silicon-only, so
    // every Intel Mac got zero display data from this probe. Confirmed
    // against the corpus (research/customer-probes/intel_*): 29 of 59 Intel
    // folders hold a capture from this probe's pre-#379 predecessor, which
    // queried the classic Intel framebuffer classes, and every one of those
    // 29 has real properties under IODisplayConnect and IOFramebuffer (17 of
    // 22 also under IOBacklightDisplay). Post-#379 Intel captures show all
    // three current roots empty, confirming the blind spot is real and
    // current, not just historical.
    //
    // Kept as an appended, separately-suppressed pass (not merged into the
    // roots[] list above) so the original output stays byte-identical:
    // existing corpus sweeps that read this probe's original "root:" headers
    // and tree-node format keep working unchanged. Deduped by registry entry
    // ID against the walk above as a safety net, even though the two class
    // families are not expected to coexist on one Mac.
    printf("=== Intel-era roots (added for Intel coverage) ===\n\n");
    const char *intelRoots[] = {
        "IODisplayConnect",
        "IOFramebuffer",
        "IOBacklightDisplay",
        NULL
    };
    for (int r = 0; intelRoots[r]; r++) {
        printf("=== root: %s ===\n", intelRoots[r]);
        io_iterator_t iter;
        if (IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching(intelRoots[r]), &iter) != KERN_SUCCESS) {
            printf("  (match failed)\n\n");
            continue;
        }
        io_service_t svc;
        int n = 0;
        while ((svc = IOIteratorNext(iter))) {
            walk(svc, 0, 0, 1);
            IOObjectRelease(svc);
            n++;
        }
        if (n > 0 && !IOIteratorIsValid(iter))
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(iter);
        if (n == 0) printf("  (no instances)\n");
        printf("\n");
    }

    if (g_seenLookupFailures > 0 || g_seenOverflow > 0) {
        printf("[dedup] entry ID lookup failures: %d, seen-table overflow: %d\n",
               g_seenLookupFailures, g_seenOverflow);
    }

    return 0;
}
