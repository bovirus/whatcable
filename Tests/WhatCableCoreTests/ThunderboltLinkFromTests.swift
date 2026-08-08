import Foundation
import Testing
@testable import WhatCableCore

/// Covers `IOThunderboltSwitch.from(...)` and `IOThunderboltPort.from(...)` -
/// the pure factories the watcher uses to turn raw IOKit property
/// dictionaries into model values. Fixture dictionaries are transcribed
/// from real `whatcable --tb-debug` paste-backs on issue #52, so the keys
/// and shapes match what live machines actually report.
///
/// Two real topologies anchor the tests:
/// - Steve's M3 Air + Samsung C34J79x via TB3 (one downstream switch)
/// - Joe's M2 Pro + ASUS PA32QCV (USB4) + CalDigit TS3 Plus daisy-chain
///   (downstream + sub-downstream)
@Suite("Thunderbolt Link From")
struct ThunderboltLinkFromTests {

    // MARK: - LinkGeneration enum

    @Test("Link generation known codes")
    func linkGenerationKnownCodes() {
        #expect(LinkGeneration.from(rawSpeedCode: 0x8) == .tb3)
        #expect(LinkGeneration.from(rawSpeedCode: 0x4) == .usb4Tb4)
        #expect(LinkGeneration.from(rawSpeedCode: 0x2) == .tb5)
    }

    @Test("Link generation idle returns nil")
    func linkGenerationIdleReturnsNil() {
        #expect(LinkGeneration.from(rawSpeedCode: 0) == nil)
    }

    @Test("Link generation unknown code")
    func linkGenerationUnknownCode() {
        // Forward-compat: a future generation should not crash the parser.
        #expect(LinkGeneration.from(rawSpeedCode: 0x1) == .unknown(rawSpeedCode: 0x1))
    }

    @Test("Link generation per-lane Gbps")
    func linkGenerationPerLaneGbps() {
        #expect(LinkGeneration.tb3.perLaneGbps == 10)
        #expect(LinkGeneration.usb4Tb4.perLaneGbps == 20)
        #expect(LinkGeneration.tb5.perLaneGbps == 40)
        #expect(LinkGeneration.unknown(rawSpeedCode: 0x1).perLaneGbps == nil)
    }

    // MARK: - LinkWidth bitmask

    @Test("Link width single")
    func linkWidthSingle() {
        let w = LinkWidth(rawValue: 0x1)
        #expect(w.single)
        #expect(!w.dual)
        #expect(w.txLanes == 1)
        #expect(w.rxLanes == 1)
        #expect(w.isActive)
    }

    @Test("Link width dual")
    func linkWidthDual() {
        let w = LinkWidth(rawValue: 0x2)
        #expect(!w.single)
        #expect(w.dual)
        #expect(w.txLanes == 2)
        #expect(w.rxLanes == 2)
    }

    @Test("Link width asymmetric TX")
    func linkWidthAsymmetricTx() {
        // 3 TX / 1 RX. TB5 only; we have no real sample yet but the
        // model has to handle it without breaking.
        let w = LinkWidth(rawValue: 0x4)
        #expect(w.asymmetricTx)
        #expect(w.txLanes == 3)
        #expect(w.rxLanes == 1)
    }

    @Test("Link width asymmetric RX")
    func linkWidthAsymmetricRx() {
        let w = LinkWidth(rawValue: 0x8)
        #expect(w.asymmetricRx)
        #expect(w.txLanes == 1)
        #expect(w.rxLanes == 3)
    }

    @Test("Link width idle")
    func linkWidthIdle() {
        let w = LinkWidth(rawValue: 0)
        #expect(!w.isActive)
        #expect(w.txLanes == 0)
    }

    // MARK: - TargetLinkWidth (different encoding from current width)

    @Test("Target link width single")
    func targetLinkWidthSingle() {
        #expect(TargetLinkWidth.from(rawValue: 0x1) == .single)
    }

    /// `Target Link Width = 3` is the named DUAL register value, NOT
    /// asymmetric. This was a footgun the planning doc nearly baked in.
    @Test("Target link width three means dual")
    func targetLinkWidthThreeMeansDual() {
        #expect(TargetLinkWidth.from(rawValue: 0x3) == .dual)
    }

    @Test("Target link width unknown")
    func targetLinkWidthUnknown() {
        #expect(TargetLinkWidth.from(rawValue: 0x7) == .unknown(rawValue: 0x7))
    }

    // MARK: - SupportedSpeedMask

    /// Apple TB4-class controllers report 12 (0x4 | 0x8) on every host root
    /// we've seen so far.
    @Test("Supported speed mask TB4 class")
    func supportedSpeedMaskTb4Class() {
        let m = SupportedSpeedMask(rawValue: 12)
        #expect(m.supportsTb3)
        #expect(m.supportsUsb4Tb4)
        #expect(m.supportsTb5 == false)
    }

    /// A future TB5 controller should report 14 (0x2 | 0x4 | 0x8). Verified
    /// by inference only; no real sample yet.
    @Test("Supported speed mask TB5 class")
    func supportedSpeedMaskTb5Class() {
        let m = SupportedSpeedMask(rawValue: 14)
        #expect(m.supportsTb5)
        #expect(m.supportsUsb4Tb4)
        #expect(m.supportsTb3)
    }

    // MARK: - AdapterType decoding

    @Test("Adapter type decoding")
    func adapterTypeDecoding() {
        #expect(AdapterType.from(rawValue: 0) == .inactive)
        #expect(AdapterType.from(rawValue: 1) == .lane)
        #expect(AdapterType.from(rawValue: 2) == .nhi)
        #expect(AdapterType.from(rawValue: 0x0e0101) == .dpIn)
        #expect(AdapterType.from(rawValue: 0x0e0102) == .dpOut)
        #expect(AdapterType.from(rawValue: 0x100101) == .pcieDown)
        #expect(AdapterType.from(rawValue: 0x100102) == .pcieUp)
        #expect(AdapterType.from(rawValue: 0x200101) == .usb3Down)
        #expect(AdapterType.from(rawValue: 0x200102) == .usb3Up)
        #expect(AdapterType.from(rawValue: 0xdeadbe) == .other(0xdeadbe))
    }

    @Test("Adapter type decimal values from IOKit")
    func adapterTypeDecimalValuesFromIokit() {
        // The IOKit dumps print these as decimals; sanity-check the
        // hex-to-decimal conversions.
        #expect(AdapterType.from(rawValue: 917761) == .dpIn)
        #expect(AdapterType.from(rawValue: 917762) == .dpOut)
        #expect(AdapterType.from(rawValue: 1048833) == .pcieDown)
        #expect(AdapterType.from(rawValue: 1048834) == .pcieUp)
        #expect(AdapterType.from(rawValue: 2097409) == .usb3Down)
        #expect(AdapterType.from(rawValue: 2097410) == .usb3Up)
    }

    @Test("USB Gen T adapter type decoding (TB5-era USB tunnel, 0x210101 / 0x210102)")
    func usbGenTAdapterTypeDecoding() {
        #expect(AdapterType.from(rawValue: 0x210101) == .usbGenTDown)
        #expect(AdapterType.from(rawValue: 0x210102) == .usbGenTUp)
        // research/dumps/tb-fabric/052-nofr1ends-m5pro-ugreen-tb5-dock.md
        // lines 215-217 print this as decimal 2162945, Description "USB
        // Gen T Adapter".
        #expect(AdapterType.from(rawValue: 2162945) == .usbGenTDown)
    }

    // MARK: - Steve's Samsung C34J79x downstream switch (TB3)

    /// Switch #3 from issue #52 comment 1: Samsung C34J79x at Depth=1.
    private var samsungSwitch: [String: Any] {
        [
            "UID": NSNumber(value: Int64(105094508797638400)),
            "Vendor ID": NSNumber(value: 32902),
            "Device Vendor ID": NSNumber(value: 373),
            "Device Vendor Name": "SAMSUNG ELECTRONICS CO.,LTD",
            "Device Model Name": "C34J79x",
            "Router ID": NSNumber(value: 0),
            "Depth": NSNumber(value: 1),
            "Route String": NSNumber(value: 1),
            "Upstream Port Number": NSNumber(value: 3),
            "Max Port Number": NSNumber(value: 13),
            "Supported Link Speed": NSNumber(value: 12)
        ]
    }

    /// Active TB3 link from the same dump: host port @1 (Lane 1) with
    /// `Current Link Speed = 8`, `Width = 2`, `Link Bandwidth = 200`.
    private var hostTb3Port: [String: Any] {
        [
            "Adapter Type": NSNumber(value: 1),
            "Port Number": NSNumber(value: 1),
            "Socket ID": "1",
            "Current Link Speed": NSNumber(value: 8),
            "Current Link Width": NSNumber(value: 2),
            "Target Link Speed": NSNumber(value: 12),
            "Target Link Width": NSNumber(value: 3),
            "Supported Link Speed": NSNumber(value: 12),
            "Supported Link Width": NSNumber(value: 2),
            "Link Bandwidth": NSNumber(value: 200)
        ]
    }

    @Test("Samsung switch parses")
    func samsungSwitchParses() {
        let model = IOThunderboltSwitch.from(
            uid: (samsungSwitch["UID"] as! NSNumber).int64Value,
            read: { self.samsungSwitch[$0] },
            className: "IOIOThunderboltSwitchType3",
            ports: []
        )
        #expect(model != nil)
        #expect(model?.id == 105094508797638400)
        #expect(model?.depth == 1)
        #expect(model?.routeString == 1)
        #expect(model?.modelName == "C34J79x")
        #expect(model?.vendorName == "SAMSUNG ELECTRONICS CO.,LTD")
        #expect(model?.upstreamPortNumber == 3)
        #expect(model?.isHostRoot == false)
        // Present: the fixture carries "Device Vendor ID": 373.
        #expect(model?.dromVendorID == 373)
        // Missing: the fixture has no "Device Model ID" key at all.
        #expect(model?.dromModelID == nil)
    }

    // MARK: - Numeric DROM identity (#493)

    @Test("DROM vendor/model id: zero is normalised to nil")
    func dromNumbersZeroNormalisedToNil() {
        // A raw 0 is what a failed IOKit read defaults to elsewhere in the
        // stack (USBWatcher's idVendor/idProduct fallback); treating it as a
        // real id here would let two zeroed reads "exact match" each other.
        var dict = samsungSwitch
        dict["Device Vendor ID"] = NSNumber(value: 0)
        dict["Device Model ID"] = NSNumber(value: 0)
        let model = IOThunderboltSwitch.from(
            uid: (dict["UID"] as! NSNumber).int64Value,
            read: { dict[$0] },
            className: "IOIOThunderboltSwitchType3",
            ports: []
        )
        #expect(model?.dromVendorID == nil)
        #expect(model?.dromModelID == nil)
    }

    @Test("DROM vendor/model id: out-of-UInt16-range values are normalised to nil")
    func dromNumbersOutOfRangeNormalisedToNil() {
        var dict = samsungSwitch
        // A real vendor/product id is a 16-bit number (max 65535). A
        // negative value or one above that ceiling is a garbage read, not a
        // real (if unlikely) accessory id.
        dict["Device Vendor ID"] = NSNumber(value: -1)
        dict["Device Model ID"] = NSNumber(value: 70000)
        let model = IOThunderboltSwitch.from(
            uid: (dict["UID"] as! NSNumber).int64Value,
            read: { dict[$0] },
            className: "IOIOThunderboltSwitchType3",
            ports: []
        )
        #expect(model?.dromVendorID == nil)
        #expect(model?.dromModelID == nil)
    }

    @Test("DROM vendor/model id: a valid pair round-trips exactly")
    func dromNumbersValidPairRoundTrips() {
        // The real OWC Express 1M2 numbers from
        // research/customer-probes/m3pro_macos27.0_l/29_usb4_router_interfaces.json.
        var dict = samsungSwitch
        dict["Device Vendor ID"] = NSNumber(value: 0x174c)
        dict["Device Model ID"] = NSNumber(value: 0x2465)
        let model = IOThunderboltSwitch.from(
            uid: (dict["UID"] as! NSNumber).int64Value,
            read: { dict[$0] },
            className: "IOIOThunderboltSwitchType3",
            ports: []
        )
        #expect(model?.dromVendorID == 0x174c)
        #expect(model?.dromModelID == 0x2465)
    }

    @Test("Host TB3 port parses as active TB3 link")
    func hostTb3PortParsesAsActiveTb3Link() {
        let port = IOThunderboltPort.from(read: { self.hostTb3Port[$0] })
        #expect(port != nil)
        #expect(port?.adapterType == .lane)
        #expect(port?.socketID == "1")
        #expect(port?.currentSpeed == .tb3)
        #expect(port?.perLaneGbps == 10)
        #expect(port?.currentWidth?.dual == true)
        #expect(port?.txLanes == 2)
        #expect(port?.targetWidth == .dual)
        #expect(port?.linkBandwidthRaw == 200)
        #expect(port?.hasActiveLink ?? false)
    }

    // MARK: - Joe's daisy-chain (USB4 + TB3 step-down)

    /// ASUS PA32QCV at Depth=1 via Intel JHL8440 controller.
    private var asusSwitch: [String: Any] {
        [
            // ASUS UID is negative in IOKit (Int64 sign bit set). This is
            // exactly why the model uses Int64 rather than UInt64.
            "UID": NSNumber(value: Int64(-9185256489162756864)),
            "Vendor ID": NSNumber(value: 32903),
            "Device Vendor ID": NSNumber(value: 2821),
            "Device Vendor Name": "ASUS-Display",
            "Device Model Name": "PA32QCV",
            "Router ID": NSNumber(value: 0),
            "Depth": NSNumber(value: 1),
            "Route String": NSNumber(value: 1),
            "Upstream Port Number": NSNumber(value: 1),
            "Max Port Number": NSNumber(value: 19),
            "Supported Link Speed": NSNumber(value: 12)
        ]
    }

    /// Host port @1 on Joe's M2 Pro: USB4 link to the ASUS, speed=4, width=2.
    private var hostUsb4Port: [String: Any] {
        [
            "Adapter Type": NSNumber(value: 1),
            "Port Number": NSNumber(value: 1),
            "Socket ID": "1",
            "Current Link Speed": NSNumber(value: 4),
            "Current Link Width": NSNumber(value: 2),
            "Target Link Speed": NSNumber(value: 12),
            "Target Link Width": NSNumber(value: 3),
            "Link Bandwidth": NSNumber(value: 400)
        ]
    }

    /// CalDigit TS3 Plus at Depth=2, Route String=769 (= 0x301: entered
    /// ASUS port 3, then host port 1).
    private var ts3PlusSwitch: [String: Any] {
        [
            "UID": NSNumber(value: Int64(17188550068006400)),
            "Vendor ID": NSNumber(value: 32902),
            "Device Vendor ID": NSNumber(value: 61),
            "Device Vendor Name": "CalDigit, Inc.",
            "Device Model Name": "TS3 Plus",
            "Router ID": NSNumber(value: 0),
            "Depth": NSNumber(value: 2),
            "Route String": NSNumber(value: 769),
            "Upstream Port Number": NSNumber(value: 1),
            "Max Port Number": NSNumber(value: 11),
            "Supported Link Speed": NSNumber(value: 12)
        ]
    }

    /// TS3 Plus upstream lane port: TB3 single-lane (the step-down).
    private var ts3PlusUpstreamPort: [String: Any] {
        [
            "Adapter Type": NSNumber(value: 1),
            "Port Number": NSNumber(value: 3),
            "Current Link Speed": NSNumber(value: 8),
            "Current Link Width": NSNumber(value: 1),
            "Target Link Speed": NSNumber(value: 12),
            "Target Link Width": NSNumber(value: 1),
            "Link Bandwidth": NSNumber(value: 100)
        ]
    }

    @Test("Host USB4 port detected as TB4 class")
    func hostUsb4PortDetectedAsTb4Class() {
        let port = IOThunderboltPort.from(read: { self.hostUsb4Port[$0] })
        #expect(port?.currentSpeed == .usb4Tb4)
        #expect(port?.perLaneGbps == 20)
        #expect(port?.txLanes == 2)
        #expect(port?.linkBandwidthRaw == 400)
    }

    @Test("Daisy chain step-down detected")
    func daisyChainStepDownDetected() {
        // The interesting UX bullet for this topology is "USB4 to ASUS,
        // step-down to TB3 single-lane on the next leg". This test
        // confirms the model exposes everything a renderer needs to
        // produce that label. The renderer itself is Phase 3.
        let usb4 = IOThunderboltPort.from(read: { self.hostUsb4Port[$0] })
        let tb3 = IOThunderboltPort.from(read: { self.ts3PlusUpstreamPort[$0] })
        #expect(usb4?.currentSpeed == .usb4Tb4)
        #expect(tb3?.currentSpeed == .tb3)
        // Per-lane Gbps drops on the second hop. Lane count also drops.
        #expect((usb4?.perLaneGbps ?? 0) > (tb3?.perLaneGbps ?? 0))
        #expect((usb4?.txLanes ?? 0) > (tb3?.txLanes ?? 0))
    }

    @Test("TS3 Plus switch at depth 2")
    func ts3PlusSwitchAtDepth2() {
        let model = IOThunderboltSwitch.from(
            uid: (ts3PlusSwitch["UID"] as! NSNumber).int64Value,
            read: { self.ts3PlusSwitch[$0] },
            className: "IOIOThunderboltSwitchType3",
            ports: []
        )
        #expect(model?.depth == 2)
        #expect(model?.routeString == 769)
        #expect(model?.modelName == "TS3 Plus")
    }

    @Test("ASUS switch handles negative UID")
    func asusSwitchHandlesNegativeUid() {
        // Regression guard: IOKit reports some UIDs as signed Int64 with
        // the sign bit set. The model must store these without truncation.
        let model = IOThunderboltSwitch.from(
            uid: (asusSwitch["UID"] as! NSNumber).int64Value,
            read: { self.asusSwitch[$0] },
            className: "IOIOThunderboltSwitchIntelJHL8440",
            ports: []
        )
        #expect(model?.id == -9185256489162756864)
        #expect(model?.modelName == "PA32QCV")
    }

    // MARK: - Idle / non-lane ports

    @Test("Idle host port has no link state")
    func idleHostPortHasNoLinkState() {
        // From the M5 Pro idle probe: lane port with everything zeroed.
        let dict: [String: Any] = [
            "Adapter Type": NSNumber(value: 1),
            "Port Number": NSNumber(value: 1),
            "Socket ID": "1",
            "Current Link Speed": NSNumber(value: 0),
            "Current Link Width": NSNumber(value: 0)
        ]
        let port = IOThunderboltPort.from(read: { dict[$0] })
        #expect(port?.currentSpeed == nil)
        #expect(port?.currentWidth?.isActive == false)
        #expect((port?.hasActiveLink ?? true) == false)
    }

    @Test("Protocol adapter port has no link state")
    func protocolAdapterPortHasNoLinkState() {
        // PCIe adapter ports report Adapter Type but not link generation.
        // The factory should not invent a generation just because the
        // dictionary happens to contain a Link Bandwidth value.
        let dict: [String: Any] = [
            "Adapter Type": NSNumber(value: 1048833),  // PCIe down
            "Port Number": NSNumber(value: 3),
            "Link Bandwidth": NSNumber(value: 60)
        ]
        let port = IOThunderboltPort.from(read: { dict[$0] })
        #expect(port?.adapterType == .pcieDown)
        #expect(port?.currentSpeed == nil)
        #expect(port?.currentWidth == nil)
        #expect((port?.hasActiveLink ?? true) == false)
    }

    // MARK: - Missing fields

    @Test("Switch without VendorID returns nil")
    func switchWithoutVendorIDReturnsNil() {
        // UID is now a required parameter (caller-owned). The remaining
        // mandatory guard inside from() is Vendor ID.
        let model = IOThunderboltSwitch.from(
            uid: 1,
            read: { _ in nil },
            className: "IOIOThunderboltSwitchType7",
            ports: []
        )
        #expect(model == nil)
    }

    @Test("Port without port number returns nil")
    func portWithoutPortNumberReturnsNil() {
        let port = IOThunderboltPort.from(read: { ["Adapter Type": NSNumber(value: 1)][$0] })
        #expect(port == nil)
    }

    // MARK: - acioRootName passthrough (port-scoping join)

    @Test("acioRootName passes through IOThunderboltSwitch.from unchanged")
    func acioRootNamePassesThrough() {
        let dict: [String: Any] = ["Vendor ID": NSNumber(value: 0x8086)]
        let model = IOThunderboltSwitch.from(
            uid: 1,
            read: { dict[$0] },
            className: "IOThunderboltSwitchType5",
            ports: [],
            acioRootName: "acio2"
        )
        #expect(model?.acioRootName == "acio2")
    }

    @Test("acioRootName defaults to nil")
    func acioRootNameDefaultsNil() {
        let dict: [String: Any] = ["Vendor ID": NSNumber(value: 0x8086)]
        let model = IOThunderboltSwitch.from(uid: 1, read: { dict[$0] }, className: "IOThunderboltSwitchType5", ports: [])
        #expect(model?.acioRootName == nil)
    }

    // MARK: - apciecRootName(fromAcioRootName:) (port-scoping join)

    @Test("apciecRootName maps acioN to apciecN by matching index")
    func apciecRootNameMapsMatchingIndex() {
        // Ground truth: research/customer-probes/m3pro_macos27.0_l -- the
        // host root under acio2 owns the chain carrying the LaCie 1big and
        // Studio Display, both of which report tunnelRootName == "apciec2".
        #expect(ThunderboltTopology.apciecRootName(fromAcioRootName: "acio2") == "apciec2")
        #expect(ThunderboltTopology.apciecRootName(fromAcioRootName: "acio0") == "apciec0")
        #expect(ThunderboltTopology.apciecRootName(fromAcioRootName: "acio14") == "apciec14")
    }

    @Test("apciecRootName rejects a name that is not strictly acio + digits")
    func apciecRootNameRejectsLooseNames() {
        #expect(ThunderboltTopology.apciecRootName(fromAcioRootName: "acioDebug") == nil)
        #expect(ThunderboltTopology.apciecRootName(fromAcioRootName: "acio") == nil)
        #expect(ThunderboltTopology.apciecRootName(fromAcioRootName: "notacio2") == nil)
        #expect(ThunderboltTopology.apciecRootName(fromAcioRootName: "acio2x") == nil)
    }
}
