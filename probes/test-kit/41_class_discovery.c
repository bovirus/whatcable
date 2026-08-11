// Discover what IS there, rather than confirm what we expected.
//
// Every other probe in this kit searches for class names somebody wrote down in
// advance. That design cannot find anything it was not already told to look for,
// and the corpus shows the cost.
//
// The SD-card transport node IOPortTransportStateSD appears in zero of 1135
// captures despite existing on every Mac with a card slot. 01_walk_pd_tree.c
// spent its entire life searching "AppleHPMInterfaceType", which is not a real
// class and matched nothing anywhere. And A-series Macs run a port-controller
// class, AppleHPMInterfaceType18, that no probe names: 17_deep_property_dump.c
// is genuinely blind to it, while probe 01 captures it only by accident,
// because it happens to descend from a class probe 01 does name. Data arriving
// under a name nobody recognises is barely better than not arriving.
//
// This probe matches NOTHING. It walks the whole IOService plane and asks the
// kernel to describe what it finds:
//
//   IOObjectCopyClass                     the class an instance ACTUALLY is
//   IOObjectCopySuperclassForClass        its parent class, BY NAME
//   IOObjectCopyBundleIdentifierForClass  the kext that publishes it
//
// The middle one is the point. Apple documents it as using "the OSMetaClass
// system in the kernel to derive the name of the superclass of the class", so
// the kernel will describe a class this program has never heard of. We do not
// need to predict what Apple ships next, only to ask. Walking it repeatedly
// yields the full ancestry, which is what lets an unknown class be filed under
// a family we already understand and matched by its base class thereafter.
//
// Output is class-level only: names, ancestry, kext, and per-class node counts.
// No properties, so this stays small (a few tens of KB) regardless of how much
// hardware is attached.
//
// Compile: clang -framework IOKit -framework CoreFoundation -o class_discovery 41_class_discovery.c

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

// Upper bound on distinct class names. A busy Mac publishes ~450; this is far
// above anything real but bounded, since this runs on machines we do not
// control. If it is ever hit, that is reported rather than silently truncated.
#define kMaxClasses 4096
#define kNameLen    128
// Ancestry depth cap. Real IOKit chains are under 10 deep; this only guards
// against a cycle or a pathological hierarchy.
#define kMaxAncestry 32

static char g_name[kMaxClasses][kNameLen];
static int  g_count[kMaxClasses];
static int  g_classCount = 0;
static int  g_classOverflow = 0;

static int slotFor(const char *className) {
    for (int i = 0; i < g_classCount; i++)
        if (strcmp(g_name[i], className) == 0) return i;
    if (g_classCount >= kMaxClasses) { g_classOverflow = 1; return -1; }
    snprintf(g_name[g_classCount], kNameLen, "%s", className);
    g_count[g_classCount] = 0;
    return g_classCount++;
}

// CFStringGetCString can fail and leaves the buffer unspecified on failure, so
// zero first and check the return rather than trusting the buffer.
static void copyCFString(CFStringRef s, char *out, size_t n) {
    out[0] = '\0';
    if (!s) return;
    if (!CFStringGetCString(s, out, (CFIndex)n, kCFStringEncodingUTF8)) out[0] = '\0';
}

int main(void) {
    io_iterator_t iter = IO_OBJECT_NULL;
    // No matching dictionary at all: the whole plane, recursively.
    kern_return_t kr = IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                                kIORegistryIterateRecursively, &iter);
    if (kr != KERN_SUCCESS) {
        printf("registry iterator failed: kr=0x%x\n", kr);
        return 1;
    }

    long long nodes = 0;
    io_object_t obj;
    while ((obj = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        nodes++;
        io_name_t className = {0};
        if (IOObjectGetClass(obj, className) == KERN_SUCCESS && className[0]) {
            int slot = slotFor(className);
            if (slot >= 0) g_count[slot]++;
        }
        IOObjectRelease(obj);
    }

    // IOKit documents that an iterator becomes invalid if the registry changed
    // while it was being walked. When that happens the capture is PARTIAL, and
    // a partial capture that looks complete is how a missing class gets read as
    // absent hardware. Report it rather than let a reader assume completeness.
    //
    // IOIteratorIsValid also reads false for an iterator that matched nothing
    // at all (see 42_typec_phy_subtree.c), but this iterator walks the whole
    // IOService plane, so it always sees at least the root: nodes==0 here would
    // itself be a bigger problem than a false-positive stale read, so no extra
    // guard is needed on that account.
    int stale = !IOIteratorIsValid(iter);
    IOObjectRelease(iter);

    printf("=== REGISTRY CLASS DISCOVERY ===\n");
    printf("nodes=%lld\n", nodes);
    printf("classes=%d\n", g_classCount);
    // iterator_stale is the numeric field scripts/inspect-probe.py's classes()
    // parses; the TRUNCATED line is the same marker every other probe in this
    // kit prints, so a generic scan for it (not just this probe's own field)
    // also catches this capture.
    printf("iterator_stale=%d%s\n", stale,
           stale ? "  (registry changed mid-walk: capture is PARTIAL)" : "");
    if (stale) {
        printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
    }
    printf("class_table_overflow=%d\n", g_classOverflow);
    printf("\n");

    // One row per class. Tab-separated so a miner can read it without guessing
    // at column widths.
    printf("CLASS\tNODES\tKEXT\tANCESTRY\n");
    for (int i = 0; i < g_classCount; i++) {
        char kext[256] = "";
        CFStringRef cfClass = CFStringCreateWithCString(NULL, g_name[i], kCFStringEncodingUTF8);
        if (cfClass) {
            CFStringRef bundle = IOObjectCopyBundleIdentifierForClass(cfClass);
            copyCFString(bundle, kext, sizeof(kext));
            if (bundle) CFRelease(bundle);
        }

        // Ask the kernel for the inheritance chain. This works for a class this
        // binary has never heard of, which is the entire reason the probe exists.
        char ancestry[1024] = "";
        size_t used = 0;
        CFStringRef current = cfClass ? CFStringCreateCopy(NULL, cfClass) : NULL;
        for (int depth = 0; depth < kMaxAncestry && current; depth++) {
            CFStringRef super = IOObjectCopySuperclassForClass(current);
            CFRelease(current);
            current = super;
            if (!super) break;
            char superName[kNameLen];
            copyCFString(super, superName, sizeof(superName));
            if (!superName[0]) break;
            // snprintf returns the length it WOULD have written, which can
            // exceed the space left. Compare before advancing, so `used` never
            // runs past the buffer and a cut-off chain is marked rather than
            // presented as a complete ancestry.
            size_t remaining = sizeof(ancestry) - used;
            int written = snprintf(ancestry + used, remaining,
                                   "%s%s", used ? " < " : "", superName);
            if (written <= 0) break;
            if ((size_t)written >= remaining) {
                // Write the marker AT the failed append, not at a fixed offset
                // near the end. A fixed final-12-bytes slot would clobber up to
                // 11 bytes of already-complete, valid ancestry whenever the
                // failing append started close to the end. Review demonstrated
                // that with a synthetic harness.
                snprintf(ancestry + used, remaining, " <TRUNCATED");
                used = strlen(ancestry);
                break;
            }
            used += (size_t)written;
        }
        if (current) CFRelease(current);
        if (cfClass) CFRelease(cfClass);

        printf("%s\t%d\t%s\t%s\n",
               g_name[i], g_count[i],
               kext[0] ? kext : "-",
               ancestry[0] ? ancestry : "-");
    }

    return 0;
}
