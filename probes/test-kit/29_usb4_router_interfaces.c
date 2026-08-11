/*
 * 29_usb4_router_interfaces.c - Probe USB4 router and hub services.
 * USB4 hubs/docks expose standard USB descriptors. Try to find and read
 * them, including device/config/BOS descriptors via IOUSBHostInterface.
 *
 * Compile: clang -framework IOKit -framework CoreFoundation -o 29_usb4_router_interfaces 29_usb4_router_interfaces.c
 */

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <mach/mach.h>

static void printCFType(CFTypeRef value, int indent) {
    char pad[64] = {0};
    for (int i = 0; i < indent && i < 60; i++) pad[i] = ' ';

    if (!value) { printf("%s(null)\n", pad); return; }

    CFTypeID tid = CFGetTypeID(value);
    if (tid == CFStringGetTypeID()) {
        char buf[512];
        buf[0] = '\0';
        if (!CFStringGetCString(value, buf, sizeof(buf), kCFStringEncodingUTF8))
            snprintf(buf, sizeof(buf), "<unconvertible>");
        printf("%s\"%s\"\n", pad, buf);
    } else if (tid == CFNumberGetTypeID()) {
        long long num = 0;
        CFNumberGetValue(value, kCFNumberLongLongType, &num);
        printf("%s%lld (0x%llx)\n", pad, num, num);
    } else if (tid == CFDataGetTypeID()) {
        CFIndex len = CFDataGetLength(value);
        const UInt8 *bytes = CFDataGetBytePtr(value);
        printf("%sData[%ld]: ", pad, (long)len);
        for (CFIndex i = 0; i < len && i < 64; i++)
            printf("%02x ", bytes[i]);
        if (len > 64) printf("...");
        printf("\n");
    } else if (tid == CFDictionaryGetTypeID()) {
        CFIndex n = CFDictionaryGetCount(value);
        const void **keys = malloc(n * sizeof(void*));
        const void **vals = malloc(n * sizeof(void*));
        CFDictionaryGetKeysAndValues(value, keys, vals);
        for (CFIndex i = 0; i < n; i++) {
            char kbuf[256];
            kbuf[0] = '\0';
            if (!CFStringGetCString(keys[i], kbuf, sizeof(kbuf), kCFStringEncodingUTF8))
                snprintf(kbuf, sizeof(kbuf), "<unconvertible>");
            printf("%s  %s = ", pad, kbuf);
            printCFType(vals[i], indent + 4);
        }
        free(keys); free(vals);
    } else if (tid == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(value);
        for (CFIndex i = 0; i < count; i++) {
            printf("%s  [%ld] ", pad, (long)i);
            printCFType(CFArrayGetValueAtIndex(value, i), indent + 4);
        }
    } else if (tid == CFBooleanGetTypeID()) {
        printf("%s%s\n", pad, CFBooleanGetValue(value) ? "true" : "false");
    } else {
        printf("%s<type %lu>\n", pad, (unsigned long)tid);
    }
}

/* Read a small integer IOKit property as a long. Returns 1 on success.
 * Copied from probe 25 (25_usb_bos_descriptor.c) readIntProperty. */
static int readIntProperty(io_service_t svc, const char *key, long *out) {
    CFStringRef cfKey = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    if (!cfKey) return 0;
    CFTypeRef val = IORegistryEntryCreateCFProperty(svc, cfKey, kCFAllocatorDefault, 0);
    CFRelease(cfKey);
    if (!val) return 0;
    int ok = 0;
    if (CFGetTypeID(val) == CFNumberGetTypeID()) {
        long n = 0;
        if (CFNumberGetValue(val, kCFNumberLongType, &n)) { *out = n; ok = 1; }
    }
    CFRelease(val);
    return ok;
}

/*
 * True if this service is (or carries) a Mass Storage (USB class 0x08) or
 * HID (USB class 0x03) interface. Adapted from probe 25's
 * deviceHasMassStorageInterface: we avoid opening these because
 *   - opening a storage device/interface whose media is mounted as a
 *     removable volume makes macOS (Ventura+) raise the "would like to
 *     access files on a removable volume" privacy prompt.
 *   - opening a HID interface can seize a keyboard or mouse away from its
 *     kernel driver, which is disruptive on the user's live input devices.
 *
 * Storage/HID class can sit directly on the matched service (bDeviceClass on
 * a composite device, or bInterfaceClass on an IOUSBHostInterface matched
 * directly -- this probe's "IOUSBHostInterface" class loop matches
 * interfaces themselves, not their parent device), or on a child interface
 * (bInterfaceClass) when the matched service is a device node reporting
 * class 0x00 ("see interface"). Check both; only walk direct children (not
 * the full subtree), mirroring probe 25's reasoning: a device's interfaces
 * are always direct children, so one level is sufficient and correct.
 */
static int shouldSkipDeviceClass(io_service_t service) {
    enum { kUSBMassStorageClass = 0x08, kUSBHIDClass = 0x03 };

    long deviceClass = 0;
    if (readIntProperty(service, "bDeviceClass", &deviceClass) &&
        (deviceClass == kUSBMassStorageClass || deviceClass == kUSBHIDClass)) {
        return 1;
    }

    long interfaceClass = 0;
    if (readIntProperty(service, "bInterfaceClass", &interfaceClass) &&
        (interfaceClass == kUSBMassStorageClass || interfaceClass == kUSBHIDClass)) {
        return 1;
    }

    io_iterator_t children = 0;
    if (IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) != KERN_SUCCESS) {
        return 0;
    }
    int found = 0;
    int sawAny = 0;
    io_service_t child;
    while ((child = IOIteratorNext(children)) != 0) {
        sawAny = 1;
        long childInterfaceClass = 0;
        if (readIntProperty(child, "bInterfaceClass", &childInterfaceClass) &&
            (childInterfaceClass == kUSBMassStorageClass || childInterfaceClass == kUSBHIDClass)) {
            found = 1;
        }
        IOObjectRelease(child);
        if (found) break;
    }
    if (sawAny && !IOIteratorIsValid(children))
        printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
    IOObjectRelease(children);
    return found;
}

static void dumpService(io_service_t service, const char *label, const char *className) {
    CFMutableDictionaryRef props = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(service, &props,
        kCFAllocatorDefault, 0);
    if (kr != KERN_SUCCESS || !props) return;

    printf("\n--- %s ---\n", label);

    CFIndex n = CFDictionaryGetCount(props);
    const void **keys = malloc(n * sizeof(void*));
    const void **vals = malloc(n * sizeof(void*));
    CFDictionaryGetKeysAndValues(props, keys, vals);
    for (CFIndex i = 0; i < n; i++) {
        char kbuf[256];
        kbuf[0] = '\0';
        if (!CFStringGetCString(keys[i], kbuf, sizeof(kbuf), kCFStringEncodingUTF8))
            snprintf(kbuf, sizeof(kbuf), "<unconvertible>");
        printf("  %s = ", kbuf);
        printCFType(vals[i], 4);
    }
    free(keys); free(vals);
    CFRelease(props);

    // Try opening user client, but skip USB classes carrying a mass-storage
    // or HID class: mirrors probe 25's deviceHasMassStorageInterface guard,
    // extended to HID since opening such a service can trigger the macOS
    // removable-volume privacy prompt (storage), disturb a mounted volume
    // (storage), or seize a keyboard/mouse from its kernel driver (HID).
    // Thunderbolt-native classes (any class name containing "Thunderbolt")
    // are never USB storage/HID devices and keep the existing
    // unconditional-open behaviour.
    int isThunderboltClass = strstr(className, "Thunderbolt") != NULL;
    if (!isThunderboltClass && shouldSkipDeviceClass(service)) {
        printf("  [safety] Mass-storage or HID class detected; skipping IOServiceOpen to "
               "avoid the macOS removable-volume prompt / disturbing input devices\n");
    } else {
        io_connect_t conn;
        kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
        if (kr == KERN_SUCCESS) {
            printf("  ** User client OPEN (type=0) **\n");
            IOServiceClose(conn);
        }
    }
}

// For an IOThunderboltSwitch, emit its own registry entry ID and its parent
// switch's registry entry ID. The parent linkage lives in the IOService-plane
// nesting (a downstream switch sits below its parent), which the flat property
// dump above loses, so the topology tree cannot be rebuilt offline without it.
// Mirrors IOThunderboltSwitchWatcher.parentSwitchEntryID: walk up, match the
// first ancestor whose class is IOThunderboltSwitch* or IOIOThunderboltSwitch*
// (both naming families across Mac generations), take its registry entry ID.
static void dumpSwitchParentage(io_service_t svc) {
    uint64_t entryID = 0;
    IORegistryEntryGetRegistryEntryID(svc, &entryID);
    printf("  RegistryEntryID = %llu (0x%llx)\n",
           (unsigned long long)entryID, (unsigned long long)entryID);

    uint64_t parentEntryID = 0;
    io_service_t current = svc;
    IOObjectRetain(current);
    for (int hop = 0; hop < 32; hop++) {
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
        if (strncmp(cls, "IOIOThunderboltSwitch", 21) == 0 ||
            strncmp(cls, "IOThunderboltSwitch", 19) == 0) {
            IORegistryEntryGetRegistryEntryID(current, &parentEntryID);
            IOObjectRelease(current);
            current = 0;
            break;
        }
    }
    if (current) IOObjectRelease(current);
    printf("  ParentSwitchEntryID = %llu (0x%llx)\n",
           (unsigned long long)parentEntryID, (unsigned long long)parentEntryID);
}

int main(void) {
    printf("Running as uid=%d\n\n", getuid());

    io_iterator_t iter;
    kern_return_t kr;
    io_service_t svc;

    // USB4 / Thunderbolt router classes
    const char *classes[] = {
        "IOThunderboltUSB4Router",
        "IOThunderboltUSB4HostRouter",
        "IOThunderboltUSB4DeviceRouter",
        "AppleUSB4Hub",
        "AppleUSB40HostPort",
        "AppleUSB40DevicePort",
        "IOThunderboltNHI",
        "IOUSBHostInterface",
        "IOThunderboltPort",
        "IOThunderboltSwitch",
        "IOIOThunderboltSwitch",
        "IOThunderboltConnection",
        NULL
    };

    for (int c = 0; classes[c]; c++) {
        printf("=== %s ===\n", classes[c]);
        kr = IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching(classes[c]), &iter);
        if (kr != KERN_SUCCESS) {
            printf("  (not found)\n\n");
            continue;
        }

        int count = 0;
        while ((svc = IOIteratorNext(iter)) != 0) {
            io_name_t name = {0};
            IORegistryEntryGetName(svc, name);
            char label[256];
            snprintf(label, sizeof(label), "%s[%d] \"%s\"", classes[c], count, name);
            dumpService(svc, label, classes[c]);
            // For switches (both the IOThunderboltSwitch* and older
            // IOIOThunderboltSwitch* naming families), also record the parent
            // linkage (entry IDs) the flat property dump drops, so the topology
            // tree can be rebuilt offline.
            if (strcmp(classes[c], "IOThunderboltSwitch") == 0 ||
                strcmp(classes[c], "IOIOThunderboltSwitch") == 0) {
                dumpSwitchParentage(svc);
            }
            IOObjectRelease(svc);
            count++;
            if (count > 5 && strcmp(classes[c], "IOUSBHostInterface") == 0) {
                printf("  ... (truncating, %d+ interfaces)\n", count);
                break;
            }
        }
        if (count > 0 && !IOIteratorIsValid(iter))
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(iter);
        if (count == 0) printf("  (no instances)\n");
        printf("\n");
    }

    return 0;
}
