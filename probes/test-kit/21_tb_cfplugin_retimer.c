/*
 * 21_tb_cfplugin_retimer.c - Use IOThunderboltLib CFPlugin to read TB config
 *                            space registers, plus a passive property scan
 *                            for retimer/cable-related keys.
 *
 * Apple's IOThunderboltLib.plugin exports IOThunderboltLibPriv with methods:
 *   configRead(routeString, adapter, space, offset, length, ???)
 *   configWrite(routeString, adapter, space, offset, length, ???)
 *   routerOperation(routeString, opcode, metadata*, data*, dataLen, status*)
 *   findCapability(routeString, ...)
 *
 * This probe loads the plugin as an IOCFPlugIn and attempts to open the
 * CFPlugin interface on an IOThunderboltController, then does a read-only
 * property scan across the IOThunderboltSwitch/Port/Peer/Retimer/Cable/Link
 * classes for retimer/cable-related keys.
 *
 * An earlier version of this probe also sent guessed IOConnectCallMethod
 * selector numbers straight to the live IOThunderboltController user
 * client, hoping one would turn out to be configRead/routerOperation. That
 * is undocumented input to a kernel driver on the user's machine, and the
 * selector survey never actually found a working selector, so it was
 * removed. Everything else here is passive/read-only.
 *
 * Build:  clang -framework IOKit -framework CoreFoundation -o tb_cfplugin probes/21_tb_cfplugin_retimer.c
 * Run:    ./tb_cfplugin
 *         sudo ./tb_cfplugin
 */

#include <stdio.h>
#include <string.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

/* UUID for IOThunderboltLib's custom interface (we need to discover this) */
/* These are common IOCFPlugIn UUIDs */
static CFUUIDRef kIOCFPlugInInterfaceID_ref = NULL;

/* IOThunderboltLib vtable offsets (from the demangled symbols).
 * The sThunderboltLibVTable has these methods in order.
 * We'll try to reverse-engineer the vtable layout. */

/* First, let's just try the standard IOCFPlugIn approach and see what
 * interface UUIDs the plugin responds to. */

static void dump_cf_properties(io_service_t service) {
    CFMutableDictionaryRef props = NULL;
    if (IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS) {
        /* Look for IOCFPlugInTypes which tells us the interface UUID */
        CFDictionaryRef pluginTypes = CFDictionaryGetValue(props, CFSTR("IOCFPlugInTypes"));
        if (pluginTypes) {
            printf("  IOCFPlugInTypes found:\n");
            CFIndex count = CFDictionaryGetCount(pluginTypes);
            const void **keys = malloc(sizeof(void*) * count);
            const void **vals = malloc(sizeof(void*) * count);
            CFDictionaryGetKeysAndValues(pluginTypes, keys, vals);
            for (CFIndex i = 0; i < count; i++) {
                char kbuf[128] = {}, vbuf[128] = {};
                if (!CFStringGetCString(keys[i], kbuf, sizeof(kbuf), kCFStringEncodingUTF8))
                    snprintf(kbuf, sizeof(kbuf), "<unconvertible>");
                if (!CFStringGetCString(vals[i], vbuf, sizeof(vbuf), kCFStringEncodingUTF8))
                    snprintf(vbuf, sizeof(vbuf), "<unconvertible>");
                printf("    %s -> %s\n", kbuf, vbuf);
            }
            free(keys);
            free(vals);
        } else {
            printf("  No IOCFPlugInTypes property\n");
        }

        /* Also check for relevant TB properties while we're here */
        const char *interesting[] = {
            "Route String", "Upstream Port Number", "Max Port Number",
            "Supported Speed", "ThunderboltVersion", "Retimer Count",
            "Cable Type", "Cable Speed", "PORT_CS_18",
            "Link Controller Firmware Version",
            NULL
        };
        for (int i = 0; interesting[i]; i++) {
            CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault,
                interesting[i], kCFStringEncodingUTF8);
            CFTypeRef val = CFDictionaryGetValue(props, key);
            if (val) {
                CFTypeID tid = CFGetTypeID(val);
                if (tid == CFNumberGetTypeID()) {
                    int64_t n = 0;
                    CFNumberGetValue(val, kCFNumberSInt64Type, &n);
                    printf("  %s = %lld (0x%llx)\n", interesting[i], n, n);
                } else if (tid == CFStringGetTypeID()) {
                    char buf[256] = {};
                    if (!CFStringGetCString(val, buf, sizeof(buf), kCFStringEncodingUTF8))
                        snprintf(buf, sizeof(buf), "<unconvertible>");
                    printf("  %s = %s\n", interesting[i], buf);
                } else if (tid == CFDataGetTypeID()) {
                    printf("  %s = <data %ld bytes>\n", interesting[i],
                           CFDataGetLength(val));
                }
            }
            CFRelease(key);
        }

        CFRelease(props);
    }
}

static void try_cfplugin(io_service_t service, const char *label) {
    printf("\n--- %s ---\n", label);

    dump_cf_properties(service);

    /* Try to create a CFPlugIn interface */
    IOCFPlugInInterface **plugIn = NULL;
    SInt32 score = 0;

    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service,
        kIOCFPlugInInterfaceID,
        kIOCFPlugInInterfaceID,
        &plugIn,
        &score
    );
    printf("  IOCreatePlugInInterfaceForService: 0x%x (%s) score=%d\n",
           kr, kr == KERN_SUCCESS ? "SUCCESS" : "failed", score);

    if (kr == KERN_SUCCESS && plugIn) {
        printf("  Plugin interface opened!\n");

        /* Query for the Thunderbolt-specific interface.
         * We need to discover the UUID. Let's try some common ones
         * and also the one from IOCFPlugInTypes. */

        /* Try getting the factory's interface with a NULL UUID to see what happens */
        void *tbInterface = NULL;
        HRESULT hr;

        /* First, try with kIOCFPlugInInterfaceID itself */
        hr = (*plugIn)->QueryInterface(plugIn,
            CFUUIDGetUUIDBytes(kIOCFPlugInInterfaceID),
            &tbInterface);
        printf("  QueryInterface(kIOCFPlugInInterfaceID): hr=0x%x ptr=%p\n",
               (unsigned)hr, tbInterface);

        /* Release */
        IODestroyPlugInInterface(plugIn);
    }
}

/* Walk all TB port services and look for retimer/cable-related properties */
static void check_all_tb_properties(void) {
    printf("\n## Full property scan of all IOThunderbolt services\n");

    const char *classes[] = {
        "IOThunderboltSwitch",
        "IOThunderboltPort",
        "IOThunderboltPath",
        "IOThunderboltPeer",
        "IOThunderboltRetimer",
        "IOThunderboltCable",
        "IOThunderboltLink",
        NULL
    };

    for (int c = 0; classes[c]; c++) {
        io_iterator_t iter;
        CFMutableDictionaryRef match = IOServiceMatching(classes[c]);
        if (!match) continue;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != KERN_SUCCESS)
            continue;

        io_service_t svc;
        int idx = 0;
        while ((svc = IOIteratorNext(iter)) != 0) {
            char name[128] = {};
            IOObjectGetClass(svc, name);
            printf("\n  %s #%d (%s):\n", classes[c], ++idx, name);

            /* Dump ALL properties looking for anything cable/retimer related */
            CFMutableDictionaryRef props = NULL;
            if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS) {
                CFIndex count = CFDictionaryGetCount(props);
                const void **keys = malloc(sizeof(void*) * count);
                const void **vals = malloc(sizeof(void*) * count);
                CFDictionaryGetKeysAndValues(props, keys, vals);

                for (CFIndex i = 0; i < count; i++) {
                    char kbuf[256] = {};
                    if (CFGetTypeID(keys[i]) != CFStringGetTypeID()) continue;
                    if (!CFStringGetCString(keys[i], kbuf, sizeof(kbuf), kCFStringEncodingUTF8))
                        snprintf(kbuf, sizeof(kbuf), "<unconvertible>");

                    /* Filter for interesting keys */
                    if (strstr(kbuf, "etimer") || strstr(kbuf, "able") ||
                        strstr(kbuf, "ink") || strstr(kbuf, "peed") ||
                        strstr(kbuf, "idth") || strstr(kbuf, "ocket") ||
                        strstr(kbuf, "dapter") || strstr(kbuf, "oute") ||
                        strstr(kbuf, "CS_") || strstr(kbuf, "PORT") ||
                        strstr(kbuf, "Capability") || strstr(kbuf, "Version") ||
                        strstr(kbuf, "upported") || strstr(kbuf, "ctive")) {

                        CFTypeRef val = vals[i];
                        CFTypeID tid = CFGetTypeID(val);
                        if (tid == CFNumberGetTypeID()) {
                            int64_t n = 0;
                            CFNumberGetValue(val, kCFNumberSInt64Type, &n);
                            printf("    %s = %lld (0x%llx)\n", kbuf, n, n);
                        } else if (tid == CFStringGetTypeID()) {
                            char vbuf[256] = {};
                            if (!CFStringGetCString(val, vbuf, sizeof(vbuf), kCFStringEncodingUTF8))
                                snprintf(vbuf, sizeof(vbuf), "<unconvertible>");
                            printf("    %s = %s\n", kbuf, vbuf);
                        } else if (tid == CFBooleanGetTypeID()) {
                            printf("    %s = %s\n", kbuf,
                                   CFBooleanGetValue(val) ? "true" : "false");
                        } else if (tid == CFDataGetTypeID()) {
                            CFIndex len = CFDataGetLength(val);
                            const UInt8 *bytes = CFDataGetBytePtr(val);
                            printf("    %s = <data %ld bytes: ", kbuf, len);
                            for (CFIndex b = 0; b < len && b < 32; b++)
                                printf("%02x", bytes[b]);
                            if (len > 32) printf("...");
                            printf(">\n");
                        }
                    }
                }
                free(keys);
                free(vals);
                CFRelease(props);
            }
            IOObjectRelease(svc);
        }
        if (idx > 0 && !IOIteratorIsValid(iter))
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(iter);
    }
}

int main(void) {
    printf("=== Thunderbolt CFPlugin / Config Space Probe ===\n");
    printf("Running as uid=%d\n\n", getuid());

    /* First, scan ALL TB properties to look for retimer/cable-related ones */
    check_all_tb_properties();

    /* Try CFPlugin approach on controllers */
    printf("\n## IOThunderboltController CFPlugin\n");
    {
        io_iterator_t iter;
        CFMutableDictionaryRef match = IOServiceMatching("IOThunderboltController");
        if (match && IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS) {
            io_service_t svc;
            int idx = 0;
            while ((svc = IOIteratorNext(iter)) != 0) {
                char name[128] = {};
                IOObjectGetClass(svc, name);
                char label[256];
                snprintf(label, sizeof(label), "Controller #%d (%s)", ++idx, name);
                try_cfplugin(svc, label);

                IOObjectRelease(svc);
                break; /* Just try the first controller */
            }
            if (idx > 0 && !IOIteratorIsValid(iter))
                printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
            IOObjectRelease(iter);
        }
    }

    printf("\nDone.\n");
    return 0;
}
