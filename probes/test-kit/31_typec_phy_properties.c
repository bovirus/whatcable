/*
 * 31_typec_phy_properties.c - Dump all properties from AppleTypeCPhy and
 * related PHY-layer services. The Type-C PHY handles lane/speed negotiation
 * and might expose negotiated link state as registry properties.
 *
 * Compile: clang -framework IOKit -framework CoreFoundation -o 31_typec_phy_properties 31_typec_phy_properties.c
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
        for (CFIndex i = 0; i < len && i < 80; i++)
            printf("%02x ", bytes[i]);
        if (len > 80) printf("...");
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

static void dumpServiceFull(io_service_t service, const char *label) {
    CFMutableDictionaryRef props = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(service, &props,
        kCFAllocatorDefault, 0);
    if (kr != KERN_SUCCESS || !props) {
        printf("  %s: (cannot read properties: 0x%x)\n", label, kr);
        return;
    }

    printf("\n--- %s ---\n", label);

    CFIndex n = CFDictionaryGetCount(props);
    const void **keys = malloc(n * sizeof(void*));
    const void **vals = malloc(n * sizeof(void*));
    CFDictionaryGetKeysAndValues(props, keys, vals);
    printf("  Property count: %ld\n", (long)n);
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

    // Walk children
    io_iterator_t childIter;
    kr = IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIter);
    if (kr == KERN_SUCCESS) {
        io_service_t child;
        int childIdx = 0;
        while ((child = IOIteratorNext(childIter)) != 0) {
            io_name_t childName = {0};
            IORegistryEntryGetName(child, childName);
            char childLabel[256];
            snprintf(childLabel, sizeof(childLabel), "%s -> child[%d] \"%s\"", label, childIdx, childName);
            // Only dump children that look PHY/lane/speed related
            if (strcasestr(childName, "Lane") || strcasestr(childName, "Link") ||
                strcasestr(childName, "Speed") || strcasestr(childName, "PHY") ||
                strcasestr(childName, "Port") || strcasestr(childName, "Retimer")) {
                dumpServiceFull(child, childLabel);
            } else {
                printf("  %s (skipped - not PHY-related)\n", childLabel);
            }
            IOObjectRelease(child);
            childIdx++;
        }
        if (childIdx > 0 && !IOIteratorIsValid(childIter))
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(childIter);
    }
}

int main(void) {
    printf("Running as uid=%d\n\n", getuid());

    io_iterator_t iter;
    kern_return_t kr;
    io_service_t svc;

    const char *classes[] = {
        "AppleT8132TypeCPhy",
        "AppleTypeCPhy",
        "AppleTypeCRetimer",
        "IOPortPhysicalLink",
        "IOPortTransportLinkUSB4",
        "IOPortTransportLinkThunderbolt",
        "IOPortTransportLinkUSB3",
        "IOPortTransportLinkDisplayPort",
        NULL
    };

    for (int c = 0; classes[c]; c++) {
        printf("=== %s ===\n", classes[c]);
        kr = IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching(classes[c]), &iter);
        if (kr != KERN_SUCCESS) {
            printf("  (class not found)\n\n");
            continue;
        }

        int count = 0;
        while ((svc = IOIteratorNext(iter)) != 0) {
            io_name_t name = {0};
            IORegistryEntryGetName(svc, name);
            char label[256];
            snprintf(label, sizeof(label), "%s[%d] \"%s\"", classes[c], count, name);
            dumpServiceFull(svc, label);
            IOObjectRelease(svc);
            count++;
        }
        if (count > 0 && !IOIteratorIsValid(iter))
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(iter);
        if (count == 0) printf("  (no instances)\n");
        printf("\n");
    }

    return 0;
}
