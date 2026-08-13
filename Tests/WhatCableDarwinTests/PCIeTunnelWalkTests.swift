import Foundation
import Testing
@testable import WhatCableDarwinBackend
import WhatCableCore

/// Walk-side tests for the PCIe-tunnelled dock-controller continuation (plan
/// `pcie-tunnelled-usb-attribution`, the LG UltraFine 5K case):
///
/// 1. The pure `walkContinuation` seam, which IS the live collector's
///    stop/continue rule (the collector calls it directly, so these tests
///    catch a collector that stops too early: the gap the review rounds
///    named in the synthetic-chain tests, which feed the chain in by hand).
/// 2. `classifyAncestry` over a dock-controller chain WITH the bridge chain
///    recorded (the new walk's output shape).
/// 3. The m2max_macos26.6.1 corpus pin: the reporter's own probe 38 (an OLD
///    capture, stopped at the terminator) replays to tunnelled/port=nil with
///    a PCIe carrier and nil depth/root. A regression guard only: it cannot
///    validate the new walk (the capture has no bridge chain), the synthetic
///    tests above do that.
struct PCIeTunnelWalkTests {

    private func ancestor(
        className: String = "IOPP",
        serviceName: String?,
        usbIOPortPath: String? = nil
    ) -> USBWatcher.USBAncestor {
        USBWatcher.USBAncestor(
            className: className,
            locationID: nil,
            usbIOPortPath: usbIOPortPath,
            usbPortType: nil,
            conformsToUSBHostDevice: false,
            serviceName: serviceName
        )
    }

    // MARK: - The continuation seam (plan test 1)

    @Test("walkContinuation: both tunnel kinds continue to the PCIe root; native and embedded stop")
    func continuationRule() {
        // Native USB tunnel: continues (unchanged behaviour).
        #expect(USBWatcher.walkContinuation(after: "AppleUSBXHCITR") == .continueToPCIeRoot)
        // Dock-supplied PCIe xHCI controllers: continue (the fix).
        #expect(USBWatcher.walkContinuation(after: "AppleUSBXHCIFL1100") == .continueToPCIeRoot)
        #expect(USBWatcher.walkContinuation(after: "AppleASMediaUSBXHCI") == .continueToPCIeRoot)
        #expect(USBWatcher.walkContinuation(after: "AppleUSBXHCIAR") == .continueToPCIeRoot)
        // Native Apple Silicon controllers: stop.
        #expect(USBWatcher.walkContinuation(after: "AppleT8112USBXHCI") == .stop)
        #expect(USBWatcher.walkContinuation(after: "AppleT6000USBXHCI") == .stop)
        // Apple-embedded board controllers (desktop built-in wiring,
        // discussion #417): stop, and never PCIe-carried.
        #expect(USBWatcher.walkContinuation(after: "AppleEmbeddedUSBXHCIFL1100") == .stop)
        #expect(USBWatcher.walkContinuation(after: "AppleEmbeddedUSBXHCIASMedia3142") == .stop)
        // Non-controller classes: stop (never consulted in practice; the
        // collector only asks for isWalkTerminator classes).
        #expect(USBWatcher.walkContinuation(after: "AppleUSB20Hub") == .stop)
    }

    // MARK: - Dock-controller chain classification (plan test 2)

    @Test("classifyAncestry: FL1100 chain WITH bridge chain yields PCIe carrier + depth + root")
    func dockControllerChainWithBridge() {
        // The new walk's output shape for an LG UltraFine-class monitor:
        // device -> hub port -> FL1100 controller, then the continuation's
        // pci-bridge chain up to the strict apciecN root.
        let ancestors: [USBWatcher.USBAncestor] = [
            ancestor(className: "AppleUSB30HubPort", serviceName: nil),
            ancestor(className: "AppleUSBXHCIFL1100", serviceName: "AppleUSBXHCIFL1100"),
            ancestor(serviceName: "IOPP"),
            ancestor(serviceName: "pci-bridge"),
            ancestor(serviceName: "IOPP"),
            ancestor(serviceName: "pci-bridge"),
            ancestor(serviceName: "IOPP"),
            ancestor(serviceName: "pcic1-bridge"),
            ancestor(className: "AppleT6000PCIeC", serviceName: "AppleT6000PCIeC"),
            ancestor(serviceName: "apciec1"),
        ]
        let c = USBWatcher.classifyAncestry(ancestors)
        #expect(c.tunnelled == true)
        #expect(c.carrier == .pcieTunnel)
        #expect(c.tunnelBridgeDepth == 2)
        #expect(c.tunnelRootName == "apciec1")
        #expect(c.portName == nil)
        #expect(c.reachedNativeController == false)
        #expect(c.reachedEmbeddedController == false)
    }

    @Test("classifyAncestry: XHCITR chain is unchanged and carries the USB carrier")
    func usbTunnelChainUnchanged() {
        let ancestors: [USBWatcher.USBAncestor] = [
            ancestor(className: "AppleUSBXHCITR", serviceName: "AppleUSBXHCITR"),
            ancestor(serviceName: "IOPP"),
            ancestor(serviceName: "pci-bridge"),
            ancestor(serviceName: "IOPP"),
            ancestor(serviceName: "pci-bridge"),
            ancestor(serviceName: "apciec2"),
        ]
        let c = USBWatcher.classifyAncestry(ancestors)
        #expect(c.tunnelled == true)
        #expect(c.carrier == .usbTunnel)
        #expect(c.tunnelBridgeDepth == 2)
        #expect(c.tunnelRootName == "apciec2")
    }

    @Test("classifyAncestry: embedded controller never continues and never gets a PCIe carrier")
    func embeddedControllerStops() {
        // Even if extra ancestors WERE somehow present past an embedded
        // controller (they never are: the collector stops), classification
        // must not read them: the terminator decides, and embedded means
        // built-in wiring, not a tunnel.
        let ancestors: [USBWatcher.USBAncestor] = [
            ancestor(className: "AppleEmbeddedUSBXHCIFL1100", serviceName: "AppleEmbeddedUSBXHCIFL1100"),
            ancestor(serviceName: "IOPP"),
            ancestor(serviceName: "pci-bridge"),
            ancestor(serviceName: "apciec0"),
        ]
        let c = USBWatcher.classifyAncestry(ancestors)
        #expect(c.tunnelled == false)
        #expect(c.carrier == nil)
        #expect(c.tunnelBridgeDepth == nil)
        #expect(c.tunnelRootName == nil)
        #expect(c.reachedEmbeddedController == true)
    }

    // MARK: - Corpus pin: the reporter's capture (plan test 12, regression guard only)

    private static let probeRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhatCableDarwinTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("research/customer-probes")
    }()

    /// Parse one probe-38 ancestor line (helper duplicated from
    /// `USBWatcherCorpusSweepTests` per the house copy rule).
    private static func parseAncestorLine(_ line: String) -> USBWatcher.USBAncestor? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let closeBracket = trimmed.firstIndex(of: "]") else { return nil }
        let rest = trimmed[trimmed.index(after: closeBracket)...].trimmingCharacters(in: .whitespaces)
        var className: String?
        var locationID: UInt32?
        var usbPortType: Int?
        var usbIOPort: String?
        var usbHostDevice = false
        var serviceName: String?
        for token in rest.split(separator: " ") {
            guard let eq = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<eq])
            let value = String(token[token.index(after: eq)...])
            switch key {
            case "class": className = value
            case "locationID":
                var hex = value
                if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
                locationID = UInt32(hex, radix: 16)
            case "USBPortType": usbPortType = Int(value)
            case "UsbIOPort": usbIOPort = value
            case "usbHostDevice": usbHostDevice = value == "1"
            case "name": serviceName = value
            default: break
            }
        }
        guard let className else { return nil }
        let conforms = usbHostDevice || className == "IOUSBHostDevice"
        return USBWatcher.USBAncestor(
            className: className, locationID: locationID, usbIOPortPath: usbIOPort,
            usbPortType: conforms ? usbPortType : nil,
            conformsToUSBHostDevice: conforms, serviceName: serviceName
        )
    }

    // MARK: - New probe-38 format replay (review finding: Stage B evidence)

    @Test("Extended probe-38 format: continuation rows replay to bridge depth + root through the real parser and classifier")
    func newProbeFormatReplaysBridgeChain() {
        // The exact shape the extended probe emits for an FL1100 behind a
        // PCIe tunnel: numbered continuation rows with name= tokens ABOVE
        // the controller marker (which the block parsers treat as
        // end-of-ancestors).
        let lines = [
            "    [0] class=AppleUSB30HubPort locationID=0x20540000",
            "    [1] class=AppleUSBXHCIFL1100 locationID=0x20000000",
            "    [2] class=IOPP name=IOPP",
            "    [3] class=IOPCIDevice name=pci-bridge",
            "    [4] class=IOPP name=IOPP",
            "    [5] class=IOPCIDevice name=pci-bridge",
            "    [6] class=IOPP name=IOPP",
            "    [7] class=IOPCIDevice name=pcic1-bridge",
            "    [8] class=AppleT6000PCIeC name=AppleT6000PCIeC",
            "    [9] class=IOPlatformDevice name=apciec1",
        ]
        let ancestors = lines.compactMap { Self.parseAncestorLine($0) }
        #expect(ancestors.count == 10, "all rows incl. continuation parse as ancestors, got \(ancestors.count)")
        let c = USBWatcher.classifyAncestry(ancestors)
        #expect(c.tunnelled == true)
        #expect(c.carrier == .pcieTunnel)
        #expect(c.tunnelBridgeDepth == 2, "two pci-bridge names between controller and root")
        #expect(c.tunnelRootName == "apciec1")
    }

    @Test("m2max_macos26.6.1 pin: the LG's 8 devices replay tunnelled/port=nil with PCIe carrier, nil depth+root; the 19 native devices keep their ports")
    func reporterCapturePin() throws {
        let url = Self.probeRoot
            .appendingPathComponent("m2max_macos26.6.1")
            .appendingPathComponent("38_usb_device_tree.json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = root["output"] as? String else {
            // Raw probe 38 is gitignored for this folder; on a fresh clone or
            // unlinked worktree this pin has no input. The corpus-presence CI
            // check keeps this from silently skipping everywhere.
            return
        }
        var tunnelledCount = 0
        var nativeCount = 0
        for block in text.components(separatedBy: "--- Device[").dropFirst() {
            let ancestors = block.split(separator: "\n").compactMap { Self.parseAncestorLine(String($0)) }
            guard !ancestors.isEmpty else { continue }
            let c = USBWatcher.classifyAncestry(ancestors)
            if c.tunnelled {
                tunnelledCount += 1
                #expect(c.carrier == .pcieTunnel, "every tunnelled device in this capture is on the LG's FL1100")
                #expect(c.portName == nil)
                // Old capture shape: the probe stopped at the terminator, so
                // depth/root replay honestly nil (the failure invariant).
                #expect(c.tunnelBridgeDepth == nil)
                #expect(c.tunnelRootName == nil)
            } else {
                nativeCount += 1
                #expect(c.portName != nil, "native devices in this capture all carry a UsbIOPort port name")
            }
        }
        // Floors, so a parser regression shows as a failure rather than a
        // clean run: the capture holds 8 FL1100 devices and 19 native ones.
        #expect(tunnelledCount == 8, "expected the LG's 8 devices, got \(tunnelledCount)")
        #expect(nativeCount == 19, "expected 19 native devices, got \(nativeCount)")
    }
}
