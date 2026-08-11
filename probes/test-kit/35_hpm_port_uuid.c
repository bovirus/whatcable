// Map each USB-C / MagSafe port to its power-controller identity.
//
// Why this exists: on desktop Macs the per-port power-out readings live in the
// SMC (probe 34: DxJV volts, DxJI amps, DxUI a UUID per channel). But the SMC
// channel numbers (D1..D4) do NOT line up with the physical port numbers
// (Port-USB-C@N). On Apple Silicon M3 and later, each port's power controller
// (class AppleHPMDeviceHALType3) carries a stable UUID, and that same UUID is
// the SMC channel's DxUI:
//
//     Port-USB-C@N  <-  AppleHPMDeviceHALType3.UUID  ==  SMC DxUI  ->  watts
//
// Matching the two UUIDs ties a power channel to the right physical port with
// no guessing. This probe captures the port half of that join.
//
// M1 / M2 use an older controller class (AppleHPMDevice) that may not carry the
// stable UUID. To find out what those machines expose, this probe matches the
// BASE class AppleHPMDevice, which also catches the M3+ AppleHPMDeviceHALType3
// subclass, prints each node's actual class, and reads both the controller UUID
// and the port node's ConnectionUUID (a per-connection id seen on both
// generations). That tells us whether a stable port identity exists on M1/M2.
//
// Compile: clang -framework IOKit -framework CoreFoundation -o 35_hpm_port_uuid 35_hpm_port_uuid.c

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>

// Copy a CFString property into buf. Returns 1 on success, 0 otherwise.
static int readStringProp(io_service_t s, CFStringRef key, char *buf, size_t n) {
    buf[0] = '\0';
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    int ok = 0;
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
        ok = CFStringGetCString(v, buf, n, kCFStringEncodingUTF8) ? 1 : 0;
    }
    if (v) CFRelease(v);
    return ok;
}

// Read a CFNumber property as long long. Returns 1 on success.
static int readNumberProp(io_service_t s, CFStringRef key, long long *out) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    int ok = 0;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
        ok = CFNumberGetValue(v, kCFNumberLongLongType, out);
    }
    if (v) CFRelease(v);
    return ok;
}

// Walk descendants looking for a "Description" property that contains "@",
// e.g. "Port-USB-C@1/CC". Used as a fallback when the port node's location
// in the IOService plane is empty. Returns 1 if found.
static int findDescriptionWithLocation(io_service_t service, int depth, char *out, size_t n) {
    if (depth > 4) return 0;

    char desc[256];
    if (readStringProp(service, CFSTR("Description"), desc, sizeof(desc))) {
        if (strchr(desc, '@') != NULL) {
            // Trim at the first '/' so we keep just "Port-USB-C@N".
            char *slash = strchr(desc, '/');
            if (slash) *slash = '\0';
            snprintf(out, n, "%s", desc);
            return 1;
        }
    }

    io_iterator_t childIter;
    if (IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIter) == KERN_SUCCESS) {
        io_service_t child;
        int found = 0;
        int sawAny = 0;
        while ((child = IOIteratorNext(childIter))) {
            sawAny = 1;
            if (!found && findDescriptionWithLocation(child, depth + 1, out, n)) {
                found = 1;
            }
            IOObjectRelease(child);
        }
        if (sawAny && !IOIteratorIsValid(childIter))
            printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
        IOObjectRelease(childIter);
        if (found) return 1;
    }
    return 0;
}

// Inspect a controller's child port. Fills `label` with the port name
// (Port-USB-C@N or Port-MagSafe 3@N) and `connUUID` with the port node's
// ConnectionUUID, a per-connection id present on both M1 and M3+. Either is
// left at "(none)" when not found.
static void resolvePort(io_service_t hpm, char *label, size_t labelN,
                        char *connUUID, size_t connN) {
    snprintf(label, labelN, "(no port child)");
    snprintf(connUUID, connN, "(none)");

    io_iterator_t childIter;
    if (IORegistryEntryGetChildIterator(hpm, kIOServicePlane, &childIter) != KERN_SUCCESS) {
        return;
    }

    io_service_t child;
    int sawAny = 0;
    while ((child = IOIteratorNext(childIter))) {
        sawAny = 1;
        io_name_t name = {0};
        if (IORegistryEntryGetName(child, name) != KERN_SUCCESS) {
            IOObjectRelease(child);
            continue;
        }
        // Match any physical port child: "Port-USB-C" or "Port-MagSafe 3".
        if (strncmp(name, "Port-", 5) == 0) {
            io_name_t loc = {0};
            IORegistryEntryGetLocationInPlane(child, kIOServicePlane, loc);
            if (loc[0] != '\0') {
                snprintf(label, labelN, "%s@%s", name, loc);
            } else if (!findDescriptionWithLocation(child, 0, label, labelN)) {
                snprintf(label, labelN, "%s", name);
            }
            char cu[128] = {0};
            if (readStringProp(child, CFSTR("ConnectionUUID"), cu, sizeof(cu)) && cu[0]) {
                snprintf(connUUID, connN, "%s", cu);
            }
            IOObjectRelease(child);
            IOObjectRelease(childIter);
            return;
        }
        IOObjectRelease(child);
    }
    if (sawAny && !IOIteratorIsValid(childIter))
        printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
    IOObjectRelease(childIter);
}

int main(void) {
    printf("=== Port -> power-controller identity map ===\n");
    printf("M3+: controller UUID == SMC DxUI (probe 34), the stable per-port power join key.\n");
    printf("M1/M2: class AppleHPMDevice may lack UUID; ConnectionUUID (per-connection) shown for comparison.\n\n");

    // Match the base class so both the M1-era AppleHPMDevice and the M3+
    // AppleHPMDeviceHALType3 subclass are caught in one sweep.
    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("AppleHPMDevice"),
        &iter);
    if (kr != KERN_SUCCESS) {
        printf("No AppleHPMDevice found (kr=0x%x)\n", kr);
        return 0;
    }

    io_service_t hpm;
    int idx = 0;
    while ((hpm = IOIteratorNext(iter))) {
        io_name_t cls = {0};
        IOObjectGetClass(hpm, cls);

        char uuid[128] = "(none)";
        readStringProp(hpm, CFSTR("UUID"), uuid, sizeof(uuid));

        long long rid = -1, addr = -1;
        readNumberProp(hpm, CFSTR("RID"), &rid);
        readNumberProp(hpm, CFSTR("Address"), &addr);

        char portLabel[160], connUUID[128];
        resolvePort(hpm, portLabel, sizeof(portLabel), connUUID, sizeof(connUUID));

        printf("[%d] %-18s  class=%s\n", idx, portLabel, cls);
        printf("      UUID=%s  RID=%lld  Address=%lld\n", uuid, rid, addr);
        printf("      ConnectionUUID=%s\n", connUUID);

        idx++;
        IOObjectRelease(hpm);
    }
    if (idx > 0 && !IOIteratorIsValid(iter))
        printf("--- TRUNCATED: iterator invalidated mid-walk (registry changed) ---\n");
    IOObjectRelease(iter);

    if (idx == 0) printf("(no power controllers matched)\n");
    return 0;
}
