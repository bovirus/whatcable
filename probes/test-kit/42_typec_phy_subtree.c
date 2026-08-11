/*
 * 42_typec_phy_subtree.c - Full, unfiltered dump of the Type-C PHY registry
 * subtree, plus a direct match on AppleTypeCPhyCIO80PhyMBI.
 *
 * Why this exists when 31_typec_phy_properties already matches AppleTypeCPhy:
 * the 2026-08-09 class census (probe 41) found AppleTypeCPhyCIO80PhyMBI on
 * TB5-class silicon (T6040 M4 Max, T6050 M5 Pro), and probe 31 can never see
 * it, for two reasons:
 *   - its ancestry is bare "IOService < IORegistryEntry < OSObject", NOT a
 *     subclass of AppleTypeCPhy, so IOServiceMatching("AppleTypeCPhy") does
 *     not return it;
 *   - probe 31's child walk skips any child whose registry NAME doesn't look
 *     PHY-related, so even as a child it could be filtered out.
 * This probe matches the class directly, prints where each instance sits in
 * the registry (full path + parent class chain), and walks the whole subtree
 * under every AppleTypeCPhy instance with no name filter, so any other
 * non-conforming PHY-adjacent node shows up too.
 *
 * Compile: clang -framework IOKit -framework CoreFoundation -o 42_typec_phy_subtree 42_typec_phy_subtree.c
 */

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>

/* The runner's pipe truncates at 65536 bytes and the tail (including any
 * warning) is what gets lost, so the budget is on BYTES, counted at every
 * print, with headroom for the end-of-run summary. MAX_NODES stays as a
 * secondary bound. MAX_BYTES is overridable (-DMAX_BYTES=...) so the budget
 * path can be exercised in a test run without a pathological machine. */
#ifndef MAX_BYTES
#define MAX_BYTES 60000
#endif
#define MAX_NODES 400
#define MAX_DEPTH 8

static long bytesOut = 0;
static int nodesDumped = 0;
static int budgetExhausted = 0;   /* set by outf() on MAX_BYTES, or the walk on MAX_NODES */

/* Every dump line goes through here: counts bytes, goes silent (and marks
 * the run exhausted) once the budget is spent. The final summary uses plain
 * printf so it survives regardless. */
static void outf(const char *fmt, ...) {
    if (budgetExhausted) return;
    va_list ap;
    va_start(ap, fmt);
    int n = vprintf(fmt, ap);
    va_end(ap);
    if (n > 0) bytesOut += n;
    if (bytesOut >= MAX_BYTES) budgetExhausted = 1;
}

static void printCFType(CFTypeRef value, int indent) {
    char pad[64] = {0};
    for (int i = 0; i < indent && i < 60; i++) pad[i] = ' ';

    if (!value) { outf("%s(null)\n", pad); return; }
    /* Kernel-supplied data shouldn't nest this deep; cap recursion anyway. */
    if (indent > 48) { outf("%s<nested too deep>\n", pad); return; }

    CFTypeID tid = CFGetTypeID(value);
    if (tid == CFStringGetTypeID()) {
        char buf[512];
        buf[0] = '\0';
        if (!CFStringGetCString(value, buf, sizeof(buf), kCFStringEncodingUTF8))
            snprintf(buf, sizeof(buf), "<unconvertible>");
        outf("%s\"%s\"\n", pad, buf);
    } else if (tid == CFNumberGetTypeID()) {
        long long num = 0;
        CFNumberGetValue(value, kCFNumberLongLongType, &num);
        outf("%s%lld (0x%llx)\n", pad, num, num);
    } else if (tid == CFDataGetTypeID()) {
        CFIndex len = CFDataGetLength(value);
        const UInt8 *bytes = CFDataGetBytePtr(value);
        outf("%sData[%ld]: ", pad, (long)len);
        for (CFIndex i = 0; i < len && i < 80; i++)
            outf("%02x ", bytes[i]);
        if (len > 80) outf("...");
        outf("\n");
    } else if (tid == CFDictionaryGetTypeID()) {
        CFIndex n = CFDictionaryGetCount(value);
        outf("%s<dict %ld>\n", pad, (long)n);
        if (n > 0) {
            const void **keys = malloc(n * sizeof(void*));
            const void **vals = malloc(n * sizeof(void*));
            if (!keys || !vals) {
                outf("%s  <alloc failed>\n", pad);
                free(keys); free(vals);
                return;
            }
            CFDictionaryGetKeysAndValues(value, keys, vals);
            for (CFIndex i = 0; i < n; i++) {
                char kbuf[256];
                kbuf[0] = '\0';
                if (!CFStringGetCString(keys[i], kbuf, sizeof(kbuf), kCFStringEncodingUTF8))
                    snprintf(kbuf, sizeof(kbuf), "<unconvertible>");
                outf("%s  %s = ", pad, kbuf);
                printCFType(vals[i], indent + 4);
            }
            free(keys); free(vals);
        }
    } else if (tid == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(value);
        outf("%s<array %ld>\n", pad, (long)count);
        for (CFIndex i = 0; i < count; i++) {
            outf("%s  [%ld] ", pad, (long)i);
            printCFType(CFArrayGetValueAtIndex(value, i), indent + 4);
        }
    } else if (tid == CFBooleanGetTypeID()) {
        outf("%s%s\n", pad, CFBooleanGetValue(value) ? "true" : "false");
    } else {
        outf("%s<type %lu>\n", pad, (unsigned long)tid);
    }
}

static void copyClassName(io_service_t service, char *buf, size_t bufLen) {
    buf[0] = '\0';
    CFStringRef cls = IOObjectCopyClass(service);
    if (cls) {
        if (!CFStringGetCString(cls, buf, bufLen, kCFStringEncodingUTF8))
            snprintf(buf, bufLen, "<unconvertible>");
        CFRelease(cls);
    }
}

/* Print the chain of (class "name") pairs from this node up to the root, so
 * the node's position in the registry is unambiguous even if the path string
 * fails to resolve. */
static void printParentChain(io_service_t service) {
    outf("  parent chain (leaf -> root):\n");
    io_service_t current = service;
    IOObjectRetain(current);
    int depth = 0;
    while (current && depth < 24) {
        io_name_t name = {0};
        char cls[128];
        IORegistryEntryGetName(current, name);
        copyClassName(current, cls, sizeof(cls));
        outf("    [%d] %s \"%s\"\n", depth, cls, name);

        io_service_t parent = 0;
        kern_return_t kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent);
        IOObjectRelease(current);
        if (kr != KERN_SUCCESS) break;
        current = parent;
        depth++;
    }
    if (current && depth >= 24) IOObjectRelease(current);
}

/* Dump one node's class, name, path and full property table, then recurse
 * into ALL children (no name filter - that filter is exactly what probe 31
 * got wrong for this subtree). Budget checks come first so an exhausted run
 * stops traversing instead of printing per-child cap lines forever. */
static void dumpSubtree(io_service_t service, int depth) {
    if (budgetExhausted || nodesDumped >= MAX_NODES) { budgetExhausted = 1; return; }
    if (depth > MAX_DEPTH) { outf("  (depth cap %d hit)\n", MAX_DEPTH); return; }
    nodesDumped++;

    io_name_t name = {0};
    char cls[128];
    io_string_t path = {0};
    IORegistryEntryGetName(service, name);
    copyClassName(service, cls, sizeof(cls));

    outf("\n--- [depth %d] %s \"%s\" ---\n", depth, cls, name);
    if (IORegistryEntryGetPath(service, kIOServicePlane, path) == KERN_SUCCESS)
        outf("  path: %s\n", path);

    CFMutableDictionaryRef props = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(service, &props,
        kCFAllocatorDefault, 0);
    if (kr != KERN_SUCCESS || !props) {
        outf("  (cannot read properties: 0x%x)\n", kr);
    } else {
        CFIndex n = CFDictionaryGetCount(props);
        outf("  property count: %ld\n", (long)n);
        if (n > 0) {
            const void **keys = malloc(n * sizeof(void*));
            const void **vals = malloc(n * sizeof(void*));
            if (!keys || !vals) {
                outf("  <alloc failed>\n");
                free(keys); free(vals);
            } else {
                CFDictionaryGetKeysAndValues(props, keys, vals);
                for (CFIndex i = 0; i < n; i++) {
                    char kbuf[256];
                    kbuf[0] = '\0';
                    if (!CFStringGetCString(keys[i], kbuf, sizeof(kbuf), kCFStringEncodingUTF8))
                        snprintf(kbuf, sizeof(kbuf), "<unconvertible>");
                    outf("  %s = ", kbuf);
                    printCFType(vals[i], 4);
                }
                free(keys); free(vals);
            }
        }
        CFRelease(props);
    }

    io_iterator_t childIter;
    kr = IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIter);
    if (kr == KERN_SUCCESS) {
        io_service_t child;
        int childCount = 0;
        while ((child = IOIteratorNext(childIter)) != 0) {
            dumpSubtree(child, depth + 1);
            IOObjectRelease(child);
            childCount++;
            if (budgetExhausted) break;
        }
        /* Measured on macOS 26: IOIteratorIsValid is 0 for an iterator that
         * matched nothing at all, so only a warn when something WAS seen
         * distinguishes a mid-walk registry change from an empty result. */
        if (childCount > 0 && !IOIteratorIsValid(childIter))
            outf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(childIter);
    }
}

static void matchAndDump(const char *className, int withParentChain) {
    outf("=== %s ===\n", className);

    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching(className), &iter);
    if (kr != KERN_SUCCESS) {
        outf("  (matching failed: 0x%x)\n\n", kr);
        return;
    }

    int count = 0;
    io_service_t svc;
    while ((svc = IOIteratorNext(iter)) != 0) {
        if (withParentChain) printParentChain(svc);
        dumpSubtree(svc, 0);
        IOObjectRelease(svc);
        count++;
        if (budgetExhausted) break;
    }
    /* Same zero-match IOIteratorIsValid quirk as the child walk above. */
    if (count > 0 && !IOIteratorIsValid(iter))
        outf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
    IOObjectRelease(iter);
    outf("\nmatched instances: %d\n\n", count);
}

int main(void) {
    printf("Running as uid=%d\n\n", getuid());
    bytesOut = 0;

    /* The target class first: direct match, with parent chain so we learn
     * where it hangs even on machines where AppleTypeCPhy sits elsewhere.
     * Ordering also means that if the budget somehow blows, the rare class
     * is what got captured and the commodity subtree is what got cut. */
    matchAndDump("AppleTypeCPhyCIO80PhyMBI", 1);

    /* Then the whole PHY subtree, unfiltered. IOServiceMatching includes
     * subclasses, so this covers every Apple<SoC>TypeCPhy generation. */
    matchAndDump("AppleTypeCPhy", 0);

    /* Plain printf: must survive even when outf() has gone silent. */
    if (budgetExhausted)
        printf("\nWARNING: output budget hit (%ld bytes emitted, byte cap %d, node cap %d, nodes dumped %d); output truncated\n",
               bytesOut, MAX_BYTES, MAX_NODES, nodesDumped);

    return 0;
}
