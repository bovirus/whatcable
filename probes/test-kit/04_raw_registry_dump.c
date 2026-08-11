// Dump EVERY property from a wide set of USB-C / Thunderbolt / port-controller
// root services AND their full child subtrees. No field filtering: we want
// everything the kernel exposes, documented or not, because a field that looks
// useless today can turn out to matter for a later WhatCable feature (or a
// sibling app). The recursion is what makes this a full capture: the matched
// root nodes carry the port-controller and top-level device properties, but the
// interesting per-interface fields (per-device power allocation, VID source,
// billboard modes, link speed, hub-port statistics) live on child nodes, so a
// flat per-root dump silently dropped them. This walks down into every
// descendant and dumps its properties too.
//
// Safety: the collector discards any probe output over a few MB, so an
// unbounded dump risks losing EVERYTHING rather than a tail. Three guards keep
// that from happening without filtering any field: a visited-set (each registry
// node is dumped once even when reachable from several roots, which also breaks
// any cycle), a generous depth cap, and a byte budget kept well under the
// collector cap that stops emitting and prints a marker rather than overflowing.
//
// Compile: clang -framework IOKit -framework CoreFoundation -o raw_registry_dump 04_raw_registry_dump.c

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdint.h>
#include <string.h>

// Byte budget: stay comfortably under the collector's multi-MB output cap so a
// large tree is captured as far as it fits, never discarded wholesale.
static const long long kByteBudget = 3LL * 1024 * 1024;
// Depth cap for registry-node recursion: a pure runaway backstop. Real subtrees
// here are ~10 deep; the visited-set already prevents cycles, so this never
// truncates real data.
static const int kMaxDepth = 48;
// Separate depth cap for CF property-value recursion (nested dicts/arrays inside
// one node's properties). Real IOKit property graphs are a few levels deep; this
// only guards against a pathologically deep or cyclic container exhausting the
// stack before the byte budget stops output.
static const int kMaxValueDepth = 100;

// Upper bound on how many entries of one property dictionary we will buffer.
// Far above anything real (a busy node publishes tens), low enough that the
// allocation cannot get out of hand on a machine we do not control.
static const size_t kMaxDictEntries = 20000;

static long long g_bytes = 0;
static int g_truncatedNoted = 0;

// Every registry node reached, by registry entry ID, so a node shared by more
// than one root is dumped once and any cycle terminates. Sized far above real
// use (a live multi-hub dock touches a few hundred nodes). If it ever saturates,
// dedup stops (nodes past the cap may be re-dumped) but the byte budget still
// hard-caps total output, so it degrades safely rather than running away.
#define kSeenCap 65536u   /* power of two, for the mask below */
static uint64_t g_seen[kSeenCap];
static size_t g_seenCount = 0;

// printf wrapper that accumulates emitted bytes AND enforces the budget: once the
// budget is reached it emits nothing further, so the total output is bounded to
// the budget plus at most one value's worth of overshoot. This is the actual
// enforcement; overBudget() below just prints the one-time marker and lets
// callers break their loops early.
static int emitf(const char *fmt, ...) {
    if (g_bytes >= kByteBudget) return 0;
    va_list ap;
    va_start(ap, fmt);
    int n = vprintf(fmt, ap);
    va_end(ap);
    if (n > 0) g_bytes += n;
    return n;
}

static int overBudget(void) {
    if (g_bytes < kByteBudget) return 0;
    if (!g_truncatedNoted) {
        g_truncatedNoted = 1;
        // Not routed through emitf: this marker must print even at the budget.
        printf("\n[output budget reached: remaining nodes omitted to stay under the collector cap]\n");
    }
    return 1;
}

// Returns 1 if this node was already dumped (so the caller skips it). Nodes
// whose ID can't be read are treated as new (dumped, not deduped); the depth
// cap still bounds them.
static int alreadySeen(io_service_t service) {
    uint64_t id = 0;
    if (IORegistryEntryGetRegistryEntryID(service, &id) != KERN_SUCCESS) return 0;
    /* 0 marks an empty slot, so an id of 0 is simply never deduped. */
    if (id == 0) return 0;
    /* Open addressing with linear probing. The previous linear scan was O(n)
       per node, so a wide registry cost O(n^2) comparisons and could burn the
       runner's watchdog on a contributor's machine before the byte budget ever
       came into play. */
    const size_t mask = kSeenCap - 1u;
    /* Golden-ratio (Fibonacci) multiplicative hash, taking the TOP bits.
       Registry entry IDs are near-sequential, and the previous version
       multiplied by the FNV prime and took bits [17,33). That prime is
       2^40 + 435, so its 2^40 component never reaches that window and the
       result stayed near-linear in the low bits: 10,000 sequential ids
       landed in 34 buckets, and linear probing turned that single cluster
       back into the O(n^2) behaviour this set exists to avoid. Taking the
       top bits of the golden-ratio product spreads them properly (the same
       10,000 ids land in 10,000 buckets). */
    size_t h = (size_t)((id * 0x9E3779B97F4A7C15ULL) >> 48) & mask;
    for (size_t i = 0; i < kSeenCap; i++) {
        size_t slot = (h + i) & mask;
        if (g_seen[slot] == id) return 1;
        if (g_seen[slot] == 0) {
            /* Keep one slot free so the probe above always terminates. */
            if (g_seenCount < kSeenCap - 1u) {
                g_seen[slot] = id;
                g_seenCount++;
            }
            return 0;
        }
    }
    /* Saturated: stop deduping. The byte budget still bounds total output. */
    return 0;
}

static void dumpValue(CFTypeRef value, int indent, int vdepth);

static void dumpDict(CFDictionaryRef dict, int indent, int vdepth) {
    if (vdepth > kMaxValueDepth) { emitf("<max value depth>\n"); return; }
    CFIndex count = CFDictionaryGetCount(dict);
    if (count <= 0) return;
    /* A third-party driver can publish an enormous property dictionary. Cap the
       entry count before allocating: the two arrays below are 16 bytes per entry,
       so an unbounded count could demand hundreds of megabytes on someone else's
       machine even though the OUTPUT is capped. The check also rules out the
       size_t multiply overflowing. */
    if ((size_t)count > kMaxDictEntries) {
        emitf("<dictionary too large: %ld entries omitted>\n", (long)count);
        return;
    }
    const void **keys = malloc(sizeof(void*) * (size_t)count);
    const void **vals = malloc(sizeof(void*) * (size_t)count);
    if (!keys || !vals) { free(keys); free(vals); return; }
    CFDictionaryGetKeysAndValues(dict, keys, vals);

    for (CFIndex i = 0; i < count; i++) {
        if (overBudget()) break;
        for (int j = 0; j < indent; j++) emitf("  ");
        if (CFGetTypeID(keys[i]) == CFStringGetTypeID()) {
            char buf[256];
            buf[0] = '\0';
            if (CFStringGetCString(keys[i], buf, sizeof(buf), kCFStringEncodingUTF8)) {
                emitf("\"%s\": ", buf);
            } else {
                emitf("<unconvertible-key>: ");
            }
        } else {
            emitf("<key>: ");
        }
        dumpValue(vals[i], indent + 1, vdepth + 1);
    }
    free(keys);
    free(vals);
}

static void dumpValue(CFTypeRef value, int indent, int vdepth) {
    if (overBudget()) {
        /* The key label for this value has already been written, so returning
           silently would leave a dangling `"key": ` with no value and no
           newline. Terminate the line. Not routed through emitf for the same
           reason the budget marker is not: it must appear at the budget. Its
           enclosing loop breaks on the next iteration, so this fires at most
           once per open container. */
        printf("<truncated>\n");
        return;
    }
    if (vdepth > kMaxValueDepth) { emitf("<max value depth>\n"); return; }
    if (!value) { emitf("null\n"); return; }
    CFTypeID tid = CFGetTypeID(value);

    if (tid == CFStringGetTypeID()) {
        char buf[2048];
        buf[0] = '\0';
        if (CFStringGetCString(value, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            emitf("\"%s\"\n", buf);
        } else {
            emitf("<unconvertible string>\n");
        }
    } else if (tid == CFNumberGetTypeID()) {
        long long n = 0;
        if (CFNumberGetValue(value, kCFNumberLongLongType, &n)) {
            emitf("%lld (0x%llx)\n", n, n);
        } else {
            /* Out of range or otherwise not convertible: n would be
               indeterminate, so never print it. */
            emitf("<unconvertible number>\n");
        }
    } else if (tid == CFBooleanGetTypeID()) {
        emitf("%s\n", CFBooleanGetValue(value) ? "true" : "false");
    } else if (tid == CFDataGetTypeID()) {
        CFIndex len = CFDataGetLength(value);
        const UInt8 *b = CFDataGetBytePtr(value);
        emitf("<data %ld>: ", len);
        for (CFIndex i = 0; i < len; i++) {
            if (overBudget()) break;
            emitf("%02x", b[i]);
            if (i < len - 1 && (i + 1) % 4 == 0) emitf(" ");
        }
        emitf("\n");
    } else if (tid == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(value);
        emitf("[\n");
        for (CFIndex i = 0; i < count; i++) {
            if (overBudget()) break;
            for (int j = 0; j < indent; j++) emitf("  ");
            emitf("[%ld] ", i);
            dumpValue(CFArrayGetValueAtIndex(value, i), indent + 1, vdepth + 1);
        }
        for (int j = 0; j < indent - 1; j++) emitf("  ");
        emitf("]\n");
    } else if (tid == CFDictionaryGetTypeID()) {
        emitf("{\n");
        dumpDict(value, indent, vdepth + 1);
        for (int j = 0; j < indent - 1; j++) emitf("  ");
        emitf("}\n");
    } else {
        emitf("<type-%lu>\n", tid);
    }
}

// Dump one node (class, name, all properties) then recurse into every child on
// the service plane. `depth` drives indentation and the runaway cap.
//
// `forceOwnProperties` makes this node dump its own properties even if it was
// already reached under some other root. Every explicitly matched root passes 1.
// Without it, a device that happened to be reached first as another root's
// descendant had its own section reduced to a bare "[already dumped]" line with
// no properties at all: on a docked Mac that emptied 10 of 12 USB device
// sections, including the display and the ethernet adapter. Descendants keep
// deduping normally, so a shared subtree is still only walked once.
static void dumpNode(io_service_t service, int depth, int forceOwnProperties) {
    if (depth > kMaxDepth) return;
    if (overBudget()) {
        /* A root whose section header was the write that crossed the budget
           would otherwise leave a header with nothing beneath it, which reads
           like a device with no properties rather than a truncated dump. Say
           so explicitly. Raw printf for the same reason as the budget marker,
           and bounded because only matched roots pass forceOwnProperties. */
        if (forceOwnProperties) printf("[properties omitted: output budget reached]\n");
        return;
    }

    io_name_t name = {0}, cls = {0};
    IORegistryEntryGetName(service, name);
    IOObjectGetClass(service, cls);

    if (alreadySeen(service) && !forceOwnProperties) {
        for (int j = 0; j < depth; j++) emitf("  ");
        emitf("- %s (name: %s) [already dumped, see above]\n", cls, name);
        return;
    }

    for (int j = 0; j < depth; j++) emitf("  ");
    emitf("- %s (name: %s) [depth %d]\n", cls, name, depth);

    CFMutableDictionaryRef props = NULL;
    if (IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
        dumpDict(props, depth + 1, 0);
        CFRelease(props);
    }

    io_iterator_t children;
    if (IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS) {
        io_service_t child;
        int sawAny = 0;
        while ((child = IOIteratorNext(children))) {
            sawAny = 1;
            // Stop walking, not just writing. Without this a very wide node
            // keeps fetching and releasing every remaining sibling long after
            // output has stopped, which on a big tree means the runner's
            // watchdog kills the probe instead of it finishing cleanly.
            if (overBudget()) { IOObjectRelease(child); break; }
            dumpNode(child, depth + 1, 0);
            IOObjectRelease(child);
        }
        if (sawAny && !IOIteratorIsValid(children))
            emitf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(children);
    }
}

static void dumpAllMatchingServices(const char *className) {
    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching(className),
        &iter
    );
    if (kr != KERN_SUCCESS) return;

    io_service_t service;
    int idx = 0;
    while ((service = IOIteratorNext(iter))) {
        if (overBudget()) { IOObjectRelease(service); break; }
        io_name_t name = {0};
        IORegistryEntryGetName(service, name);

        emitf("\n========================================\n");
        emitf("%s[%d] (name: %s)\n", className, idx++, name);
        emitf("========================================\n");

        dumpNode(service, 0, 1);

        IOObjectRelease(service);
    }
    if (idx > 0 && !IOIteratorIsValid(iter))
        emitf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
    IOObjectRelease(iter);
}

int main(void) {
    // Cast a wide net - search for every class prefix that might be relevant.
    // Each match is a root; dumpNode walks its whole subtree.
    const char *prefixes[] = {
        "IOPortTransportComponentCCUSBPDSOP",
        "IOPortTransportComponentCCUSBPDSOPp",
        "IOPortTransportComponentCCUSBPDSOPpp",
        "IOPortTransportStateCC",
        "IOPortFeaturePowerIn",
        "IOPortFeatureLDCM",
        "IOPortFeatureUSBCOvercurrent",
        "AppleHPMInterfaceType",
        "AppleHPMARMSPMI",
        "AppleHPMLDCMType",
        "AppleTypeCPort",
        "AppleT8132TypeCPhy",
        "AppleTypeCRetimer",
        "IOAccessoryManager",
        "IOAccessoryPort",
        "AppleUSBCPort",
        "IOUSBHostDevice",
        "AppleUSBVHCIPort",
        "IOThunderboltPort",
        NULL
    };

    for (int i = 0; prefixes[i]; i++) {
        if (overBudget()) break;
        dumpAllMatchingServices(prefixes[i]);
    }

    return 0;
}
