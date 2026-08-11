// Decode raw PDO (Power Data Object) integers from PortControllerPortPDO
// and watch for IOPortTransportStateUSB3 appearance.
//
// PDOs are 32-bit values defined in USB PD spec:
//   Bits 31:30 = PDO type (00=Fixed, 01=Battery, 10=Variable, 11=APDO)
//   Fixed Supply PDO:
//     Bits 29:22 = Voltage in 50mV units
//     Bits 9:0   = Max current in 10mA units
//     Bit 25     = Dual-Role Power
//     Bit 24     = USB Suspend Supported
//     Bit 23     = Externally Powered
//     Bit 22     = USB Communications Capable
//     Bit 21     = Dual-Role Data
//     Bit 20     = Unchunked Extended Messages Supported
//   APDO (Augmented):
//     Bits 29:28 = APDO type (00=SPR PPS, 01=EPR AVS, 10=SPR AVS)
//     SPR PPS: bits 24:17 = max voltage (100mV), bits 15:8 = min voltage (100mV), bits 6:0 = max current (50mA)
//     EPR AVS: bits 25:17 = max voltage (100mV), bits 15:8 = min voltage (100mV), bits 7:0 = PDP (1W).
//              There is no current field; the low byte is the PDP.
//     SPR AVS: bits 19:10 = max current at 15V (10mA), bits 9:0 = max current at 20V (10mA)
//
// Also watches for USB3 transport state with notifications.
//
// Compile: clang -framework IOKit -framework CoreFoundation -o pdo_decode 19_pdo_decode_and_usb3_watch.c
// Run: ./pdo_decode
// TIP: Plug in a USB3 device (SSD, hub with USB3) while running!

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void decodePDO(uint32_t pdo, int index) {
    if (pdo == 0) return;

    uint32_t type = (pdo >> 30) & 0x3;

    printf("    PDO[%d] = 0x%08x -> ", index, pdo);

    switch (type) {
        case 0: { // Fixed Supply
            uint32_t voltage_50mv = (pdo >> 10) & 0x3FF;
            uint32_t current_10ma = pdo & 0x3FF;
            uint32_t voltage_mv = voltage_50mv * 50;
            uint32_t current_ma = current_10ma * 10;
            uint32_t power_mw = (voltage_mv * current_ma) / 1000;

            int drp = (pdo >> 29) & 1;
            int usbSuspend = (pdo >> 28) & 1;
            int extPowered = (pdo >> 27) & 1;
            int usbComm = (pdo >> 26) & 1;
            int drd = (pdo >> 25) & 1;
            int unchunked = (pdo >> 24) & 1;
            int eprCapable = (pdo >> 23) & 1;

            printf("Fixed %dmV %dmA (%d.%dW)",
                voltage_mv, current_ma, power_mw / 1000, (power_mw % 1000) / 100);

            if (drp) printf(" DRP");
            if (usbSuspend) printf(" USB-Suspend");
            if (extPowered) printf(" Ext-Powered");
            if (usbComm) printf(" USB-Comm");
            if (drd) printf(" DRD");
            if (unchunked) printf(" Unchunked");
            if (eprCapable) printf(" EPR-Capable");
            printf("\n");
            break;
        }
        case 1: { // Battery
            uint32_t maxV = ((pdo >> 20) & 0x3FF) * 50;
            uint32_t minV = ((pdo >> 10) & 0x3FF) * 50;
            uint32_t maxP = (pdo & 0x3FF) * 250;
            printf("Battery %d-%dmV max %dmW\n", minV, maxV, maxP);
            break;
        }
        case 2: { // Variable Supply
            uint32_t maxV = ((pdo >> 20) & 0x3FF) * 50;
            uint32_t minV = ((pdo >> 10) & 0x3FF) * 50;
            uint32_t maxI = (pdo & 0x3FF) * 10;
            printf("Variable %d-%dmV max %dmA\n", minV, maxV, maxI);
            break;
        }
        case 3: { // APDO
            uint32_t apdoType = (pdo >> 28) & 0x3;
            if (apdoType == 0) { // SPR PPS
                uint32_t maxV = ((pdo >> 17) & 0xFF) * 100;
                uint32_t minV = ((pdo >> 8) & 0xFF) * 100;
                uint32_t maxI = (pdo & 0x7F) * 50;
                printf("SPR PPS %d-%dmV max %dmA\n", minV, maxV, maxI);
            } else if (apdoType == 1) { // EPR AVS (Table 6.16)
                uint32_t maxV = ((pdo >> 17) & 0x1FF) * 100; // bits 25:17, 100mV
                uint32_t minV = ((pdo >> 8) & 0xFF) * 100;   // bits 15:8, 100mV
                uint32_t pdp_w = pdo & 0xFF;                 // bits 7:0, PDP in 1W
                printf("EPR AVS %d-%dmV PDP=%dW\n", minV, maxV, pdp_w);
            } else if (apdoType == 2) { // SPR AVS (Table 6.15)
                uint32_t maxI15V = ((pdo >> 10) & 0x3FF) * 10; // bits 19:10, 10mA
                uint32_t maxI20V = (pdo & 0x3FF) * 10;         // bits 9:0, 10mA
                printf("SPR AVS %dmA@15V %dmA@20V\n", maxI15V, maxI20V);
            } else {
                printf("APDO type=%d (unknown)\n", apdoType);
            }
            break;
        }
    }
}

static void printIndent(int depth) {
    for (int i = 0; i < depth; i++) printf("  ");
}

static void dumpCFType(CFTypeRef value, int depth);

static void dumpDict(CFDictionaryRef dict, int depth) {
    CFIndex count = CFDictionaryGetCount(dict);
    const void **keys = malloc(sizeof(void*) * count);
    const void **vals = malloc(sizeof(void*) * count);
    CFDictionaryGetKeysAndValues(dict, keys, vals);
    for (CFIndex i = 0; i < count; i++) {
        char keyBuf[256] = {0};
        if (CFGetTypeID(keys[i]) == CFStringGetTypeID()) {
            if (!CFStringGetCString(keys[i], keyBuf, sizeof(keyBuf), kCFStringEncodingUTF8))
                snprintf(keyBuf, sizeof(keyBuf), "<unconvertible>");
        } else {
            snprintf(keyBuf, sizeof(keyBuf), "<non-string>");
        }
        printIndent(depth);
        printf("%s: ", keyBuf);
        dumpCFType(vals[i], depth);
    }
    free(keys);
    free(vals);
}

static void dumpCFType(CFTypeRef value, int depth) {
    if (!value) { printf("(null)\n"); return; }
    CFTypeID tid = CFGetTypeID(value);

    if (tid == CFStringGetTypeID()) {
        char buf[1024];
        buf[0] = '\0';
        if (CFStringGetCString(value, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            printf("\"%s\"\n", buf);
        } else {
            printf("<unconvertible string>\n");
        }
    } else if (tid == CFNumberGetTypeID()) {
        int64_t val = 0;
        CFNumberGetValue(value, kCFNumberSInt64Type, &val);
        printf("%lld (0x%llx)\n", val, val);
    } else if (tid == CFBooleanGetTypeID()) {
        printf("%s\n", CFBooleanGetValue(value) ? "true" : "false");
    } else if (tid == CFDataGetTypeID()) {
        CFDataRef data = (CFDataRef)value;
        CFIndex len = CFDataGetLength(data);
        const uint8_t *bytes = CFDataGetBytePtr(data);
        printf("<data %ld bytes> [", len);
        for (CFIndex j = 0; j < len && j < 64; j++)
            printf(" %02x", bytes[j]);
        if (len > 64) printf(" ...");
        printf(" ]\n");
    } else if (tid == CFDictionaryGetTypeID()) {
        printf("{\n");
        dumpDict((CFDictionaryRef)value, depth + 1);
        printIndent(depth);
        printf("}\n");
    } else if (tid == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(value);
        printf("[\n");
        for (CFIndex i = 0; i < count; i++) {
            printIndent(depth + 1);
            printf("[%ld] ", i);
            dumpCFType(CFArrayGetValueAtIndex(value, i), depth + 1);
        }
        printIndent(depth);
        printf("]\n");
    } else if (tid == CFSetGetTypeID()) {
        CFIndex count = CFSetGetCount(value);
        const void **vals = malloc(sizeof(void*) * count);
        CFSetGetValues(value, vals);
        printf("<set %ld> {\n", count);
        for (CFIndex i = 0; i < count; i++) {
            printIndent(depth + 1);
            printf("{%ld} ", i);
            dumpCFType(vals[i], depth + 1);
        }
        printIndent(depth);
        printf("}\n");
        free(vals);
    } else {
        CFStringRef desc = CFCopyDescription(value);
        if (desc) {
            char buf[2048];
            buf[0] = '\0';
            if (!CFStringGetCString(desc, buf, sizeof(buf), kCFStringEncodingUTF8))
                snprintf(buf, sizeof(buf), "unconvertible");
            printf("<type %lu> %s\n", tid, buf);
            CFRelease(desc);
        } else {
            printf("<type %lu>\n", tid);
        }
    }
}

// Matching callback for new services appearing
static void matchingCallback(void *refcon, io_iterator_t iterator) {
    io_service_t svc;
    int sawAny = 0;
    while ((svc = IOIteratorNext(iterator))) {
        sawAny = 1;
        io_name_t name = {0};
        IOObjectGetClass(svc, name);
        printf("\n>>> NEW SERVICE: %s\n", name);

        CFMutableDictionaryRef props = NULL;
        kern_return_t kr = IORegistryEntryCreateCFProperties(
            svc, &props, kCFAllocatorDefault, 0);
        if (kr == KERN_SUCCESS && props) {
            dumpDict(props, 1);
            CFRelease(props);
        }

        IOObjectRelease(svc);
    }
    if (sawAny && !IOIteratorIsValid(iterator))
        printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
}

// Interest callback for HPM property changes
static void interestCallback(void *refcon, io_service_t service,
                              uint32_t messageType, void *messageArgument) {
    io_name_t cn = {0};
    IOObjectGetClass(service, cn);

    // Get port number
    int port = 0;
    CFNumberRef pn = (CFNumberRef)IORegistryEntryCreateCFProperty(
        service, CFSTR("PortNumber"), kCFAllocatorDefault, 0);
    if (pn) { CFNumberGetValue(pn, kCFNumberIntType, &port); CFRelease(pn); }

    // Check connection state
    CFBooleanRef active = (CFBooleanRef)IORegistryEntryCreateCFProperty(
        service, CFSTR("ConnectionActive"), kCFAllocatorDefault, 0);
    int isActive = 0;
    if (active) { isActive = CFBooleanGetValue(active); CFRelease(active); }

    // Get transports provisioned
    CFArrayRef tp = (CFArrayRef)IORegistryEntryCreateCFProperty(
        service, CFSTR("TransportsProvisioned"), kCFAllocatorDefault, 0);
    printf("\n>>> Port@%d changed: active=%d transports=[", port, isActive);
    if (tp && CFGetTypeID(tp) == CFArrayGetTypeID()) {
        for (CFIndex i = 0; i < CFArrayGetCount(tp); i++) {
            char buf[64];
            buf[0] = '\0';
            if (!CFStringGetCString(CFArrayGetValueAtIndex(tp, i), buf, sizeof(buf), kCFStringEncodingUTF8))
                snprintf(buf, sizeof(buf), "<unconvertible>");
            printf("%s%s", i > 0 ? ", " : "", buf);
        }
        CFRelease(tp);
    }
    printf("]\n");

    // Get pin config
    CFDictionaryRef pinCfg = (CFDictionaryRef)IORegistryEntryCreateCFProperty(
        service, CFSTR("Pin Configuration"), kCFAllocatorDefault, 0);
    if (pinCfg && CFGetTypeID(pinCfg) == CFDictionaryGetTypeID()) {
        printf("    Pin Config: ");
        const char *pins[] = {"tx1", "rx1", "tx2", "rx2", "sbu1", "sbu2", NULL};
        for (int j = 0; pins[j]; j++) {
            CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, pins[j], kCFStringEncodingUTF8);
            CFNumberRef val = CFDictionaryGetValue(pinCfg, key);
            int v = 0;
            if (val && CFGetTypeID(val) == CFNumberGetTypeID()) CFNumberGetValue(val, kCFNumberIntType, &v);
            printf("%s=%d ", pins[j], v);
            CFRelease(key);
        }
        printf("\n");
        CFRelease(pinCfg);
    }

    // Get plug orientation
    CFNumberRef orient = (CFNumberRef)IORegistryEntryCreateCFProperty(
        service, CFSTR("PlugOrientation"), kCFAllocatorDefault, 0);
    if (orient) {
        int o = 0;
        CFNumberGetValue(orient, kCFNumberIntType, &o);
        printf("    PlugOrientation: %d (%s)\n", o,
            o == 0 ? "unknown" : o == 1 ? "normal" : o == 2 ? "flipped" : "?");
        CFRelease(orient);
    }
}

int main(void) {
    printf("Running as uid=%d\n\n", getuid());

    // 1. Decode PDOs from PortControllerInfo in AppleSmartBattery
    printf("============================================================\n");
    printf("  PDO Decode from AppleSmartBattery.PortControllerInfo\n");
    printf("============================================================\n\n");
    {
        io_iterator_t iter;
        kern_return_t kr = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery"),
            &iter);
        if (kr == KERN_SUCCESS) {
            io_service_t svc;
            int sawAny = 0;
            while ((svc = IOIteratorNext(iter))) {
                sawAny = 1;
                CFArrayRef pcInfo = (CFArrayRef)IORegistryEntryCreateCFProperty(
                    svc, CFSTR("PortControllerInfo"), kCFAllocatorDefault, 0);
                if (pcInfo && CFGetTypeID(pcInfo) == CFArrayGetTypeID()) {
                    CFIndex portCount = CFArrayGetCount(pcInfo);
                    for (CFIndex p = 0; p < portCount; p++) {
                        CFDictionaryRef portDict = CFArrayGetValueAtIndex(pcInfo, p);
                        if (!portDict || CFGetTypeID(portDict) != CFDictionaryGetTypeID()) continue;

                        // Get port mode
                        int portMode = 0;
                        CFNumberRef modeRef = CFDictionaryGetValue(portDict, CFSTR("PortControllerPortMode"));
                        if (modeRef) CFNumberGetValue(modeRef, kCFNumberIntType, &portMode);

                        // Get number of PDOs
                        int nPDOs = 0;
                        CFNumberRef nRef = CFDictionaryGetValue(portDict, CFSTR("PortControllerNPDOs"));
                        if (nRef) CFNumberGetValue(nRef, kCFNumberIntType, &nPDOs);

                        int nEprPDOs = 0;
                        CFNumberRef neRef = CFDictionaryGetValue(portDict, CFSTR("PortControllerNEprPDOs"));
                        if (neRef) CFNumberGetValue(neRef, kCFNumberIntType, &nEprPDOs);

                        // Get max power
                        int maxPower = 0;
                        CFNumberRef mpRef = CFDictionaryGetValue(portDict, CFSTR("PortControllerMaxPower"));
                        if (mpRef) CFNumberGetValue(mpRef, kCFNumberIntType, &maxPower);

                        // Get attach/detach counts
                        int attachCount = 0, detachCount = 0;
                        CFNumberRef acRef = CFDictionaryGetValue(portDict, CFSTR("PortControllerAttachCount"));
                        CFNumberRef dcRef = CFDictionaryGetValue(portDict, CFSTR("PortControllerDetachCount"));
                        if (acRef) CFNumberGetValue(acRef, kCFNumberIntType, &attachCount);
                        if (dcRef) CFNumberGetValue(dcRef, kCFNumberIntType, &detachCount);

                        // Get hard reset count
                        int hardResets = 0;
                        CFNumberRef hrRef = CFDictionaryGetValue(portDict, CFSTR("PortControllerHardResetCount"));
                        if (hrRef) CFNumberGetValue(hrRef, kCFNumberIntType, &hardResets);

                        // Get FW version
                        int fwVer = 0;
                        CFNumberRef fwRef = CFDictionaryGetValue(portDict, CFSTR("PortControllerFwVersion"));
                        if (fwRef) CFNumberGetValue(fwRef, kCFNumberIntType, &fwVer);

                        // Get src types
                        int srcTypes = 0;
                        CFNumberRef stRef = CFDictionaryGetValue(portDict, CFSTR("PortControllerSrcTypes"));
                        if (stRef) CFNumberGetValue(stRef, kCFNumberIntType, &srcTypes);

                        printf("  Port %ld: mode=%d nPDOs=%d nEprPDOs=%d maxPower=%dmW\n",
                            p, portMode, nPDOs, nEprPDOs, maxPower);
                        printf("    FW=0x%06x attach=%d detach=%d hardResets=%d srcTypes=%d\n",
                            fwVer, attachCount, detachCount, hardResets, srcTypes);

                        // Decode PDOs
                        CFArrayRef pdoArray = CFDictionaryGetValue(portDict, CFSTR("PortControllerPortPDO"));
                        if (pdoArray && CFGetTypeID(pdoArray) == CFArrayGetTypeID()) {
                            CFIndex pdoCount = CFArrayGetCount(pdoArray);
                            for (CFIndex i = 0; i < pdoCount; i++) {
                                CFNumberRef pdoRef = CFArrayGetValueAtIndex(pdoArray, i);
                                if (!pdoRef) continue;
                                int64_t pdoVal = 0;
                                CFNumberGetValue(pdoRef, kCFNumberSInt64Type, &pdoVal);
                                decodePDO((uint32_t)pdoVal, (int)i);
                            }
                        }
                        printf("\n");
                    }
                }
                if (pcInfo) CFRelease(pcInfo);

                // Also decode UsbHvcMenu from AdapterDetails
                CFDictionaryRef adapterDetails = (CFDictionaryRef)IORegistryEntryCreateCFProperty(
                    svc, CFSTR("AdapterDetails"), kCFAllocatorDefault, 0);
                if (adapterDetails && CFGetTypeID(adapterDetails) == CFDictionaryGetTypeID()) {
                    printf("  AdapterDetails:\n");

                    char desc[256] = "?";
                    CFStringRef descRef = CFDictionaryGetValue(adapterDetails, CFSTR("Description"));
                    // Keep the "?" fallback rather than a possibly garbled
                    // partial copy if the conversion fails.
                    if (descRef && !CFStringGetCString(descRef, desc, sizeof(desc), kCFStringEncodingUTF8))
                        snprintf(desc, sizeof(desc), "?");

                    int watts = 0, adapterV = 0, adapterI = 0, tier = 0;
                    CFNumberRef wRef = CFDictionaryGetValue(adapterDetails, CFSTR("Watts"));
                    CFNumberRef avRef = CFDictionaryGetValue(adapterDetails, CFSTR("AdapterVoltage"));
                    CFNumberRef aiRef = CFDictionaryGetValue(adapterDetails, CFSTR("Current"));
                    CFNumberRef tRef = CFDictionaryGetValue(adapterDetails, CFSTR("AdapterPowerTier"));
                    if (wRef) CFNumberGetValue(wRef, kCFNumberIntType, &watts);
                    if (avRef) CFNumberGetValue(avRef, kCFNumberIntType, &adapterV);
                    if (aiRef) CFNumberGetValue(aiRef, kCFNumberIntType, &adapterI);
                    if (tRef) CFNumberGetValue(tRef, kCFNumberIntType, &tier);

                    printf("    Description: %s\n", desc);
                    printf("    Voltage: %dmV, Current: %dmA, Power: %dW, Tier: %d\n",
                        adapterV, adapterI, watts, tier);

                    CFArrayRef hvcMenu = CFDictionaryGetValue(adapterDetails, CFSTR("UsbHvcMenu"));
                    if (hvcMenu && CFGetTypeID(hvcMenu) == CFArrayGetTypeID()) {
                        printf("    USB HVC Menu (charger's voltage options):\n");
                        for (CFIndex i = 0; i < CFArrayGetCount(hvcMenu); i++) {
                            CFDictionaryRef entry = CFArrayGetValueAtIndex(hvcMenu, i);
                            if (!entry || CFGetTypeID(entry) != CFDictionaryGetTypeID()) continue;
                            int maxV = 0, maxI = 0, idx = 0;
                            CFNumberRef vRef = CFDictionaryGetValue(entry, CFSTR("MaxVoltage"));
                            CFNumberRef iRef = CFDictionaryGetValue(entry, CFSTR("MaxCurrent"));
                            CFNumberRef idxRef = CFDictionaryGetValue(entry, CFSTR("Index"));
                            if (vRef) CFNumberGetValue(vRef, kCFNumberIntType, &maxV);
                            if (iRef) CFNumberGetValue(iRef, kCFNumberIntType, &maxI);
                            if (idxRef) CFNumberGetValue(idxRef, kCFNumberIntType, &idx);
                            int power = (maxV * maxI) / 1000;
                            printf("      [%d] %dmV / %dmA = %d.%dW\n",
                                idx, maxV, maxI, power / 1000, (power % 1000) / 100);
                        }
                    }
                    CFRelease(adapterDetails);
                }

                IOObjectRelease(svc);
            }
            if (sawAny && !IOIteratorIsValid(iter))
                printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
            IOObjectRelease(iter);
        }
    }

    // 2. Check for USB3 transport state right now
    printf("\n============================================================\n");
    printf("  Current IOPortTransportStateUSB3 (if any)\n");
    printf("============================================================\n\n");
    {
        io_iterator_t iter;
        kern_return_t kr = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOPortTransportStateUSB3"),
            &iter);
        if (kr == KERN_SUCCESS) {
            io_service_t svc;
            int idx = 0;
            while ((svc = IOIteratorNext(iter))) {
                printf("--- IOPortTransportStateUSB3[%d] ---\n", idx);
                CFMutableDictionaryRef props = NULL;
                kr = IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0);
                if (kr == KERN_SUCCESS && props) {
                    dumpDict(props, 1);
                    CFRelease(props);
                }
                IOObjectRelease(svc);
                idx++;
            }
            if (idx > 0 && !IOIteratorIsValid(iter))
                printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
            IOObjectRelease(iter);
            if (idx == 0) printf("  (none present - plug in a USB3 device!)\n");
        }
    }

    // 3. Also check for CIO (Converged I/O) transport
    printf("\n============================================================\n");
    printf("  Current IOPortTransportStateCIO (if any)\n");
    printf("============================================================\n\n");
    {
        io_iterator_t iter;
        kern_return_t kr = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOPortTransportStateCIO"),
            &iter);
        if (kr == KERN_SUCCESS) {
            io_service_t svc;
            int idx = 0;
            while ((svc = IOIteratorNext(iter))) {
                printf("--- IOPortTransportStateCIO[%d] ---\n", idx);
                CFMutableDictionaryRef props = NULL;
                kr = IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0);
                if (kr == KERN_SUCCESS && props) {
                    dumpDict(props, 1);
                    CFRelease(props);
                }
                IOObjectRelease(svc);
                idx++;
            }
            if (idx > 0 && !IOIteratorIsValid(iter))
                printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
            IOObjectRelease(iter);
            if (idx == 0) printf("  (none present - appears with TB/USB4 devices)\n");
        }
    }

    printf("\nDone.\n");
    return 0;
}
