/*
 * 32_smart_battery_full_keys.c - Dump ALL keys from AppleSmartBattery and
 * IOPMPowerSource. We use some of these keys already but haven't catalogued
 * the full set. There might be per-port power keys we're missing.
 *
 * Compile: clang -framework IOKit -framework CoreFoundation -o 32_smart_battery_full_keys 32_smart_battery_full_keys.c
 */

#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPSKeys.h>
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
        char buf[1024] = {0};
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
    } else if (tid == CFBooleanGetTypeID()) {
        printf("%s%s\n", pad, CFBooleanGetValue(value) ? "true" : "false");
    } else if (tid == CFDictionaryGetTypeID()) {
        CFIndex n = CFDictionaryGetCount(value);
        printf("%sDict[%ld]:\n", pad, (long)n);
        const void **keys = malloc(n * sizeof(void*));
        const void **vals = malloc(n * sizeof(void*));
        CFDictionaryGetKeysAndValues(value, keys, vals);
        for (CFIndex i = 0; i < n; i++) {
            char kbuf[256] = {0};
            if (CFGetTypeID(keys[i]) == CFStringGetTypeID()) {
                if (!CFStringGetCString(keys[i], kbuf, sizeof(kbuf), kCFStringEncodingUTF8))
                    snprintf(kbuf, sizeof(kbuf), "<unconvertible-key>");
            } else {
                snprintf(kbuf, sizeof(kbuf), "<non-string-key>");
            }
            printf("%s  %s = ", pad, kbuf);
            printCFType(vals[i], indent + 4);
        }
        free(keys); free(vals);
    } else if (tid == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(value);
        printf("%sArray[%ld]:\n", pad, (long)count);
        for (CFIndex i = 0; i < count && i < 20; i++) {
            printf("%s  [%ld] ", pad, (long)i);
            printCFType(CFArrayGetValueAtIndex(value, i), indent + 4);
        }
        if (count > 20) printf("%s  ... (%ld more)\n", pad, (long)(count - 20));
    } else {
        printf("%s<type %lu>\n", pad, (unsigned long)tid);
    }
}

int main(void) {
    printf("Running as uid=%d\n\n", getuid());

    io_iterator_t iter;
    kern_return_t kr;
    io_service_t svc;

    // AppleSmartBattery
    printf("=== AppleSmartBattery (full property dump) ===\n");
    kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("AppleSmartBattery"), &iter);
    if (kr == KERN_SUCCESS) {
        int sawAny = 0;
        while ((svc = IOIteratorNext(iter)) != 0) {
            sawAny = 1;
            CFMutableDictionaryRef props = NULL;
            kr = IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0);
            if (kr == KERN_SUCCESS && props) {
                CFIndex n = CFDictionaryGetCount(props);
                printf("  Total keys: %ld\n\n", (long)n);

                const void **keys = malloc(n * sizeof(void*));
                const void **vals = malloc(n * sizeof(void*));
                CFDictionaryGetKeysAndValues(props, keys, vals);

                // Sort keys alphabetically for readability
                for (CFIndex i = 0; i < n; i++) {
                    char kbuf[256] = {0};
                    if (!CFStringGetCString(keys[i], kbuf, sizeof(kbuf), kCFStringEncodingUTF8))
                        snprintf(kbuf, sizeof(kbuf), "<unconvertible-key>");
                    printf("  %s = ", kbuf);
                    printCFType(vals[i], 4);
                }
                free(keys); free(vals);
                CFRelease(props);
            }
            IOObjectRelease(svc);
        }
        if (sawAny && !IOIteratorIsValid(iter))
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(iter);
    } else {
        printf("  (not found)\n");
    }

    // Also check for charger-specific services
    printf("\n\n=== AppleSmartBatteryManager ===\n");
    kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("AppleSmartBatteryManager"), &iter);
    if (kr == KERN_SUCCESS) {
        int sawAny = 0;
        while ((svc = IOIteratorNext(iter)) != 0) {
            sawAny = 1;
            CFMutableDictionaryRef props = NULL;
            kr = IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0);
            if (kr == KERN_SUCCESS && props) {
                CFIndex n = CFDictionaryGetCount(props);
                printf("  Total keys: %ld\n", (long)n);
                const void **keys = malloc(n * sizeof(void*));
                const void **vals = malloc(n * sizeof(void*));
                CFDictionaryGetKeysAndValues(props, keys, vals);
                for (CFIndex i = 0; i < n; i++) {
                    char kbuf[256] = {0};
                    if (!CFStringGetCString(keys[i], kbuf, sizeof(kbuf), kCFStringEncodingUTF8))
                        snprintf(kbuf, sizeof(kbuf), "<unconvertible-key>");
                    printf("  %s = ", kbuf);
                    printCFType(vals[i], 4);
                }
                free(keys); free(vals);
                CFRelease(props);
            }
            IOObjectRelease(svc);
        }
        if (sawAny && !IOIteratorIsValid(iter))
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(iter);
    } else {
        printf("  (not found)\n");
    }

    // Check for AC adapter / charger info
    printf("\n\n=== AppleACAdapter / ChargerData ===\n");
    const char *chargerClasses[] = {
        "AppleACAdapter", "IOPMPowerSource", "ApplePMUCharger", NULL
    };
    for (int c = 0; chargerClasses[c]; c++) {
        kr = IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching(chargerClasses[c]), &iter);
        if (kr == KERN_SUCCESS) {
            int sawAny = 0;
            while ((svc = IOIteratorNext(iter)) != 0) {
                sawAny = 1;
                io_name_t name = {0};
                IORegistryEntryGetName(svc, name);
                printf("\n  --- %s \"%s\" ---\n", chargerClasses[c], name);
                CFMutableDictionaryRef props = NULL;
                kr = IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0);
                if (kr == KERN_SUCCESS && props) {
                    CFIndex n = CFDictionaryGetCount(props);
                    const void **keys = malloc(n * sizeof(void*));
                    const void **vals = malloc(n * sizeof(void*));
                    CFDictionaryGetKeysAndValues(props, keys, vals);
                    for (CFIndex i = 0; i < n; i++) {
                        char kbuf[256] = {0};
                        if (!CFStringGetCString(keys[i], kbuf, sizeof(kbuf), kCFStringEncodingUTF8))
                            snprintf(kbuf, sizeof(kbuf), "<unconvertible-key>");
                        printf("    %s = ", kbuf);
                        printCFType(vals[i], 6);
                    }
                    free(keys); free(vals);
                    CFRelease(props);
                }
                IOObjectRelease(svc);
            }
            if (sawAny && !IOIteratorIsValid(iter))
                printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
            IOObjectRelease(iter);
        }
    }

    return 0;
}
