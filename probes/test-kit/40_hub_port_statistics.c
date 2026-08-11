// Dump every USB hub node (AppleUSB20Hub / AppleUSB30Hub) and per-downstream-port
// node (AppleUSB20HubPort / AppleUSB30HubPort) in full, together with their whole
// child subtrees. No field filtering: everything the kernel exposes is captured,
// documented or not, because a field that looks useless today can matter for a
// later WhatCable feature or a sibling app.
//
// Why this exists: when a dock or hub throws macOS's "USB Accessories Disabled -
// using too much power" alert, that is a DOWNSTREAM overcurrent, inside the dock,
// on the port an accessory is plugged into. WhatCable's only overcurrent signal
// today is the Mac's OWN port controller (AppleHPMInterface "Overcurrent Count"),
// a step removed from the dock's downstream ports. These hub-port nodes carry a
// per-port "port-statistics" dict with lifetime-cumulative counters, including
// kPortStatOverCurrentCount (downstream overcurrent trips), kPortStatConnectCount
// (per-port plug events), and enumeration/address-failure counts, plus per-port
// current budgets (kUSBWakePortCurrentLimit / kUSBSleepPortCurrentLimit) and the
// hub's total supply (kUSBHubPowerSupply). No probe had ever run
// IORegistryEntryCreateCFProperties on these nodes. The child recursion also
// captures the connected devices behind each port and their interfaces.
//
// Data captured: USB topology, power budgets, health counters, and device
// descriptor strings. Those descriptor strings can include the model / product
// name and serial of an attached accessory. Those are hardware identifiers of a
// peripheral, WhatCable's join keys, the same class of data probes 04 and 38
// already collect on purpose; they identify a device, not a person or their Mac.
// Nothing here reads anything identifying the person or the Mac itself.
//
// A short upward parent chain (class + name + locationID) records which
// hub/controller each root sits under, so an offline replay can tell a dock's
// downstream ports from the Mac's own internal wiring.
//
// Safety mirrors probe 04: a visited-set (dump each node once, break any cycle),
// a depth cap, and a byte budget kept under the collector's output cap so a large
// tree is captured as far as it fits rather than discarded wholesale.
//
// Plain unprivileged registry read: no entitlement, no exclusive-access conflict,
// no USB control transfer. (This describes the original section below,
// which is unchanged. A later section appends a hub-descriptor capture that
// DOES issue a USB control transfer, on the unopened device interface; see
// its own header comment for why that is still safe.)
//
// Compile: clang -framework IOKit -framework CoreFoundation -o 40_hub_port_statistics 40_hub_port_statistics.c

#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_error.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdint.h>
#include <string.h>
#include <ctype.h>

static const long long kByteBudget = 3LL * 1024 * 1024;
// Registry-node recursion cap (runaway backstop; real subtrees are ~10 deep).
static const int kMaxDepth = 48;
// CF property-value recursion cap (nested dicts/arrays within one node). Real
// IOKit property graphs are a few levels deep; this only guards a pathologically
// deep or cyclic container from exhausting the stack before the budget stops it.
static const int kMaxValueDepth = 100;

// Upper bound on how many entries of one property dictionary we will buffer.
// Far above anything real (a busy node publishes tens), low enough that the
// allocation cannot get out of hand on a machine we do not control.
static const size_t kMaxDictEntries = 20000;

static long long g_bytes = 0;
static int g_truncatedNoted = 0;
// Visited-set, sized far above real use (a live multi-hub dock touches a few
// hundred nodes). If it ever saturates, dedup stops but the byte budget still
// hard-caps total output, so it degrades safely.
#define kSeenCap 65536u   /* power of two, for the mask below */
static uint64_t g_seen[kSeenCap];
static size_t g_seenCount = 0;

// printf wrapper that accumulates emitted bytes AND enforces the budget: once the
// budget is reached it emits nothing further, bounding total output to the budget
// plus at most one value's overshoot. overBudget() below prints the one-time
// marker and lets callers break their loops early.
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
        printf("\n[output budget reached: remaining nodes omitted to stay under the collector cap]\n");
    }
    return 1;
}

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

// The upward join context for a root: which hub/controller it sits under. Kept
// light (class + name + locationID); those ancestors are captured in full when
// they are matched as their own roots (here or in probe 04).
static void dumpParents(io_service_t service) {
    if (overBudget()) return;
    emitf("  Parent chain (service plane):\n");
    io_service_t current = service;
    IOObjectRetain(current);
    for (int hop = 0; hop < 8; hop++) {
        io_service_t parent = 0;
        if (IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) != KERN_SUCCESS) {
            IOObjectRelease(current);
            current = 0;
            break;
        }
        IOObjectRelease(current);
        current = parent;

        io_name_t cls = {0}, nm = {0};
        IOObjectGetClass(current, cls);
        IORegistryEntryGetName(current, nm);

        CFTypeRef locRef = IORegistryEntryCreateCFProperty(current, CFSTR("locationID"), kCFAllocatorDefault, 0);
        long long loc = -1;
        if (locRef && CFGetTypeID(locRef) == CFNumberGetTypeID())
            CFNumberGetValue(locRef, kCFNumberLongLongType, &loc);
        if (locRef) CFRelease(locRef);

        emitf("    [%d] class=%s name=%s", hop, cls, nm);
        if (loc >= 0) emitf(" locationID=0x%llx", (unsigned long long)loc);
        emitf("\n");
    }
    if (current) IOObjectRelease(current);
}

// Dump one node (class, name, all properties) then recurse into every child.
//
// `forceOwnProperties` makes this node dump its own properties even if it was
// already reached under some other root. Every explicitly matched root passes 1.
// Without it, a hub or port reached first as another root's descendant had its
// own section reduced to a bare "[already dumped]" line carrying no per-port
// statistics at all, which is the entire point of this probe.
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
            // Stop walking, not just writing: see the note in probe 04.
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
    if (kr != KERN_SUCCESS) {
        emitf("\n(no match / error for class %s)\n", className);
        return;
    }

    io_service_t service;
    int idx = 0;
    while ((service = IOIteratorNext(iter))) {
        if (overBudget()) { IOObjectRelease(service); break; }
        io_name_t name = {0}, cls = {0};
        IORegistryEntryGetName(service, name);
        IOObjectGetClass(service, cls);

        emitf("\n========================================\n");
        emitf("%s[%d] (name: %s, class: %s)\n", className, idx++, name, cls);
        emitf("========================================\n");

        dumpParents(service);
        dumpNode(service, 0, 1);
        IOObjectRelease(service);
    }
    if (idx == 0) emitf("\n(class %s matched but zero instances)\n", className);
    if (idx > 0 && !IOIteratorIsValid(iter))
        emitf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
    IOObjectRelease(iter);
}

// ============================================================================
// Hub descriptor capture (wHubCharacteristics + DeviceRemovable).
//
// Everything above this point is the original probe 40, byte-identical.
// This section is purely additive: new content only, appended after the
// original output, behind its own sentinel header so it cannot be confused
// with the original section grammar (the "################ ClassName" rule
// above is reserved for the original class loop).
//
// Why this exists: DeviceRemovable is the USB spec's per-port "hardwired vs
// user-pluggable" flag (USB 2.0 11.23.2.1 / USB 3.x 10.13.2.1 Hub
// Descriptor). If a dock's internal hub marks its own internal chips'
// downstream ports as non-removable, that is a signal WhatCable could use to
// tell "this is a chip soldered inside the dock" apart from "this is
// something the user plugged into the dock", closing part of the
// multi-chip-dock attribution gap in the Connected-devices tree
// (issue 493 family). Nothing in the probe set captures wHubCharacteristics
// or DeviceRemovable today; this section is the first attempt.
//
// Two independent capture paths, run for every matched hub:
//
//   (a) Registry hint scan. IOKit does not publish a documented property
//       name for the raw hub descriptor (Apple's public USB headers define
//       no such registry key), so this is a best-effort scan: every property
//       on the hub node and on every matched HubPort node is checked for a
//       key name that CONTAINS one of a small set of case-insensitive hints
//       ("removable", "connectable", "hubcharacteristic"). Whatever a given
//       hub driver happens to expose under any such name gets printed
//       verbatim; if nothing matches, that absence is reported explicitly
//       rather than left silent, so a replay can tell "checked, found
//       nothing" apart from "never checked".
//
//   (b) A direct USB GET_DESCRIPTOR(HUB) class request, issued to the hub
//       node's kIOServicePlane PARENT (the IOUSBHostDevice nub the hub
//       driver sits on top of, confirmed against real probe 40 corpus
//       dumps, e.g. m1_macos26.5.2_af) via IOCFPlugIn. This is the same
//       no-open control-transfer pattern probe 25 already uses for the BOS
//       descriptor and that
//       Sources/WhatCableDarwinBackend/Watchers/BillboardDescriptorReader.swift
//       uses in the shipped app: DeviceRequest on the UNOPENED device
//       interface. No USBDeviceOpen/USBDeviceOpenSeize is attempted here.
//       Opening for exclusive access could contend with (or forcibly evict)
//       the kernel hub driver actually running the hub; a passive read-only
//       probe must not risk that. Uses DeviceRequestTO with a finite
//       timeout (kIOUSBDeviceInterfaceID182) rather than plain
//       DeviceRequest, so a hub that never answers cannot hang the probe;
//       stdout is flushed immediately before each request for the same
//       reason, so a watchdog kill mid-request loses only what has not
//       been flushed rather than the whole probe's buffered output. If the
//       request is refused, times out, or the reply fails validation
//       (wrong descriptor type, implausible length), that is reported
//       per-hub as "hub descriptor: unavailable (<reason>)" / "reply
//       invalid (<reason>)" and the probe moves on. Never lets one hub's
//       failure stop the loop or crash the probe.
//
// descriptor type 0x29 = USB 2.0 hub descriptor (AppleUSB20Hub), 0x2A =
// SuperSpeed hub descriptor (AppleUSB30Hub); see USBSpec.h kUSBHUBDesc /
// kUSB3HUBDesc, which alias AppleUSBDefinitions.h
// kIOUSBDescriptorTypeHub / kIOUSBDescriptorTypeSuperSpeedHub (41 / 42).

// Case-insensitive substring search, no allocation, bounded by strnlen so a
// non-terminated or oversized key can never run this off the end of a page.
static int containsHintCI(const char *hay, const char *needleLower) {
    if (!hay || !needleLower) return 0;
    size_t hayLen = strnlen(hay, 512);
    size_t needleLen = strlen(needleLower);
    if (needleLen == 0 || needleLen > hayLen) return 0;
    for (size_t i = 0; i + needleLen <= hayLen; i++) {
        size_t j = 0;
        for (; j < needleLen; j++) {
            if (tolower((unsigned char)hay[i + j]) != needleLower[j]) break;
        }
        if (j == needleLen) return 1;
    }
    return 0;
}

static const char *const kDescriptorKeyHints[] = {
    "removable",
    "connectable",
    "hubcharacteristic",
    NULL
};

// Scan one node's OWN properties (no recursion into children) for any key
// whose name contains one of kDescriptorKeyHints. Prints matches; returns
// the number of matches so the caller can report "none found" explicitly.
static int scanNodeForHubDescriptorHints(io_service_t service, int indent) {
    if (overBudget()) return 0;
    CFMutableDictionaryRef props = NULL;
    if (IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) != KERN_SUCCESS || !props) {
        return 0;
    }
    CFIndex count = CFDictionaryGetCount(props);
    int matches = 0;
    if (count > 0 && (size_t)count <= kMaxDictEntries) {
        const void **keys = malloc(sizeof(void*) * (size_t)count);
        const void **vals = malloc(sizeof(void*) * (size_t)count);
        if (keys && vals) {
            CFDictionaryGetKeysAndValues(props, keys, vals);
            for (CFIndex i = 0; i < count; i++) {
                if (overBudget()) break;
                if (CFGetTypeID(keys[i]) != CFStringGetTypeID()) continue;
                char keyBuf[256];
                keyBuf[0] = '\0';
                if (!CFStringGetCString(keys[i], keyBuf, sizeof(keyBuf), kCFStringEncodingUTF8)) continue;
                int isHint = 0;
                for (int h = 0; kDescriptorKeyHints[h]; h++) {
                    if (containsHintCI(keyBuf, kDescriptorKeyHints[h])) { isHint = 1; break; }
                }
                if (!isHint) continue;
                matches++;
                for (int j = 0; j < indent; j++) emitf("  ");
                emitf("hint match \"%s\": ", keyBuf);
                dumpValue(vals[i], indent + 1, 0);
            }
        }
        free(keys);
        free(vals);
    } else if (count > (CFIndex)kMaxDictEntries) {
        emitf("  <property dictionary too large to scan: %ld entries>\n", (long)count);
    }
    CFRelease(props);
    return matches;
}

// Human-readable string for an IOReturn / kern_return_t. mach_error_string
// always returns a non-NULL string (falling back to a generic description
// for codes it does not recognise), so this never needs a NULL guard.
static const char *ioReturnDescription(kern_return_t kr) {
    return mach_error_string(kr);
}

static void indentf(int indent) {
    for (int j = 0; j < indent; j++) emitf("  ");
}

// The largest request this section will ever issue: the fixed 7-byte
// descriptor prefix plus the widest possible USB 2.0 DeviceRemovable
// bitmap, ceil((255+1)/8) = 32 bytes, giving 39. 71 is a deliberately
// generous cap well above that real maximum (it happens to match the
// worst-case FULL USB 2.0 hub descriptor, prefix + DeviceRemovable +
// PortPwrCtrlMask, 7+32+32, even though this probe never reads
// PortPwrCtrlMask) so a future field added to this section has headroom
// without another buffer-size argument.
// A #define, not a const variable: C has no true compile-time constants, so
// a `static const` here would make the buf[] declaration below a
// variable-length array (clang warns: "folded to constant array as an
// extension"). A plain macro keeps it a real fixed-size array.
#define kHubDescriptorBufferCap 71

// Corpus-confirmed (e.g. m1_macos26.5.2_af, probe 40 raw dumps):
// AppleUSB20Hub / AppleUSB30Hub's direct kIOServicePlane parent IS the
// IOUSBHostDevice nub. IOCFPlugIn device interfaces are created from that
// nub, not from the hub driver instance sitting below it, so the plugin
// must be created from the PARENT, never from hubService itself.
//
// Returns 1 and an IOObjectRetain'd parent in *outParent on success; the
// caller owns that reference and must IOObjectRelease it. Returns 0 (and
// prints a tagged line) if the parent is absent or does not conform to
// IOUSBHostDevice. Per the corpus this must never happen, but the point of
// this whole section is to distinguish "checked, found nothing" from
// "never checked", so the failure path is reported explicitly rather than
// silently skipped.
static int findUSBHostDeviceParent(io_service_t hubService, int indent, io_service_t *outParent) {
    *outParent = 0;
    io_service_t parent = 0;
    kern_return_t kr = IORegistryEntryGetParentEntry(hubService, kIOServicePlane, &parent);
    if (kr != KERN_SUCCESS || !parent) {
        indentf(indent);
        emitf("hub descriptor: unavailable (no service-plane parent: %s)\n", ioReturnDescription(kr));
        return 0;
    }
    if (!IOObjectConformsTo(parent, "IOUSBHostDevice")) {
        io_name_t cls = {0};
        IOObjectGetClass(parent, cls);
        indentf(indent);
        emitf("hub descriptor: unavailable (service-plane parent class %s does not conform to IOUSBHostDevice)\n", cls);
        IOObjectRelease(parent);
        return 0;
    }
    *outParent = parent;
    return 1;
}

// Issue one GET_DESCRIPTOR(HUB) class request for `want` bytes into `buf`
// (buf must hold at least `want` bytes). Uses DeviceRequestTO with a finite
// timeout (kIOUSBDeviceInterfaceID182+) so a hub that never answers cannot
// hang the probe; a plain DeviceRequest has no timeout and would block
// forever on an unresponsive hub. fflush(stdout) runs immediately before
// the request: the probe's stdout is fully buffered once piped (the normal
// test-kit runner path), so a watchdog kill mid-request would otherwise
// lose ALL of probe 40's buffered output, including the original section
// above, not just this one request.
static kern_return_t requestHubDescriptorBytes(IOUSBDeviceInterface182 **dev, uint8_t descType,
                                                UInt8 *buf, UInt16 want, UInt32 *outGot) {
    IOUSBDevRequestTO req;
    memset(&req, 0, sizeof(req));
    req.bmRequestType    = USBmakebmRequestType(kUSBIn, kUSBClass, kUSBDevice);
    req.bRequest         = kUSBRqGetDescriptor;
    req.wValue           = (UInt16)(descType << 8);
    req.wIndex           = 0;
    req.wLength          = want;
    req.pData            = buf;
    req.noDataTimeout    = 3000;  // milliseconds
    req.completionTimeout = 3000; // milliseconds
    fflush(stdout);
    kern_return_t kr = (*dev)->DeviceRequestTO(dev, &req);
    *outGot = req.wLenDone;
    return kr;
}

// Validates one GET_DESCRIPTOR(HUB) reply before any field is parsed from
// it, and returns the number of bytes safe to read: min(wLenDone,
// requested, bLength). Returns 0 (and prints a tagged line) if the reply
// cannot be trusted at all, e.g. a device that claims to have sent more
// than was requested, or a descriptor type / length mismatch.
static UInt32 validateHubDescriptorReply(const UInt8 *buf, UInt32 wLenDone, UInt16 requested,
                                          uint8_t expectedType, int indent) {
    if (wLenDone > requested) {
        indentf(indent);
        emitf("hub descriptor: reply invalid (wLenDone %u exceeds the %u bytes requested)\n",
              (unsigned)wLenDone, (unsigned)requested);
        return 0;
    }
    if (wLenDone < 2) {
        indentf(indent);
        emitf("hub descriptor: reply too short to contain a descriptor header (got %u bytes)\n",
              (unsigned)wLenDone);
        return 0;
    }
    uint8_t bLength = buf[0];
    uint8_t bDescriptorType = buf[1];
    if (bDescriptorType != expectedType) {
        indentf(indent);
        emitf("hub descriptor: reply invalid (bDescriptorType 0x%02x, expected 0x%02x)\n",
              bDescriptorType, expectedType);
        return 0;
    }
    if (bLength < 7) {
        indentf(indent);
        emitf("hub descriptor: reply invalid (bLength %u, expected >= 7)\n", bLength);
        return 0;
    }
    UInt32 usable = wLenDone;
    if ((UInt32)requested < usable) usable = requested;
    if ((UInt32)bLength < usable) usable = bLength;
    return usable;
}

// Attempt the class-specific GET_DESCRIPTOR(HUB) request against one hub's
// upstream device nub. descType is 0x29 (USB2) or 0x2A (SuperSpeed).
static void attemptHubDescriptorRequest(io_service_t hubService, uint8_t descType, int indent) {
    if (overBudget()) return;

    io_service_t deviceNub = 0;
    if (!findUSBHostDeviceParent(hubService, indent, &deviceNub)) return;

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        deviceNub, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(deviceNub);
    if (kr != KERN_SUCCESS || !plugin) {
        if (plugin) IODestroyPlugInInterface(plugin);
        indentf(indent);
        emitf("hub descriptor: unavailable (no device interface: %s)\n", ioReturnDescription(kr));
        return;
    }

    IOUSBDeviceInterface182 **dev = NULL;
    HRESULT hr = (*plugin)->QueryInterface(
        plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID182), (LPVOID *)&dev);
    IODestroyPlugInInterface(plugin);
    if (hr || !dev) {
        if (dev) (*dev)->Release(dev);
        indentf(indent);
        emitf("hub descriptor: unavailable (QueryInterface(182) failed: 0x%lx)\n", (long)hr);
        return;
    }

    // No USBDeviceOpen: see the section header comment. This mirrors probe
    // 25's BOS fetch and BillboardDescriptorReader.swift, both of which issue
    // DeviceRequest(TO) on the unopened interface successfully in production.
    UInt8 buf[kHubDescriptorBufferCap];
    memset(buf, 0, sizeof(buf));

    if (descType == kIOUSBDescriptorTypeSuperSpeedHub) {
        // SuperSpeed: bLength(0) bDescriptorType(1) bNumberPorts(2)
        // wHubCharacteristics(3-4) bPowerOnToPowerGood(5)
        // bHubControllerCurrent(6) bHubDecodeLatency(7) wHubDelay(8-9)
        // DeviceRemovable(10-11), a fixed 16-bit field regardless of port
        // count (USB 3.x Table 10-12). One request is enough.
        UInt16 want = 12;
        UInt32 got = 0;
        kr = requestHubDescriptorBytes(dev, descType, buf, want, &got);
        if (kr != kIOReturnSuccess) {
            indentf(indent);
            emitf("hub descriptor: unavailable (GET_DESCRIPTOR(0x%02x) failed: %s)\n",
                  descType, ioReturnDescription(kr));
            (*dev)->Release(dev);
            return;
        }
        indentf(indent);
        emitf("hub descriptor: GET_DESCRIPTOR(0x%02x) returned %u bytes: ", descType, (unsigned)got);
        for (UInt32 i = 0; i < got && i < sizeof(buf); i++) emitf("%02x", buf[i]);
        emitf("\n");

        UInt32 usable = validateHubDescriptorReply(buf, got, want, descType, indent);
        if (usable >= 12) {
            uint8_t numPorts = buf[2];
            uint16_t hubChar = (uint16_t)(buf[3] | (buf[4] << 8));
            uint16_t removable = (uint16_t)(buf[10] | (buf[11] << 8));
            indentf(indent);
            emitf("  bNumberPorts=%u wHubCharacteristics=0x%04x DeviceRemovable=0x%04x\n",
                  numPorts, hubChar, removable);
            for (int p = 1; p <= numPorts && p < 16; p++) {
                int bit = (removable >> p) & 1;
                indentf(indent);
                emitf("    port %d: DeviceRemovable bit=%d (%s per USB 3.x Table 10-12)\n",
                      p, bit, bit ? "non-removable/hardwired" : "removable");
            }
        } else if (usable > 0) {
            indentf(indent);
            emitf("  too few usable bytes to decode DeviceRemovable (usable=%u, need >= 12)\n", (unsigned)usable);
        }
    } else {
        // USB 2.0: bLength(0) bDescriptorType(1) bNumberPorts(2)
        // wHubCharacteristics(3-4) bPowerOnToPowerGood(5)
        // bHubControllerCurrent(6) DeviceRemovable[](7..) PortPwrCtrlMask[](after).
        // DeviceRemovable is variable-length (USB 2.0 Table 11-13), so the
        // port count has to be read before the second field can be sized:
        // stage A fetches the fixed 7-byte prefix, stage B fetches
        // DeviceRemovable itself now that bNumberPorts is known.
        UInt16 prefixWant = 7;
        UInt32 prefixGot = 0;
        kr = requestHubDescriptorBytes(dev, descType, buf, prefixWant, &prefixGot);
        if (kr != kIOReturnSuccess) {
            indentf(indent);
            emitf("hub descriptor: unavailable (GET_DESCRIPTOR(0x%02x) prefix failed: %s)\n",
                  descType, ioReturnDescription(kr));
            (*dev)->Release(dev);
            return;
        }
        UInt32 prefixUsable = validateHubDescriptorReply(buf, prefixGot, prefixWant, descType, indent);
        if (prefixUsable < 7) {
            indentf(indent);
            emitf("  too few usable bytes to read bNumberPorts (usable=%u, need >= 7)\n", (unsigned)prefixUsable);
            (*dev)->Release(dev);
            return;
        }

        uint8_t numPorts = buf[2];
        uint16_t hubChar = (uint16_t)(buf[3] | (buf[4] << 8));
        indentf(indent);
        emitf("  bNumberPorts=%u wHubCharacteristics=0x%04x\n", numPorts, hubChar);

        // ceil((numPorts + 1) / 8): bit 0 reserved, one bit per port
        // starting at bit 1.
        UInt16 bitmapBytes = (UInt16)((numPorts + 1 + 7) / 8);
        UInt16 fullWant = (UInt16)(7 + bitmapBytes);
        if (fullWant > kHubDescriptorBufferCap) fullWant = kHubDescriptorBufferCap;

        UInt32 fullGot = 0;
        kr = requestHubDescriptorBytes(dev, descType, buf, fullWant, &fullGot);
        if (kr != kIOReturnSuccess) {
            indentf(indent);
            emitf("hub descriptor: unavailable (GET_DESCRIPTOR(0x%02x) DeviceRemovable fetch failed: %s)\n",
                  descType, ioReturnDescription(kr));
            (*dev)->Release(dev);
            return;
        }
        indentf(indent);
        emitf("hub descriptor: GET_DESCRIPTOR(0x%02x) returned %u bytes: ", descType, (unsigned)fullGot);
        for (UInt32 i = 0; i < fullGot && i < sizeof(buf); i++) emitf("%02x", buf[i]);
        emitf("\n");

        UInt32 usable = validateHubDescriptorReply(buf, fullGot, fullWant, descType, indent);
        // Per USB 2.0 Table 11-13: bit value 1 = device attached to that
        // port is non-removable (hardwired), 0 = removable. Printed as raw
        // bytes plus the per-port read so either can be checked against
        // the spec independently.
        if (usable >= 7) {
            UInt32 availableBitmapBytes = usable - 7;
            if (availableBitmapBytes > bitmapBytes) availableBitmapBytes = bitmapBytes;
            if (availableBitmapBytes > 0) {
                indentf(indent);
                emitf("  DeviceRemovable bytes: ");
                for (UInt32 i = 0; i < availableBitmapBytes; i++) emitf("%02x", buf[7 + i]);
                emitf("\n");
                for (int p = 1; p <= numPorts; p++) {
                    UInt32 byteIdx = (UInt32)(p / 8);
                    int bitIdx = p % 8;
                    if (byteIdx >= availableBitmapBytes) break;
                    int bit = (buf[7 + byteIdx] >> bitIdx) & 1;
                    indentf(indent);
                    emitf("    port %d: DeviceRemovable bit=%d (%s per USB 2.0 Table 11-13)\n",
                          p, bit, bit ? "non-removable/hardwired" : "removable");
                }
            } else {
                indentf(indent);
                emitf("  DeviceRemovable: no bitmap bytes returned\n");
            }
        } else if (usable > 0) {
            indentf(indent);
            emitf("  DeviceRemovable: not enough usable bytes to decode (usable=%u)\n", (unsigned)usable);
        }
    }

    (*dev)->Release(dev);
}

// One hub (AppleUSB20Hub or AppleUSB30Hub): run both capture paths.
static void captureHubDescriptor(io_service_t hubService, const char *className, int index) {
    if (overBudget()) return;
    io_name_t name = {0};
    IORegistryEntryGetName(hubService, name);
    emitf("\n%s[%d] (name: %s):\n", className, index, name);

    int isSuperSpeed = (strcmp(className, "AppleUSB30Hub") == 0);
    uint8_t descType = isSuperSpeed
        ? (uint8_t)kIOUSBDescriptorTypeSuperSpeedHub
        : (uint8_t)kIOUSBDescriptorTypeHub;

    emitf("  registry hint scan (hub node itself):\n");
    int hits = scanNodeForHubDescriptorHints(hubService, 2);
    if (hits == 0) {
        emitf("    (no property key on this node matched a removable/connectable/hubcharacteristic hint)\n");
    }

    attemptHubDescriptorRequest(hubService, descType, 1);
}

// Every matched HubPort node under the whole registry (not just this hub's
// own children): same hint scan as the hub node, so a per-port removable
// flag published on the PORT rather than the hub is still caught. Matches
// the flat class-iteration style already used by dumpAllMatchingServices
// above, so no parent/child correlation is assumed.
static void captureHubPortHints(const char *className) {
    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iter);
    if (kr != KERN_SUCCESS) {
        // Same wording as the hub loop in captureAllHubDescriptors below, so
        // a "matching failed" result reads the same way in both places
        // rather than looking like silent, unchecked absence.
        emitf("  (no match / error for class %s)\n", className);
        return;
    }

    io_service_t service;
    int idx = 0;
    int any = 0;
    while ((service = IOIteratorNext(iter))) {
        if (overBudget()) { IOObjectRelease(service); break; }
        int hits = scanNodeForHubDescriptorHints(service, 1);
        if (hits > 0) any = 1;
        idx++;
        IOObjectRelease(service);
    }
    if (idx > 0 && !IOIteratorIsValid(iter))
        emitf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
    IOObjectRelease(iter);
    if (idx == 0) {
        emitf("  (class %s matched but zero instances)\n", className);
    } else if (!any) {
        emitf("  %d %s node(s) scanned, none had a removable/connectable/hubcharacteristic hint\n", idx, className);
    }
}

static void captureAllHubDescriptors(void) {
    emitf("\n\n=== Hub descriptors (DeviceRemovable) ===\n");
    emitf("wHubCharacteristics and the per-port DeviceRemovable bitmap for every\n");
    emitf("matched hub, via (a) a registry property-key hint scan and (b) a direct\n");
    emitf("USB GET_DESCRIPTOR(HUB) class request. Empty when no hub is attached.\n");

    const char *hubClasses[] = { "AppleUSB20Hub", "AppleUSB30Hub", NULL };
    for (int c = 0; hubClasses[c]; c++) {
        if (overBudget()) break;
        io_iterator_t iter;
        kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(hubClasses[c]), &iter);
        if (kr != KERN_SUCCESS) {
            emitf("\n(no match / error for class %s)\n", hubClasses[c]);
            continue;
        }
        io_service_t service;
        int idx = 0;
        while ((service = IOIteratorNext(iter))) {
            if (overBudget()) { IOObjectRelease(service); break; }
            captureHubDescriptor(service, hubClasses[c], idx++);
            IOObjectRelease(service);
        }
        if (idx == 0) emitf("\n(class %s matched but zero instances)\n", hubClasses[c]);
        if (idx > 0 && !IOIteratorIsValid(iter))
            emitf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(iter);
    }

    emitf("\nPer-port registry hint scan (HubPort classes, independent of hub above):\n");
    const char *portClasses[] = { "AppleUSB20HubPort", "AppleUSB30HubPort", NULL };
    for (int c = 0; portClasses[c]; c++) {
        if (overBudget()) break;
        emitf(" %s:\n", portClasses[c]);
        captureHubPortHints(portClasses[c]);
    }
}

int main(void) {
    emitf("=== USB hub per-downstream-port statistics (full subtree) ===\n");
    emitf("AppleUSB2x/3xHub + AppleUSB2x/3xHubPort roots, each with its parent\n");
    emitf("chain and full child subtree. Empty when no hub or dock is attached.\n");

    const char *classes[] = {
        "AppleUSB20HubPort",
        "AppleUSB30HubPort",
        "AppleUSB20Hub",
        "AppleUSB30Hub",
        NULL
    };
    for (int i = 0; classes[i]; i++) {
        if (overBudget()) break;
        emitf("\n\n################ %s ################\n", classes[i]);
        dumpAllMatchingServices(classes[i]);
    }

    // Additive only: everything above this call is the original,
    // byte-identical probe 40 output. New hub descriptor capture below.
    captureAllHubDescriptors();

    return 0;
}
