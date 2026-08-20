/*
 * 27_iopower_management.c - Check IOPowerManagement properties on port services.
 * Each IOService node can have an IOPowerManagement dictionary with current
 * power state info. Check whether HPM/port services expose this.
 *
 * Compile: clang -framework IOKit -framework CoreFoundation -o 27_iopower_management 27_iopower_management.c
 */

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
        for (CFIndex i = 0; i < len && i < 48; i++)
            printf("%02x ", bytes[i]);
        if (len > 48) printf("...");
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

static void checkPowerManagement(io_service_t service, const char *label) {
    // Check IOPowerManagement property
    CFTypeRef pm = IORegistryEntryCreateCFProperty(service,
        CFSTR("IOPowerManagement"), kCFAllocatorDefault, 0);

    if (pm) {
        printf("  %s: IOPowerManagement = ", label);
        printCFType(pm, 4);
        CFRelease(pm);
    }

    // Also check PowerState, CurrentPowerState, DevicePowerState
    const char *powerKeys[] = {
        "IOPowerManagement", "PowerState", "CurrentPowerState",
        "DevicePowerState", "MaxPowerState", "DesiredPowerState",
        "power-state", "power-supply", NULL
    };

    for (int i = 0; powerKeys[i]; i++) {
        CFStringRef key = CFStringCreateWithCString(NULL, powerKeys[i], kCFStringEncodingUTF8);
        CFTypeRef val = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
        if (val && strcmp(powerKeys[i], "IOPowerManagement") != 0) {
            printf("  %s: %s = ", label, powerKeys[i]);
            printCFType(val, 4);
            CFRelease(val);
        } else if (val) {
            CFRelease(val);
        }
        CFRelease(key);
    }
}

int main(void) {
    printf("Running as uid=%d\n\n", getuid());

    io_iterator_t iter;
    kern_return_t kr;
    io_service_t svc;

    const char *classes[] = {
        "AppleHPMARMSPMI",
        "IOPortTransportStateCC",
        "IOPortTransportComponentCC",
        "IOAccessoryManager",
        "AppleTypeCRetimer",
        "AppleT8132TypeCPhy",
        "IOThunderboltController",
        "IOThunderboltPort",
        "AppleUSBHostController",
        "IOUSBHostDevice",
        "IOPortFeaturePowerIn",
        "IOPortFeatureLDCM",
        // Base classes, appended LAST so every header this probe has ever
        // emitted keeps its exact name and position: corpus sweeps read these
        // "=== <class> ===" headers literally. IOServiceMatching matches
        // subclasses, so a base class reaches variants no leaf name covers.
        //
        // AppleHPMARM: the HPM bus transport is per-machine. 58 of the 98
        // corpus machines that ran probe 41 publish AppleHPMARMSPMI, the other
        // 40 publish AppleHPMARMI2C, never both. As a result the
        // AppleHPMARMSPMI section is empty on 500 of 1177 Apple Silicon folders.
        //
        // AppleTypeCPhy: the PHY class is per-die, one per machine, and there
        // are 8 of them in the corpus (T6000, T6040, T6050, T8103, T8112,
        // T8122, T8130, T8132). The AppleT8132TypeCPhy section is empty on
        // 899 of 1177 Apple Silicon folders.
        "AppleHPMARM",
        "AppleTypeCPhy",
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
        int found = 0;
        while ((svc = IOIteratorNext(iter)) != 0) {
            io_name_t name = {0};
            IORegistryEntryGetName(svc, name);
            char label[256];
            snprintf(label, sizeof(label), "[%d] %s", count, name);

            CFMutableDictionaryRef props = NULL;
            kr = IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0);
            if (kr == KERN_SUCCESS && props) {
                // Look for any power-related keys
                CFIndex n = CFDictionaryGetCount(props);
                const void **keys = malloc(n * sizeof(void*));
                const void **vals = malloc(n * sizeof(void*));
                CFDictionaryGetKeysAndValues(props, keys, vals);
                for (CFIndex i = 0; i < n; i++) {
                    char kbuf[256];
                    kbuf[0] = '\0';
                    if (!CFStringGetCString(keys[i], kbuf, sizeof(kbuf), kCFStringEncodingUTF8))
                        snprintf(kbuf, sizeof(kbuf), "<unconvertible>");
                    if (strcasestr(kbuf, "Power") || strcasestr(kbuf, "Current") ||
                        strcasestr(kbuf, "Voltage") || strcasestr(kbuf, "Watt") ||
                        strcasestr(kbuf, "Charge") || strcasestr(kbuf, "Energy")) {
                        if (found == 0) printf("\n");
                        printf("  %s: %s = ", label, kbuf);
                        printCFType(vals[i], 4);
                        found++;
                    }
                }
                free(keys); free(vals);
                CFRelease(props);
            }

            checkPowerManagement(svc, label);
            IOObjectRelease(svc);
            count++;
        }
        if (count > 0 && !IOIteratorIsValid(iter))
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(iter);
        if (found == 0 && count > 0) printf("  (%d services, no power properties)\n", count);
        printf("\n");
    }

    // Walk IOPower plane directly
    printf("=== IOPower plane root children ===\n");
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (root) {
        io_iterator_t childIter;
        kr = IORegistryEntryGetChildIterator(root, "IOPower", &childIter);
        if (kr == KERN_SUCCESS) {
            int count = 0;
            while ((svc = IOIteratorNext(childIter)) != 0) {
                io_name_t name = {0};
                IORegistryEntryGetName(svc, name);
                if (strcasestr(name, "Port") || strcasestr(name, "HPM") ||
                    strcasestr(name, "USB") || strcasestr(name, "Thunder") ||
                    strcasestr(name, "TypeC")) {
                    printf("  [%d] %s\n", count, name);
                    checkPowerManagement(svc, name);
                }
                IOObjectRelease(svc);
                count++;
            }
            if (count > 0 && !IOIteratorIsValid(childIter))
                printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
            IOObjectRelease(childIter);
            printf("  Total IOPower root children: %d\n", count);
        } else {
            printf("  Failed to iterate IOPower plane: 0x%x\n", kr);
        }
        IOObjectRelease(root);
    }

    return 0;
}
