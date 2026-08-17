import Testing
@testable import WhatCableCore

@Suite("Data Link Diagnostic")
struct DataLinkDiagnosticTests {

    // MARK: - Fixtures

    /// Active USB-C port. Same shape as the ChargingDiagnostic fixture
    /// (the proven-compiling AppleHPMInterface init param list).
    /// `transportsActive` defaults to `["CC", "USB3", "CIO"]` so the
    /// fixture exercises the TB-aware paths by default; tests that
    /// hand-roll USB3-only or USB2-only scenarios override it.
    /// `transportsSupported` mirrors a real M-class USB-C port (matters
    /// for the `carriesData` gate added in the issue #195 fix); MagSafe
    /// shape tests override it to `[]`.
    private func makePort(
        active: Bool = true,
        transportsActive: [String] = ["CC", "USB3", "CIO"],
        transportsSupported: [String] = ["CC", "USB2", "USB3", "CIO", "DisplayPort"],
        serviceName: String = "Port-USB-C@1",
        portTypeDescription: String? = "USB-C",
        superSpeedActive: Bool? = nil
    ) -> AppleHPMInterface {
        AppleHPMInterface(
            id: 1,
            serviceName: serviceName,
            className: "AppleHPMInterfaceType10",
            portDescription: nil,
            portTypeDescription: portTypeDescription,
            portNumber: 1,
            connectionActive: active,
            activeCable: nil,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: superSpeedActive,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: transportsSupported,
            transportsActive: transportsActive,
            transportsProvisioned: [],
            plugOrientation: nil,
            plugEventCount: nil,
            connectionCount: nil,
            overcurrentCount: nil,
            pinConfiguration: [:],
            powerCurrentLimits: [],
            firmwareVersion: nil,
            bootFlagsHex: nil,
            rawProperties: [:]
        )
    }

    /// Cable e-marker (SOP') advertising a given CableSpeed code in the
    /// low 3 bits of VDO[3]. Codes: 0 = USB 2.0 (0.48), 1 = USB 3.2 Gen 1
    /// (5), 2 = Gen 2 (10), 3 = USB4 Gen 3 (40), 4 = Gen 4 (80). Mirrors
    /// the ChargingDiagnostic test's cableIdentity construction.
    private func cableEmarker(speedCode: UInt32) -> USBPDSOP {
        let validLatency: UInt32 = 1 << 13          // ~1m, avoids decode warning
        let cableVDO = speedCode | (1 << 5) | validLatency   // 3A current bits
        let idHeader: UInt32 = 0x1800_0000          // passive cable, UFP type 3
        return USBPDSOP(
            id: 2, endpoint: .sopPrime,
            parentPortType: 2, parentPortNumber: 1,
            vendorID: 0, productID: 0, bcdDevice: 0,
            vdos: [idHeader, 0, 0, cableVDO],
            specRevision: 0
        )
    }

    /// USB device with a given "Device Speed" enum value.
    /// 3 = 5 Gbps, 4 = 10 Gbps, 5 = 20 Gbps.
    private func device(speedRaw: UInt8) -> USBDevice {
        USBDevice(
            id: 10, locationID: 0x0100_0000,
            vendorID: 0x1234, productID: 0x5678,
            vendorName: nil, productName: "Test SSD", serialNumber: nil,
            usbVersion: nil, speedRaw: speedRaw,
            busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
    }

    /// issue #181: a port-matched (not root) SuperSpeed device that
    /// corroborates a USB3 reading via `USBDevice.portMatchedSuperSpeed`
    /// without affecting `usb3ActiveGbps`'s resolution (which checks
    /// `rootSuperSpeed` before transport signaling, then falls back to
    /// `portMatchedSuperSpeed` last, so a non-root portMatched device never
    /// wins over an already-resolved transport signaling value). Callers
    /// pick `speedRaw` at or below whatever `device(speedRaw:)` in the same
    /// fixture uses, so it never becomes the array's "fastest device" and
    /// silently changes a `.deviceLimit`/`.cableLimit`/`.hostLimit` figure.
    private func corroboratingPortMatchedDevice(speedRaw: UInt8 = 3) -> USBDevice {
        USBDevice(
            id: 11, locationID: 0x0121_0000,
            vendorID: 0x1234, productID: 0x0001,
            vendorName: nil, productName: "Corroborating device", serialNumber: nil,
            usbVersion: nil, speedRaw: speedRaw,
            busPowerMA: nil, currentMA: nil,
            controllerPortName: "Port-USB-C@1",
            rawProperties: [:]
        )
    }

    private func cio(negotiatedLinkSpeed: Int) -> CIOCableCapability {
        CIOCableCapability(
            id: 3, portKey: "2/1",
            cableGeneration: nil, negotiatedLinkSpeed: negotiatedLinkSpeed, generation: nil,
            asymmetricModeSupported: nil, legacyAdapter: nil, linkTrainingMode: nil
        )
    }

    private func usb3(signaling: Int, transportRestricted: Bool? = nil) -> USB3Transport {
        USB3Transport(
            id: 4, portKey: "2/1",
            signaling: signaling, signalingDescription: nil, dataRole: nil,
            transportRestricted: transportRestricted
        )
    }

    // MARK: - Applicability

    @Test("Returns nil on an inactive port")
    func returnsNilOnInactivePort() {
        let diag = DataLinkDiagnostic(
            port: makePort(active: false),
            identities: [cableEmarker(speedCode: 3)],
            devices: [device(speedRaw: 5)],
            usb3Transports: [usb3(signaling: 2)],
            cio: nil
        )
        #expect(diag == nil)
    }

    @Test("Returns nil when no active link speed is known")
    func returnsNilWithoutActiveSpeed() {
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],
            devices: [device(speedRaw: 5)],
            usb3Transports: [],            // no USB3 signaling
            cio: nil,
            tbActiveGbps: nil              // no TB link
        )
        #expect(diag == nil)
    }

    @Test("Returns nil for a power-only MagSafe port (issue #195)")
    func returnsNilForMagSafePort() {
        // M2 MacBook Air shape from issue #195: MagSafe and the first
        // USB-C port share the same HPM controller die and therefore the
        // controller-local `@1` socket suffix. Empty `transportsSupported`
        // is the exclusive capability signal for "power-only port"; the
        // diagnostic now refuses to verdict on it. Without the gate the
        // host-max inference would attribute USB-C@1's 40 Gbps lane mask
        // to MagSafe and produce a confident "Running at full data speed
        // (40 Gbps)" verdict.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xC, activeSpeed: .usb4Tb4)
        let diag = DataLinkDiagnostic(
            port: makePort(
                transportsActive: ["CC"],
                transportsSupported: [],
                serviceName: "Port-MagSafe 3@1",
                portTypeDescription: "MagSafe 3"
            ),
            identities: [],
            devices: [],
            usb3Transports: [],
            cio: nil,
            thunderboltSwitches: [host]
        )
        #expect(diag == nil)
    }

    @Test("Within-controller socket-ID collision: USB-C verdicts, MagSafe abstains")
    func withinControllerCollision() {
        // The exact shape that the #159 verification pass missed: a
        // MagSafe and a USB-C port on the same controller, sharing the
        // `@1` socket suffix. The USB-C port must still get a real
        // verdict; the MagSafe port must abstain. The host TB switch is
        // shared (one root, one lane port at socket "1").
        let host = hostSwitch(socketID: "1", supportedRaw: 0xC, activeSpeed: .usb4Tb4)

        let usbC = makePort(
            transportsActive: ["CC", "USB3", "CIO"],
            serviceName: "Port-USB-C@1"
        )
        let magSafe = makePort(
            transportsActive: ["CC"],
            transportsSupported: [],
            serviceName: "Port-MagSafe 3@1",
            portTypeDescription: "MagSafe 3"
        )

        let usbDiag = DataLinkDiagnostic(
            port: usbC,
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps
            devices: [],
            usb3Transports: [],
            cio: nil,
            thunderboltSwitches: [host]
        )
        let magSafeDiag = DataLinkDiagnostic(
            port: magSafe,
            identities: [],
            devices: [],
            usb3Transports: [],
            cio: nil,
            thunderboltSwitches: [host]
        )
        #expect(usbDiag != nil,
            "USB-C port must still get a verdict despite sharing its socket suffix with MagSafe")
        #expect(magSafeDiag == nil,
            "MagSafe must abstain even when a usable TB switch exists for its colliding socket suffix")
    }

    @Test("USB 2.0 cable on a USB-C port returns nil without a real active rate")
    func usb2CableNoActiveRate() {
        // bigskookum's shape (issue #195 follow-up): a USB-C port holds
        // a USB 2.0 cable. `transportsActive` does not contain CIO or
        // USB3, so the TB lookup (which on Apple Silicon reads the
        // always-up internal root lane) is now gated off, and no USB3
        // signaling is available. With no honest active rate, the
        // diagnostic abstains rather than reading 40 Gbps off the
        // internal lane. The cable badge from PortSummary still
        // surfaces the USB 2.0 reading separately.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xC, activeSpeed: .usb4Tb4)
        let diag = DataLinkDiagnostic(
            port: makePort(
                transportsActive: ["CC", "USB2"],         // USB 2.0 cable only
                transportsSupported: ["CC", "USB2", "USB3", "CIO", "DisplayPort"]
            ),
            identities: [cableEmarker(speedCode: 0)],    // USB 2.0 e-marker
            devices: [],
            usb3Transports: [],
            cio: nil,
            thunderboltSwitches: [host]
        )
        #expect(diag == nil,
            "A USB 2.0-only link should not pick up a Thunderbolt active rate from the always-up internal lane")
    }

    @Test("Cable contradicts active rate when no CIO tiebreak (Change B)")
    func cableContradictsActive() {
        // Synthetic case: e-marker says USB 2.0, the link reads 40 Gbps,
        // no CIO. With the old floor, cable would be promoted to 40 and
        // the verdict would say "Running at full data speed". The new
        // behaviour surfaces both numbers and asks the user to swap the
        // cable to resolve the contradiction.
        let diag = DataLinkDiagnostic(
            port: makePort(transportsActive: ["CC", "USB3", "CIO"]),
            identities: [cableEmarker(speedCode: 0)],    // USB 2.0 (0.48)
            devices: [],
            usb3Transports: [],
            cio: nil,
            tbActiveGbps: 40,
            hostMaxGbps: 40
        )
        guard case .cableContradictsActive(let cableGbps, let activeGbps) = diag?.bottleneck else {
            Issue.record("expected .cableContradictsActive, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(cableGbps == 0.48)
        #expect(activeGbps == 40)
        #expect(diag!.isWarning)
        #expect(diag!.facts.cableGbps == 0.48,
            "Facts must reflect the cable's actual claim, not the silently-promoted active rate")
    }

    // MARK: - Bottleneck attribution

    @Test("Cable is the bottleneck")
    func cableIsBottleneck() {
        // Mac port 20, device 20, but a USB 3.2 Gen 1 (5 Gbps) cable.
        // issue #181: corroborate with a low-speed port-matched device so it
        // never wins the "fastest device" capability figure.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 1)],   // 5 Gbps
            devices: [device(speedRaw: 5), corroboratingPortMatchedDevice()],  // 20 Gbps + corroboration
            usb3Transports: [usb3(signaling: 1)],        // active 5 Gbps
            cio: nil,
            hostMaxGbps: 20
        )
        guard case .cableLimit(let cable, let capable) = diag?.bottleneck else {
            Issue.record("expected .cableLimit, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(cable == 5)
        #expect(capable == 20)
        #expect(diag!.isWarning)
    }

    @Test("Host port is the bottleneck")
    func hostIsBottleneck() {
        // Fast 40 Gbps cable, 20 Gbps device, but the Mac port only does 5.
        // issue #181: corroborate with a low-speed port-matched device so it
        // never wins the "fastest device" capability figure.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps
            devices: [device(speedRaw: 5), corroboratingPortMatchedDevice()],  // 20 Gbps + corroboration
            usb3Transports: [usb3(signaling: 1)],        // active 5 Gbps
            cio: nil,
            hostMaxGbps: 5
        )
        guard case .hostLimit(let host, let capable) = diag?.bottleneck else {
            Issue.record("expected .hostLimit, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(host == 5)
        #expect(capable == 20)
        #expect(diag!.isWarning)
    }

    @Test("Device is the cap, not a fault")
    func deviceIsCapNotFault() {
        // 40 Gbps cable, 40 Gbps port, but a 10 Gbps device.
        // issue #181: corroborate with a low-speed port-matched device so it
        // never wins the "fastest device" capability figure (the whole
        // point of this test is that the 10 Gbps device IS the figure).
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps
            devices: [device(speedRaw: 4), corroboratingPortMatchedDevice()],  // 10 Gbps + corroboration
            usb3Transports: [usb3(signaling: 2)],        // active 10 Gbps
            cio: nil,
            hostMaxGbps: 40
        )
        guard case .deviceLimit(let d) = diag?.bottleneck else {
            Issue.record("expected .deviceLimit, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(d == 10)
        #expect(diag!.isWarning == false)   // a slow device is normal, not a warning
    }

    @Test("Degraded link: everyone supports more but it came up slow")
    func degradedLink() {
        // 40 Gbps cable, 40 Gbps port, 20 Gbps device, but the TB link
        // negotiated only 5 Gbps. This is the case the old draft wrongly
        // reported as "full speed".
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps
            devices: [device(speedRaw: 5)],              // 20 Gbps
            usb3Transports: [],
            cio: nil,
            tbActiveGbps: 5,                             // degraded link
            hostMaxGbps: 40
        )
        guard case .degraded(let active, let expected) = diag?.bottleneck else {
            Issue.record("expected .degraded, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 5)
        #expect(expected == 20)
        #expect(diag!.isWarning)
    }

    @Test("No cable signal: honest 'can't tell'")
    func unknownCableWhenNoSignal() {
        // No e-marker, no controller data. Port 40, device 20, link 5.
        // issue #181: corroborate with a low-speed port-matched device.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [device(speedRaw: 5), corroboratingPortMatchedDevice()],  // 20 Gbps + corroboration
            usb3Transports: [usb3(signaling: 1)],        // active 5 Gbps
            cio: nil,
            hostMaxGbps: 40
        )
        guard case .unknownCable(let active) = diag?.bottleneck else {
            Issue.record("expected .unknownCable, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 5)
        #expect(diag!.isWarning == false)
        #expect(diag!.cableSignalConflict == false)
    }

    @Test("Everything matched: fine")
    func everythingFine() {
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps
            devices: [],
            usb3Transports: [],
            cio: nil,
            tbActiveGbps: 40,                            // active 40 Gbps
            hostMaxGbps: 40
        )
        guard case .fine(let active) = diag?.bottleneck else {
            Issue.record("expected .fine, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 40)
        #expect(diag!.isWarning == false)
    }

    @Test("Controller overrides a lying e-marker (issue #111)")
    func controllerWinsOverEmarker() {
        // E-marker claims USB 2.0 (passive under-report), but the TB
        // controller reports CableSpeed 3 (40 Gbps). We must NOT blame the
        // cable: report fine at 40 and flag the conflict.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 0)],   // e-marker says 0.48
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),                     // controller says 40
            tbActiveGbps: 40,
            hostMaxGbps: 40
        )
        guard case .fine(let active) = diag?.bottleneck else {
            Issue.record("expected .fine, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 40)
        #expect(diag!.cableSignalConflict == true)
        #expect(diag!.detail.contains("disagree"))
    }

    @Test("E-marker claim above the CIO floor is not a conflict (issue #393 direction)")
    func emarkerClaimAboveFloorIsNotAConflict() {
        // Historical note: this fixture used to encode "the controller
        // always wins" -- e-marker claims USB4 Gen 4 (80 Gbps), CIO
        // reports CableSpeed 3 (40 Gbps), take the controller's lower
        // figure -- on the theory that a higher e-marker claim must be a
        // lying cable (issue #190, a zeroed-VID Amazon cable). Issue #393
        // proved that assumption wrong for genuine cables: a real,
        // registered-vendor CableMatters TB5 cable produces the exact
        // same shape (e-marker 80, CIO 40) whenever both endpoints cap at
        // 40. CIO is the negotiated floor, never a ceiling, so a claim
        // above it is not, by itself, evidence of a lying cable.
        // Suspicion about a specific cable (e.g. a zeroed VID) is
        // CableTrust's job, not this tiebreak's. cableMaxGbps must now
        // resolve to the e-marker's own claim (80), with no conflict.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 4)],   // e-marker says 80
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),            // controller floor: 40
            tbActiveGbps: 40,
            hostMaxGbps: 80                              // M4 Max-class host
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.cableEmarkerGbps == 80)
        #expect(facts.cableControllerGbps == 40)
        #expect(facts.cableGbps == 80,
            "The e-marker's claim must stand: CIO is a floor, not a cap. Got: \(String(describing: facts.cableGbps))")
        #expect(diag!.cableSignalConflict == false,
            "A claim above the CIO floor is not, by itself, a conflict")
    }

    @Test("Same-tier e-marker and CIO agree at 80: no conflict, take the value")
    func sameTierEmarkerAndCIOAgreeAtEighty() {
        // Both signals say 80 (TB5-class): agreement, not a conflict.
        // min(80, 80) via sameTier -> cableMaxGbps = 80.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 4)],   // e-marker: 80
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 4),            // controller: 80
            tbActiveGbps: 80,
            hostMaxGbps: 80
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.cableEmarkerGbps == 80)
        #expect(facts.cableControllerGbps == 80)
        #expect(facts.cableGbps == 80)
        #expect(diag!.cableSignalConflict == false)
    }

    @Test("Stale-controller guard: a higher CIO figure uncorroborated by the live link stays quiet")
    func staleCIOAboveEmarkerAndActiveStaysQuiet() {
        // CIO and the TB switch lane state come from two different IOKit
        // services on two different watcher streams, so a transient can
        // leave CIO reading higher than the link that is actually up.
        // Shape: e-marker claims 40, CIO says 80 (uncorroborated), the
        // live link runs 40. The e-marker matches the link; the higher
        // CIO figure matches nothing. Walk: sameTier(e 40, active 40)
        // holds and sameTier(c 80, active 40) does not (ratio 2), so the
        // guard keeps the e-marker's 40 with no conflict banner, and the
        // verdict is a plain full-speed .fine (40 = host = device tier).
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // e-marker: 40
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 4),            // CIO claims 80
            tbActiveGbps: 40,                            // but the link runs 40
            hostMaxGbps: 40
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.cableGbps == 40,
            "An uncorroborated higher CIO figure must not override the e-marker")
        #expect(diag!.cableSignalConflict == false,
            "No confirmed-conflict banner from possibly stale controller data")
    }

    @Test("Controller wins over the e-marker when the live link corroborates it (issue #111 direction)")
    func cioAboveEmarkerCorroboratedByActiveWins() {
        // The genuine #111 shape: e-marker under-reports (5 Gbps), CIO
        // says 40 and the live link really runs 40. sameTier(e 5,
        // active 40) fails, so the stale-controller guard does not
        // apply: the controller's corroborated figure wins, conflict on.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 1)],   // e-marker: 5
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),            // controller: 40
            tbActiveGbps: 40,
            hostMaxGbps: 40
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.cableGbps == 40)
        #expect(diag!.cableSignalConflict == true)
    }

    @Test("PD 3.0 Gen3 ambiguity: a 20 Gbps floor resolves the Gen3 claim to 20, not 40")
    func gen3ClaimResolvesToFloorOnTB3Link() {
        // A TB3-era passive cable e-marks "Gen3", which means 20 Gbps
        // under PD 3.0 but 40 under PD 3.1; the decoder hardcodes 40.
        // With the controller floor at 20 (a real TB3 link), the PD 3.0
        // reading is the one the evidence supports. Walk: claim resolves
        // to 20 = CIO 20, same tier, agreement; caps cable 20 / host 40,
        // expected 20 = active 20, cable is the unique floor below the
        // 40 Gbps host, so the verdict is the correct .cableLimit (a
        // faster cable would unlock more), NOT a false "slower than
        // expected" built on the phantom 40 Gbps reading.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // Gen3: 20 or 40
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 2),            // controller floor: 20
            tbActiveGbps: 20,
            hostMaxGbps: 40
        )
        guard let diag else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(diag.facts.cableGbps == 20)
        #expect(diag.cableSignalConflict == false)
        if case .cableLimit = diag.bottleneck {
        } else {
            Issue.record("expected .cableLimit for a 20 Gbps cable on a 40 Gbps host, got \(diag.bottleneck)")
        }
    }

    @Test("Issue #393 shape maps to amber trust, not a false green confirmation")
    func claimAboveFloorIsNotTrustConfirmed() {
        // Before the #393 fix, this shape deflated the cable's claim to
        // the negotiated 40 and reported .fine, which CableTrust read as
        // "delivered its claim" -> green. That green was circular: the
        // claim it confirmed was the bug's own deflation. The honest
        // behaviour-first verdict for an 80 Gbps claim that has only ever
        // been seen running 40 is "not yet seen to perform at its claim"
        // (amber): neither confirmed nor contradicted. Pin that mapping
        // so a future change can't quietly flip it back.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 4)],   // claims 80
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),            // floor: 40
            tbActiveGbps: 40,
            hostMaxGbps: 40
        )
        guard let diag else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        let behaviour = CableTrust.behaviour(
            for: diag.bottleneck,
            hasCableSpeedClaim: diag.facts.cableGbps != nil
        )
        #expect(behaviour.dataConfirmed == false,
            "An endpoint-limited link must not confirm an untested 80 Gbps claim")
        #expect(behaviour.contradiction == false,
            "Nor is an untested claim a contradiction")
    }

    @Test("Issue #393: e-marker claim above the floor names the device, not the cable")
    func emarkerClaimAboveFloorNamesDevice() {
        // The exact #393 shape: CableMatters TB5 cable (e-marker claims
        // USB4 Gen 4, 80 Gbps) between an M3 Pro host (TB4-class, 40
        // Gbps max) and a LaCie Rugged SSD4 (TB4-class TB partner, 40
        // Gbps max). CIO reports CableSpeed=3 (40 Gbps): the negotiated
        // floor, min(host, cable, device) = min(80, 40, 40) = 40.
        //
        // Arithmetic: caps = [cable=80, host=40, device=40].
        // expected = min(80, 40, 40) = 40. active (40) is sameTier as
        // expected (40), so this does NOT hit the "meaningfully slower"
        // branch at all -- it goes straight to culprit naming. limiters
        // (sameTier with 40) = [host, device]; fasterOthers
        // (meaningfullySlower(40, than: value)) = [cable] (40 < 80*0.9).
        // fasterOthers isn't empty, so it's not "fine"; priority
        // ["device", "host", "cable"] finds "device" first in limiters
        // -> .deviceLimit(40). The cable, being faster than both
        // endpoints, is never blamed.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xC, activeSpeed: .usb4Tb4)
        let partner = partnerSwitch(parent: host, parentLanePortNumber: 1, supportedRaw: 0xC)
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 4)],   // e-marker claims 80
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),            // controller floor: 40
            thunderboltSwitches: [host, partner],
            tbActiveGbps: 40,
            hostMaxGbps: 40
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.cableEmarkerGbps == 80)
        #expect(facts.cableControllerGbps == 40)
        #expect(facts.cableGbps == 80,
            "The e-marker's claim must stand: CIO is a floor, not a cap. Got: \(String(describing: facts.cableGbps))")
        #expect(diag!.cableSignalConflict == false,
            "A cable claiming more than its endpoints negotiated is not a conflict")
        guard case .deviceLimit(let d) = diag?.bottleneck else {
            Issue.record("expected .deviceLimit (host and device tie at the 40 Gbps floor), got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(d == 40)
        #expect(diag!.isWarning == false, "This is fastest-the-endpoints-support, not a fault")
    }

    @Test("All-known 80 Gbps rig with a 40 Gbps floor: degraded fires honestly")
    func allKnownEightyRigDegradedFiresHonestly() {
        // Adversarial counter-case to the unknown-endpoint guard: host
        // AND device are BOTH independently known to do 80 Gbps,
        // e-marker claims 80, but CIO (and the active link) only measured
        // 40. The guard must NOT suppress the verdict here: two
        // independently-known parts exceed the active rate, so something
        // really is holding the link back, and the honest answer is
        // "degraded", not a hedge.
        //
        // Arithmetic: caps = [cable=80, host=80, device=80].
        // expected = min(80, 80, 80) = 80. meaningfullySlower(40, than:
        // 80) is true (40 < 72), so this DOES enter the guard check.
        // hostExceedsActive = meaningfullySlower(40, than: 80) = true,
        // so the guard's `!hostExceedsActive` fails and the hedge does
        // NOT fire. Falls through to .degraded(active: 40, expected: 80).
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .usb4Tb4)
        let partner = partnerSwitch(parent: host, parentLanePortNumber: 1, supportedRaw: 0xE)   // TB5-class partner, 80 Gbps
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 4)],   // e-marker claims 80
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),            // controller floor: 40
            thunderboltSwitches: [host, partner],
            tbActiveGbps: 40,
            hostMaxGbps: 80
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.hostGbps == 80)
        #expect(facts.deviceGbps == 80, "Partner switch should report the TB5-class 80 Gbps mask")
        #expect(facts.cableGbps == 80, "E-marker claim stands: not contradicted, CIO tier is lower")
        guard case .degraded(let active, let expected) = diag?.bottleneck else {
            Issue.record("expected .degraded (host and device both independently exceed the active rate), got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 40)
        #expect(expected == 80)
        #expect(diag!.isWarning)
    }

    @Test("Unknown host and device: an above-floor e-marker claim alone does not trigger a false degraded verdict")
    func unknownEndpointsHedgeInsteadOfFalseDegraded() {
        // Neither the Mac port's max nor the connected device's max is
        // known here (no TB switch graph, no USB device enumerated). The
        // e-marker's 80 Gbps claim is the only "capability" figure we
        // have, and it is unverified (CIO only measured 40). Without the
        // unknown-endpoint guard, `expected` would equal the claim (80)
        // and the link (measured 40) would read as "meaningfully slower
        // than expected", producing a false "Running slower than
        // expected" warning on a link that is not actually degraded,
        // just unverified.
        //
        // Arithmetic: caps = [cable=80] only (host and device both nil).
        // expected = 80. meaningfullySlower(40, than: 80) = true, so the
        // guard check runs. hostExceedsActive = false (host unknown),
        // deviceExceedsActive = false (device unknown).
        // cableClaimAboveCIOFloor = true (rule B fired above). All three
        // guard conditions hold -> hedge (.unknownCable), not .degraded.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 4)],   // e-marker claims 80
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),            // controller floor: 40
            tbActiveGbps: 40
            // hostMaxGbps and thunderboltSwitches both omitted: host and
            // device stay unresolved.
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.hostGbps == nil)
        #expect(facts.deviceGbps == nil)
        #expect(facts.cableGbps == 80)
        guard case .unknownCable(let active) = diag?.bottleneck else {
            Issue.record("expected the hedged .unknownCable verdict, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(active == 40)
        #expect(diag!.isWarning == false, "A hedge is informational, not a warning")
        #expect(diag!.detail.contains("80"), "The detail should still mention the cable's claim")
    }

    @Test("CIO cableSpeed 2 maps to 20 Gbps (TB3)")
    func cioSpeed2MapsTB3() {
        // TB3 dock on a TB4 host. CIO reports cableSpeed=2 (20 Gbps).
        // E-marker agrees (speed code 2 = 10 Gbps USB 3.2 Gen 2, but
        // that's the USB-PD encoding; the CIO 20 Gbps is the TB lane
        // rate). Host supports 40, so cable is the bottleneck.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 2),
            tbActiveGbps: 20,
            hostMaxGbps: 40
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.cableControllerGbps == 20)
        #expect(facts.activeGbps == 20)
        guard case .cableLimit(let cableGbps, let capableGbps) = diag?.bottleneck else {
            Issue.record("expected .cableLimit, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(cableGbps == 20)
        #expect(capableGbps == 40)
    }

    @Test("No capability known at all: unknownCable, not a guess")
    func noCapabilityKnown() {
        // Active 10 Gbps link, but no e-marker, no controller data, host
        // unresolved, no device. Nothing to compare against.
        // issue #181: with no device and no restriction, nothing corroborates
        // this reading -- it is exactly the transient-handshake shape the
        // gate exists to suppress (issue #181). Pre-issue #181 this asserted
        // `.unknownCable(active: 10)`; that is the bug.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 2)],        // active 10 Gbps
            cio: nil,
            hostMaxGbps: nil
        )
        #expect(diag == nil, "got: \(String(describing: diag?.bottleneck))")
    }

    @Test("Facts expose the resolved per-party numbers")
    func factsExposeResolvedNumbers() {
        // E-marker says 0.48 (USB 2.0), controller says 40 (TB4 class),
        // host 40, device 10 (speedRaw 4), link active at 40 (TB).
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 0)],   // 0.48
            devices: [device(speedRaw: 4)],              // 10
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),                     // 40
            tbActiveGbps: 40,
            hostMaxGbps: 40
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic with facts, got nil")
            return
        }
        #expect(facts.cableEmarkerGbps == 0.48)
        #expect(facts.cableControllerGbps == 40)
        #expect(facts.cableGbps == 40)        // controller wins
        #expect(facts.deviceGbps == 10)
        #expect(facts.hostGbps == 40)
        #expect(facts.activeGbps == 40)
        #expect(diag!.cableSignalConflict == true)
    }

    // MARK: - TransportsActive gating

    @Test("USB2-only link ignores lingering USB3 transport (issue #187)")
    func usb2OnlyLinkIgnoresLingeringUSB3Transport() {
        // A USB-C to Micro-USB cable negotiates only USB 2.0, but the
        // HPM port controller can leave a `IOPortTransportStateUSB3`
        // service registered (carrying Gen 2 signaling) and assert
        // `IOAccessoryUSBSuperSpeedActive=1`. Neither should produce a
        // 10 Gbps verdict: `TransportsActive` is the authority.
        let diag = DataLinkDiagnostic(
            port: makePort(transportsActive: ["CC", "USB2"], superSpeedActive: true),
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 2)],
            cio: nil,
            hostMaxGbps: nil
        )
        #expect(diag == nil,
            "USB2-only link must not produce a USB3 data-link verdict, got: \(String(describing: diag?.bottleneck))")
    }

    // MARK: - Mac port speed inference

    /// Build a host root TB switch with the given `supportedSpeed` mask and
    /// one active lane port matching `socketID`. Minimal fixture: just
    /// enough for `hostMaxGbpsFromSwitches` to walk to it.
    private func hostSwitch(socketID: String, supportedRaw: UInt8, activeSpeed: LinkGeneration) -> IOThunderboltSwitch {
        let lane = IOThunderboltPort(
            portNumber: 1,
            socketID: socketID,
            adapterType: .lane,
            currentSpeed: activeSpeed,
            currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil,
            rawTargetSpeed: nil,
            linkBandwidthRaw: nil
        )
        return IOThunderboltSwitch(
            id: 100,
            className: "IOIOThunderboltSwitchType5",
            vendorID: 1452,
            vendorName: "Apple Inc.",
            modelName: "Mac",
            routerID: 0,
            depth: 0,
            routeString: 0,
            upstreamPortNumber: 0,
            maxPortNumber: 8,
            supportedSpeed: SupportedSpeedMask(rawValue: supportedRaw),
            ports: [lane],
            parentSwitchUID: nil
        )
    }

    @Test("hostMaxGbps inferred from host root supportedSpeed (TB4-class controller)")
    func hostMaxGbpsInferredTB4() {
        // Mac with a Type5 controller: supports TB3 + TB4. Max = 40 Gbps.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xC, activeSpeed: .usb4Tb4)
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 2)],
            cio: nil,
            thunderboltSwitches: [host]
            // hostMaxGbps deliberately omitted; should be inferred from `host`.
        )
        #expect(diag?.facts.hostGbps == 40,
            "Expected 40 Gbps host max from Type5 supportedSpeed mask, got: \(String(describing: diag?.facts.hostGbps))")
    }

    @Test("hostMaxGbps inferred from host root supportedSpeed (TB5-class controller)")
    func hostMaxGbpsInferredTB5() {
        // Mac with a Type7 controller: supports TB3 + TB4 + TB5. Max = 80.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .tb5)
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 2)],
            cio: nil,
            thunderboltSwitches: [host]
        )
        #expect(diag?.facts.hostGbps == 80,
            "Expected 80 Gbps host max from Type7 supportedSpeed mask, got: \(String(describing: diag?.facts.hostGbps))")
    }

    @Test("Per-port supportedSpeed beats the switch aggregate (asymmetric controller)")
    func perPortSupportedSpeedBeatsAggregate() {
        // Build an asymmetric host root: port socket "1" supports only
        // TB4 (per-port mask 0xC), while the switch-level aggregate is
        // 0xE (TB3 + TB4 + TB5) -- the shape the OR-the-lane-ports
        // fallback would produce on a switch with another TB5-capable
        // lane elsewhere. Using `root.supportedSpeed.maxTotalGbps`
        // would falsely report 80 Gbps for the socket-1 user. The
        // matched port's own mask must win.
        let socket1Port = IOThunderboltPort(
            portNumber: 1, socketID: "1", adapterType: .lane,
            currentSpeed: .usb4Tb4, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xC)   // TB3 + TB4 only
        )
        let socket9Port = IOThunderboltPort(
            portNumber: 9, socketID: "9", adapterType: .lane,
            currentSpeed: .tb5, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE)   // TB3 + TB4 + TB5
        )
        let asymmetricRoot = IOThunderboltSwitch(
            id: 100,
            className: "IOThunderboltSwitchType7",
            vendorID: 1452,
            vendorName: "Apple Inc.",
            modelName: "Mac",
            routerID: 0,
            depth: 0,
            routeString: 0,
            upstreamPortNumber: 0,
            maxPortNumber: 8,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),  // misleading aggregate
            ports: [socket1Port, socket9Port],
            parentSwitchUID: nil
        )
        let diag = DataLinkDiagnostic(
            port: makePort(),                                   // serviceName Port-USB-C@1 → socket "1"
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 2)],
            cio: nil,
            thunderboltSwitches: [asymmetricRoot]
        )
        #expect(diag?.facts.hostGbps == 40,
            "Expected 40 Gbps from port-1's own mask, not 80 Gbps from the switch aggregate. Got: \(String(describing: diag?.facts.hostGbps))")
    }

    @Test("Zero supportedSpeed mask returns nil (no host blame)")
    func zeroMaskReturnsNil() {
        // A switch with no supported-speed bits at all (mask 0) must
        // produce nil hostGbps so the diagnostic never blames the host.
        let host = hostSwitch(socketID: "1", supportedRaw: 0, activeSpeed: .usb4Tb4)
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 2)],
            cio: nil,
            thunderboltSwitches: [host]
        )
        #expect(diag?.facts.hostGbps == nil)
    }

    // MARK: - Thunderbolt partner switch as device cap (issue #190)

    /// Build a depth-1 partner switch attached to `parent` via `parent`'s
    /// lane port `parentLanePortNumber`. `supportedRaw` is the partner's
    /// own supported-speed mask, which is what the diagnostic uses as the
    /// connected device's capability.
    ///
    /// Mirrors what real IOKit topology looks like (verified against the
    /// Samsung C34J79x fixture in `ThunderboltLinkFromTests`):
    ///   * `parentSwitchUID` points at the parent's UID.
    ///   * `routeString` low byte is the parent's downstream port number
    ///     leading to this child (not the child's own port number).
    ///   * `upstreamPortNumber` is the child's OWN port number for its
    ///     upstream link. Real partners often have this value at 3 even
    ///     when the parent connects through port 1.
    /// `thunderboltVersion`/`deviceID`/`vendorID` default to values that
    /// never trigger `deviceGenerationCapGbps` (nil version, nil device
    /// id), so existing callers are unaffected; issue #515 tests pass real
    /// values to build a TB1/TB2-era partner or terminal switch.
    private func partnerSwitch(
        parent: IOThunderboltSwitch,
        parentLanePortNumber: Int,
        supportedRaw: UInt8,
        partnerOwnUpstreamPortNumber: Int = 3,
        thunderboltVersion: Int? = nil,
        deviceID: Int? = nil,
        vendorID: Int = 9999
    ) -> IOThunderboltSwitch {
        let upstream = IOThunderboltPort(
            portNumber: partnerOwnUpstreamPortNumber, socketID: nil, adapterType: .lane,
            currentSpeed: .usb4Tb4, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil,
            supportedSpeed: SupportedSpeedMask(rawValue: supportedRaw)
        )
        return IOThunderboltSwitch(
            id: parent.id + Int64(parentLanePortNumber),
            className: "IOThunderboltSwitchType5",
            vendorID: vendorID,
            vendorName: "Partner",
            modelName: "Partner Device",
            routerID: 1,
            depth: 1,
            routeString: Int64(parentLanePortNumber),
            upstreamPortNumber: partnerOwnUpstreamPortNumber,
            maxPortNumber: 4,
            supportedSpeed: SupportedSpeedMask(rawValue: supportedRaw),
            ports: [upstream],
            parentSwitchUID: parent.id,
            thunderboltVersion: thunderboltVersion,
            deviceID: deviceID
        )
    }

    @Test("TB partner switch supplies the device cap (issue #190, Port 4)")
    func tbPartnerSwitchSuppliesDeviceCap() {
        // LaCie d2 TB3 scenario: TB3 partner (40 Gbps), no USB device, TB5
        // host (80 Gbps), 40 Gbps cable, link active at 40. Without the
        // partner-switch lookup the diagnostic had no device cap and
        // blamed the cable. With it: device = 40 from partner, cable = 40,
        // host = 80 → device limit, no cable blame.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .usb4Tb4)
        let partner = partnerSwitch(parent: host, parentLanePortNumber: 1, supportedRaw: 0x8)   // TB3 only
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps cable
            devices: [],                                  // TB-only device, no USB enum
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),                     // controller confirms 40
            thunderboltSwitches: [host, partner],
            tbActiveGbps: 40
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.deviceGbps == 40,
            "Expected 40 Gbps device cap from partner TB switch (TB3 mask). Got: \(String(describing: facts.deviceGbps))")
        if case .cableLimit = diag?.bottleneck {
            Issue.record("Expected device-side outcome, not cable blame: \(String(describing: diag?.bottleneck))")
        }
    }

    @Test("TB partner overrides a slow USB sub-device (issue #190, Ports 2/3)")
    func tbPartnerOverridesUSBSubDevice() {
        // WERO TBT4 hub scenario: TB4 partner (40 Gbps), but a 10 Gbps USB
        // hub IC inside the dock enumerates as a USB device. Active link is
        // 40 Gbps. Without the partner-switch lookup the diagnostic took
        // the USB device's 10 Gbps as the device cap and announced
        // "Device runs at 10 Gbps." With it: device = 40 from partner,
        // matching the 40 Gbps link → fine, no "10 Gbps" verdict.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .usb4Tb4)
        let partner = partnerSwitch(parent: host, parentLanePortNumber: 1, supportedRaw: 0xC)   // TB3 + TB4
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps cable
            devices: [device(speedRaw: 4)],              // 10 Gbps internal USB hub
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),                     // 40 Gbps
            thunderboltSwitches: [host, partner],
            tbActiveGbps: 40
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.deviceGbps == 40,
            "TB partner (40) must win over the internal USB hub IC (10). Got: \(String(describing: facts.deviceGbps))")
        // The link runs at the TB4 partner's cap (40 Gbps) against a TB5
        // host. That makes the device the (non-actionable) limit, which is
        // not a fault. The crucial thing is the *number*: 40, not 10.
        guard case .deviceLimit(let d) = diag?.bottleneck else {
            Issue.record("expected .deviceLimit at the partner's TB4 cap, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(d == 40, "Reported device limit should match the partner switch's mask, not the internal USB IC")
        #expect(diag!.isWarning == false, "A TB4 partner on a TB5 host is informational, not a warning")
    }

    @Test("Falls back to USB device speed when no TB partner switch present")
    func fallsBackToUSBDeviceWithoutPartner() {
        // Plain USB-C SSD: no TB partner, just a USB device at 10 Gbps.
        // The USB device cap should still drive the verdict.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .usb4Tb4)
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps cable
            devices: [device(speedRaw: 4)],              // 10 Gbps USB device
            usb3Transports: [usb3(signaling: 2)],        // active 10 Gbps
            cio: nil,
            thunderboltSwitches: [host]                  // host only, no partner
        )
        #expect(diag?.facts.deviceGbps == 10)
        guard case .deviceLimit(let d) = diag?.bottleneck else {
            Issue.record("expected .deviceLimit when only USB device present, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(d == 10)
    }

    @Test("Partner switch on a sibling lane port is not used for this port")
    func partnerSwitchOnOtherLaneIgnored() {
        // Controller hosts two user-visible USB-C ports on the same root.
        // Port-USB-C@1 has no partner. The sibling lane (socket "9") has
        // a TB5 partner. The diagnostic for socket "1" must not borrow
        // the sibling's partner; deviceGbps should fall back to USB.
        let socket1Lane = IOThunderboltPort(
            portNumber: 1, socketID: "1", adapterType: .lane,
            currentSpeed: .usb4Tb4, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE)
        )
        let socket9Lane = IOThunderboltPort(
            portNumber: 9, socketID: "9", adapterType: .lane,
            currentSpeed: .usb4Tb4, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE)
        )
        let root = IOThunderboltSwitch(
            id: 100,
            className: "IOThunderboltSwitchType7",
            vendorID: 1452,
            vendorName: "Apple Inc.",
            modelName: "Mac",
            routerID: 0,
            depth: 0,
            routeString: 0,
            upstreamPortNumber: 0,
            maxPortNumber: 16,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: [socket1Lane, socket9Lane],
            parentSwitchUID: nil
        )
        // Partner attached to the *sibling* lane (port 9), not port 1.
        let siblingPartner = partnerSwitch(parent: root, parentLanePortNumber: 9, supportedRaw: 0xE)
        let diag = DataLinkDiagnostic(
            port: makePort(),                             // Port-USB-C@1 → socket "1"
            identities: [],
            devices: [device(speedRaw: 4)],              // 10 Gbps USB device on this port
            usb3Transports: [usb3(signaling: 2)],
            cio: nil,
            thunderboltSwitches: [root, siblingPartner]
        )
        #expect(diag?.facts.deviceGbps == 10,
            "Sibling lane's TB partner must not be used as this port's device cap. Got: \(String(describing: diag?.facts.deviceGbps))")
    }

    // MARK: - Deep terminal switch on a multi-hop chain (issue #507)

    @Test("Two-hop chain uses the terminal device's cap, not the middleman adapter's")
    func twoHopChainUsesTerminalDeviceCap() {
        // Reported scenario (issue #507): M3 Pro TB4 host -> Apple TB2-to-
        // TB3 adapter -> LaCie Rugged THB (TB1 drive). The old code used
        // `partnerSwitch`, which only ever looks one hop deep, so it read
        // the ADAPTER's capability mask (40 Gbps-class silicon) as "the
        // device", blamed a perfectly fine 40 Gbps cable for a 40 Gbps
        // gap that was really the drive's own ceiling.
        //
        // Masks in this model only resolve to 40 or 80 Gbps
        // (`SupportedSpeedMask.maxTotalGbps`: TB3/TB4 bits -> 40, TB5 bit
        // -> 80), so the fixture uses those two tiers to stand in for
        // "the adapter looks fast" (mid = 0x2, TB5 bit, 80 Gbps) vs "the
        // real device is slower" (terminal = 0x8, TB3 bit, 40 Gbps). The
        // arithmetic that matters is the priority walk below, not the
        // exact numbers: whichever tier is lowest becomes `expected`, and
        // whoever else shares that tier is named over a faster host.
        //
        //   host   = 0xE (TB3+TB4+TB5 bits) -> 80 Gbps, never the floor
        //   mid    = 0x2 (TB5 bit only)      -> 80 Gbps  (the adapter)
        //   terminal = 0x8 (TB3 bit only)    -> 40 Gbps  (the real drive)
        //   cable  = 40 Gbps (e-marker code 3 + CIO code 3, agreeing)
        //   active = 40 Gbps
        //
        // OLD (buggy) resolution: deviceMaxGbps = mid.mask = 80.
        //   caps = [cable 40, host 80, device 80] -> expected = min = 40.
        //   limiters at 40 = [cable] only -> culprit = "cable".
        //   bottleneck = .cableLimit(cableGbps: 40, capableGbps: 80).
        //   This is exactly the false "cable is limiting" verdict from
        //   the report.
        //
        // NEW (fixed) resolution: deviceMaxGbps = terminal.mask = 40.
        //   caps = [cable 40, host 80, device 40] -> expected = min = 40.
        //   limiters at 40 = [cable, device] -> culprit priority
        //   (device, host, cable) picks "device" since it's also at the
        //   floor. bottleneck = .deviceLimit(deviceGbps: 40). No cable
        //   blame; the 40 Gbps cable is exonerated.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .usb4Tb4)
        let mid = partnerSwitch(parent: host, parentLanePortNumber: 1, supportedRaw: 0x2)      // adapter, TB5 bit -> 80
        let terminal = partnerSwitch(parent: mid, parentLanePortNumber: 1, supportedRaw: 0x8)  // real drive, TB3 bit -> 40
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps e-marker
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),           // 40 Gbps, agrees with e-marker
            thunderboltSwitches: [host, mid, terminal],
            tbActiveGbps: 40
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.deviceGbps == 40,
            "Device cap must come from the TERMINAL switch (40), not the middleman adapter (80). Got: \(String(describing: facts.deviceGbps))")
        if case .cableLimit = diag?.bottleneck {
            Issue.record("Must not blame the cable when the true bottleneck is the terminal device: \(String(describing: diag?.bottleneck))")
        }
        guard case .deviceLimit(let d) = diag?.bottleneck else {
            Issue.record("expected .deviceLimit once the terminal device's cap is used, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(d == 40)
    }

    @Test("Branching tree keeps the direct partner as the device cap (unchanged)")
    func branchingTreeKeepsDirectPartner() {
        // A dock plugged into the host fans out to two Thunderbolt
        // devices. `deepTerminalSwitch` must bail on this shape (there is
        // no single "last" device -- exactly the reasoning
        // `PortSummary.thunderboltBullets` already uses for its own
        // step-down guard), so the diagnostic must keep using the direct
        // partner (the dock itself), unchanged from today.
        //
        // dock (direct partner) = 0x4 (usb4Tb4 bit) -> 40 Gbps
        // childA, childB (behind the dock) = 0x2 (tb5 bit) -> 80 Gbps each
        // If the branching guard failed and the walk picked a child as
        // "the terminal", deviceGbps would read 80. It must read 40.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .usb4Tb4)
        let dock = partnerSwitch(parent: host, parentLanePortNumber: 1, supportedRaw: 0x4)
        let childA = partnerSwitch(parent: dock, parentLanePortNumber: 1, supportedRaw: 0x2)
        let childB = partnerSwitch(parent: dock, parentLanePortNumber: 2, supportedRaw: 0x2)
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),
            thunderboltSwitches: [host, dock, childA, childB],
            tbActiveGbps: 40
        )
        #expect(diag?.facts.deviceGbps == 40,
            "Branching tree must keep using the direct partner (dock, 40), not walk into a child (80). Got: \(String(describing: diag?.facts.deviceGbps))")
    }

    @Test("Sibling socket's chain is not attributed to this port")
    func siblingSocketChainNotAttributedToThisPort() {
        // A root can host more than one user-visible USB-C lane (socket
        // "1" and socket "9" on the same physical controller). A genuine
        // two-hop chain hanging off the SIBLING socket 9 must never be
        // read as socket 1's terminal device. Socket 1 has nothing
        // attached at all here.
        //
        // `deepTerminalSwitch` used to resolve the walk from the shared
        // host root, not the port-qualified partner, so it had no way to
        // tell which lane a chain belonged to: `chain(from: root, ...)`
        // just follows byParent's first child, regardless of which
        // socket that child's routeString actually matches. Depending on
        // iteration order, a socket-1 query could walk straight into
        // socket 9's chain and read its terminal device (dock9Terminal)
        // as socket 1's.
        let socket1Lane = IOThunderboltPort(
            portNumber: 1, socketID: "1", adapterType: .lane,
            currentSpeed: nil, currentWidth: LinkWidth(rawValue: 0),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE)
        )
        let socket9Lane = IOThunderboltPort(
            portNumber: 9, socketID: "9", adapterType: .lane,
            currentSpeed: .usb4Tb4, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE)
        )
        let root = IOThunderboltSwitch(
            id: 100, className: "IOThunderboltSwitchType7", vendorID: 1452,
            vendorName: "Apple Inc.", modelName: "Mac", routerID: 0, depth: 0,
            routeString: 0, upstreamPortNumber: 0, maxPortNumber: 16,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: [socket1Lane, socket9Lane], parentSwitchUID: nil
        )
        let dock9 = partnerSwitch(parent: root, parentLanePortNumber: 9, supportedRaw: 0x4)      // socket 9's own partner
        let dock9Terminal = partnerSwitch(parent: dock9, parentLanePortNumber: 1, supportedRaw: 0x8)  // socket 9's terminal, two hops deep

        let terminalForSocket1 = DataLinkDiagnostic.deepTerminalSwitch(
            port: makePort(),   // Port-USB-C@1 -> socket "1"
            switches: [root, dock9, dock9Terminal]
        )
        #expect(terminalForSocket1 == nil,
            "Socket 1 has no partner of its own; socket 9's chain must not be attributed to it. Got: \(String(describing: terminalForSocket1))")

        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [device(speedRaw: 4)],   // 10 Gbps USB device on THIS port
            usb3Transports: [usb3(signaling: 2)],
            cio: nil,
            thunderboltSwitches: [root, dock9, dock9Terminal]
        )
        #expect(diag?.facts.deviceGbps == 10,
            "Socket 1's diagnostic must fall back to its own USB device (10), untouched by socket 9's chain. Got: \(String(describing: diag?.facts.deviceGbps))")
    }

    @Test("A branching sibling socket does not make this port's own linear chain look branching")
    func siblingBranchDoesNotFalselyBranchThisPort() {
        // Socket 1 has its own genuine two-hop LINEAR chain. Socket 9,
        // on the same root, fans out to two devices (a branching tree).
        // Before this fix, `deepTerminalSwitch` compared the WHOLE root's
        // downstream tree (both sockets combined) against the chain
        // walked from the root, so socket 9's branching alone was enough
        // to make socket 1's genuinely linear chain look like it
        // branched too, silently disabling the terminal-device fix for
        // socket 1's own query. Scoping the walk to socket 1's own
        // partner subtree (mid1) must not see socket 9's shape at all.
        let socket1Lane = IOThunderboltPort(
            portNumber: 1, socketID: "1", adapterType: .lane,
            currentSpeed: .usb4Tb4, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE)
        )
        let socket9Lane = IOThunderboltPort(
            portNumber: 9, socketID: "9", adapterType: .lane,
            currentSpeed: .usb4Tb4, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE)
        )
        let root = IOThunderboltSwitch(
            id: 100, className: "IOThunderboltSwitchType7", vendorID: 1452,
            vendorName: "Apple Inc.", modelName: "Mac", routerID: 0, depth: 0,
            routeString: 0, upstreamPortNumber: 0, maxPortNumber: 16,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: [socket1Lane, socket9Lane], parentSwitchUID: nil
        )
        // Socket 1: linear, mid1 -> terminal1.
        let mid1 = partnerSwitch(parent: root, parentLanePortNumber: 1, supportedRaw: 0x2)       // 80, irrelevant here
        let terminal1 = partnerSwitch(parent: mid1, parentLanePortNumber: 1, supportedRaw: 0x8)  // 40, the real terminal
        // Socket 9: branching, dock9 -> childA9, childB9.
        let dock9 = partnerSwitch(parent: root, parentLanePortNumber: 9, supportedRaw: 0x4)
        let childA9 = partnerSwitch(parent: dock9, parentLanePortNumber: 1, supportedRaw: 0x2)
        let childB9 = partnerSwitch(parent: dock9, parentLanePortNumber: 2, supportedRaw: 0x2)

        let terminalForSocket1 = DataLinkDiagnostic.deepTerminalSwitch(
            port: makePort(),   // Port-USB-C@1 -> socket "1"
            switches: [root, mid1, terminal1, dock9, childA9, childB9]
        )
        #expect(terminalForSocket1?.id == terminal1.id,
            "Socket 1's own linear chain must resolve to terminal1, unaffected by socket 9's branching. Got: \(String(describing: terminalForSocket1))")
    }

    @Test("A forged parentSwitchUID cycle inside the partner subtree still terminates and yields a verdict")
    func cyclicPartnerSubtreeTerminates() {
        // `deepTerminalSwitch` walks `ThunderboltTopology.chain` and
        // `ThunderboltTopology.tree` from the resolved partner. `chain`
        // already guards against a parentSwitchUID cycle; `tree` didn't
        // until this fix, so a malformed (or hand-forged) graph with a
        // cycle reachable from the partner would recurse forever inside
        // the diagnostic itself. A hang is the worst failure available
        // here, so it must be ruled out structurally.
        //
        // Graph, all hanging off `mid` (the resolved partner):
        //   mid -> a (parentSwitchUID = mid.id)
        //   a   -> b (parentSwitchUID = a.id)
        //   b   -> a' (SAME id as `a`, parentSwitchUID = b.id) -- closes
        //             a -> b -> a' -> ... into a cycle
        //
        // `chain`'s existing seen-set stops at the duplicate and returns
        // [mid, a, b]. `tree`'s new seen-set does the same: it builds
        // a's subtree once, reaches b, then drops the duplicate a' (its
        // id is already seen) instead of recursing into it again. Both
        // walks terminate and agree the subtree is linear (2 downstream
        // switches either way), so `deepTerminalSwitch` returns `b`, and
        // the diagnostic produces an ordinary verdict from b's mask (40).
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .usb4Tb4)
        let mid = partnerSwitch(parent: host, parentLanePortNumber: 1, supportedRaw: 0x2)
        let aPort = IOThunderboltPort(
            portNumber: 3, socketID: nil, adapterType: .lane,
            currentSpeed: .usb4Tb4, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE)
        )
        let a = IOThunderboltSwitch(
            id: 501, className: "IOThunderboltSwitchType5", vendorID: 9999,
            vendorName: "Partner", modelName: "A", routerID: 2, depth: 2,
            routeString: 1, upstreamPortNumber: 3, maxPortNumber: 4,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),   // 80, must not be used (a is not the terminal)
            ports: [aPort], parentSwitchUID: mid.id
        )
        let bPort = IOThunderboltPort(
            portNumber: 3, socketID: nil, adapterType: .lane,
            currentSpeed: .usb4Tb4, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil,
            supportedSpeed: SupportedSpeedMask(rawValue: 0x8)
        )
        let b = IOThunderboltSwitch(
            id: 502, className: "IOThunderboltSwitchType5", vendorID: 9999,
            vendorName: "Partner", modelName: "B", routerID: 3, depth: 3,
            routeString: 1, upstreamPortNumber: 3, maxPortNumber: 4,
            supportedSpeed: SupportedSpeedMask(rawValue: 0x8),   // 40, must be used (b is the real terminal)
            ports: [bPort], parentSwitchUID: a.id
        )
        // Same id as `a` (501), but claims its parent is `b`: closes the cycle.
        let aAgain = IOThunderboltSwitch(
            id: 501, className: "IOThunderboltSwitchType5", vendorID: 9999,
            vendorName: "Partner", modelName: "A (duplicate)", routerID: 2, depth: 4,
            routeString: 1, upstreamPortNumber: 3, maxPortNumber: 4,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: [], parentSwitchUID: b.id
        )
        let switches = [host, mid, a, b, aAgain]

        let terminal = DataLinkDiagnostic.deepTerminalSwitch(port: makePort(), switches: switches)
        #expect(terminal?.id == b.id,
            "Expected the walk to terminate at b (id 502), got: \(String(describing: terminal))")

        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [],
            usb3Transports: [],
            cio: nil,
            thunderboltSwitches: switches,
            tbActiveGbps: 40
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic with facts even with a cyclic subtree, got nil")
            return
        }
        #expect(facts.deviceGbps == 40,
            "Expected b's mask (40) to drive the verdict. Got: \(String(describing: facts.deviceGbps))")
    }

    @Test("Terminal switch with no supportedSpeed mask falls back to its active lane speed")
    func terminalWithoutMaskFallsBackToLaneSpeed() {
        // The terminal switch on a genuine two-hop chain sometimes has no
        // `supportedSpeed` mask of its own (rawValue 0 -> no TB3/TB4/TB5
        // bits set -> `maxTotalGbps` is nil). The fixture's `partnerSwitch`
        // helper hardcodes the port's own `currentSpeed` to `.usb4Tb4`
        // (totalGbps 40) regardless of the mask, which stands in for "the
        // link to this device is actually up at 40 Gbps even though we
        // don't know its full capability". The fallback must read that
        // active leg, not silently produce nil.
        //
        // The host's own active TB speed is set to `.tb5` (80) on purpose,
        // deliberately DIFFERENT from the terminal leg's 40, so the test
        // can tell the two fallbacks apart:
        //
        //   terminal leg fallback (terminalLegActiveGbps)  -> .usb4Tb4 -> 40
        //   final host-side fallback (activeTBGbps)         -> .tb5     -> 80
        //
        // With only one fallback value (both at 40, as this test used to
        // set up), a bug that skipped straight to the host-side fallback
        // and bypassed the terminal leg entirely would still read 40 and
        // pass. Asserting 40 here, against a host reading of 80, only
        // passes if the terminal leg fallback actually ran.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .tb5)
        let mid = partnerSwitch(parent: host, parentLanePortNumber: 1, supportedRaw: 0x2)   // 80, irrelevant here
        let terminal = partnerSwitch(parent: mid, parentLanePortNumber: 1, supportedRaw: 0)  // mask nil
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [],
            usb3Transports: [],
            cio: nil,
            thunderboltSwitches: [host, mid, terminal],
            tbActiveGbps: 40
        )
        #expect(diag?.facts.deviceGbps == 40,
            "Missing terminal mask must fall back to the terminal leg's active lane speed (40), not the host-side reading (80). Got: \(String(describing: diag?.facts.deviceGbps))")
    }

    @Test("Terminal leg fallback prefers the switch's own upstream lane over a stale downstream one")
    func terminalLegFallbackPrefersUpstreamOverStaleDownstream() {
        // The leg that actually arrives at the terminal switch is its OWN
        // upstream lane (the port whose portNumber matches its
        // upstreamPortNumber), not any downstream lane it might still
        // expose. A downstream lane left active on a "terminal" switch is
        // left over from a child record that's temporarily absent (a
        // fabric read mid-update); reading it would describe the leg
        // toward a device that isn't there.
        //
        //   upstream lane   (portNumber 3, matches upstreamPortNumber) = .usb4Tb4 -> 40 (the real arriving leg)
        //   downstream lane (portNumber 4, stale)                     = .tb5     -> 80 (leftover, must be ignored)
        //
        // If the fallback preferred the downstream lane (the old
        // behaviour), deviceGbps would read 80. It must read 40.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .usb4Tb4)
        let mid = partnerSwitch(parent: host, parentLanePortNumber: 1, supportedRaw: 0x2)
        let upstreamLeg = IOThunderboltPort(
            portNumber: 3, socketID: nil, adapterType: .lane,
            currentSpeed: .usb4Tb4, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil
        )
        let staleDownstreamLeg = IOThunderboltPort(
            portNumber: 4, socketID: nil, adapterType: .lane,
            currentSpeed: .tb5, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil
        )
        let terminal = IOThunderboltSwitch(
            id: mid.id + 1,
            className: "IOThunderboltSwitchType5",
            vendorID: 9999,
            vendorName: "Partner",
            modelName: "Ghost Terminal",
            routerID: 2,
            depth: 2,
            routeString: 1,
            upstreamPortNumber: 3,
            maxPortNumber: 4,
            supportedSpeed: SupportedSpeedMask(rawValue: 0),   // no mask -> forces the leg fallback
            ports: [upstreamLeg, staleDownstreamLeg],
            parentSwitchUID: mid.id
        )
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [],
            usb3Transports: [],
            cio: nil,
            thunderboltSwitches: [host, mid, terminal],
            tbActiveGbps: 40
        )
        #expect(diag?.facts.deviceGbps == 40,
            "Must read the arriving upstream leg (40), not the stale downstream leg (80). Got: \(String(describing: diag?.facts.deviceGbps))")
    }

    // MARK: - TB1/TB2-era device generation cap (issue #515)

    @Test("Direct-attached TB1 device caps both the negotiated and device figures at 10 Gbps")
    func directAttachedTB1DeviceCapsAt10() {
        // LaCie Rugged THB USB-C (Thunderbolt 1, Intel Port Ridge, Device
        // ID 0x1549) attached to the host via Apple's TB3-to-TB2 adapter.
        // `Current Link Speed` code 0x8 reads as `.tb3` (40 Gbps total,
        // see LinkGeneration), and the real TB1 device's own
        // `supportedSpeed` mask reports the same TB3 bit, but the actual
        // link is a single 10 Gb/s lane. Before this fix both the
        // negotiated figure and the device figure read "40 Gbps" and the
        // cable took the blame (Mac 40 / cable 20 / device 40 -> cable
        // limit). `thunderboltVersion == 1` is the corpus-verified,
        // uncontaminated signal for genuine TB1 silicon, so it caps both
        // figures at 10.
        let hostLane = IOThunderboltPort(
            portNumber: 1, socketID: "1", adapterType: .lane,
            currentSpeed: .tb3, currentWidth: LinkWidth(rawValue: 0x1),   // single lane
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil
        )
        let host = IOThunderboltSwitch(
            id: 300,
            className: "IOThunderboltSwitchType5",
            vendorID: 1452,
            vendorName: "Apple Inc.",
            modelName: "Mac",
            routerID: 0,
            depth: 0,
            routeString: 0,
            upstreamPortNumber: 0,
            maxPortNumber: 8,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xC),
            ports: [hostLane],
            parentSwitchUID: nil
        )
        let partner = IOThunderboltSwitch(
            id: 301,
            className: "IOThunderboltSwitchType2",
            vendorID: 0x8086,
            vendorName: "Intel",
            modelName: "LaCie Rugged THB",
            routerID: 1,
            depth: 1,
            routeString: 1,
            upstreamPortNumber: 3,
            maxPortNumber: 4,
            supportedSpeed: SupportedSpeedMask(rawValue: 0x8),   // reports the TB3 bit despite being TB1
            ports: [],
            parentSwitchUID: host.id,
            thunderboltVersion: 1,
            deviceID: 0x1549
        )
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 2),   // controller reads 20 Gbps
            thunderboltSwitches: [host, partner],
            hostMaxGbps: 40
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.activeGbps == 10,
            "Negotiated figure must be capped to the TB1 device's 10 Gbps ceiling. Got: \(facts.activeGbps)")
        #expect(facts.deviceGbps == 10,
            "Device figure must be capped to the TB1 device's 10 Gbps ceiling. Got: \(String(describing: facts.deviceGbps))")
        #expect(facts.hostGbps == 40,
            "The Mac port's own ceiling must stay uncapped: it is genuinely a 40 Gbps port. Got: \(String(describing: facts.hostGbps))")
        #expect(facts.cableGbps == 20,
            "The cable figure comes from the CIO controller reading and must stay uncapped by the device-side rule. Got: \(String(describing: facts.cableGbps))")
        if case .cableLimit = diag?.bottleneck {
            Issue.record("Must not blame the cable for a TB1 device's own ceiling: \(String(describing: diag?.bottleneck))")
        }
        guard case .deviceLimit(let d) = diag?.bottleneck else {
            Issue.record("expected .deviceLimit at the TB1 device's ceiling, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(d == 10)
    }

    @Test("TB3 controller reporting Thunderbolt Version 2 (Alpine Ridge) is NOT capped (the version-2 trap, regression pin)")
    func tb3DockVersion2NotCapped() {
        // `Thunderbolt Version == 2` mixes real TB2 devices (Falcon Ridge)
        // with real TB3 devices (Alpine Ridge, device ID 0x15d3 among
        // others). Capping on version 2 alone would wrongly flag genuine
        // TB3 hardware as TB1/TB2. Figures must stay at their uncapped
        // 40 Gbps.
        let hostLane = IOThunderboltPort(
            portNumber: 1, socketID: "1", adapterType: .lane,
            currentSpeed: .tb3, currentWidth: LinkWidth(rawValue: 0x2),   // dual lane
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil
        )
        let host = IOThunderboltSwitch(
            id: 302,
            className: "IOThunderboltSwitchType5",
            vendorID: 1452,
            vendorName: "Apple Inc.",
            modelName: "Mac",
            routerID: 0,
            depth: 0,
            routeString: 0,
            upstreamPortNumber: 0,
            maxPortNumber: 8,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xC),
            ports: [hostLane],
            parentSwitchUID: nil
        )
        let partner = IOThunderboltSwitch(
            id: 303,
            className: "IOThunderboltSwitchType3",
            vendorID: 0x8086,
            vendorName: "Intel",
            modelName: "TB3 Dock",
            routerID: 1,
            depth: 1,
            routeString: 1,
            upstreamPortNumber: 3,
            maxPortNumber: 4,
            supportedSpeed: SupportedSpeedMask(rawValue: 0x8),
            ports: [],
            parentSwitchUID: host.id,
            thunderboltVersion: 2,
            deviceID: 0x15d3   // Alpine Ridge, TB3
        )
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),   // 40 Gbps, agrees
            thunderboltSwitches: [host, partner],
            hostMaxGbps: 40
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.activeGbps == 40,
            "A version-2 Alpine Ridge (TB3) controller must not be capped. Got: \(facts.activeGbps)")
        #expect(facts.deviceGbps == 40,
            "A version-2 Alpine Ridge (TB3) controller must not be capped. Got: \(String(describing: facts.deviceGbps))")
    }

    @Test("TB4 dock with a TB1 leaf: negotiated stays 40 (the dock's own link), device figure caps at 10")
    func tb4DockWithTB1LeafCapsDeviceOnly() {
        // A healthy TB4 dock sits between the host and a TB1 leaf drive.
        // The dock's own link to the host is a real 40 Gbps TB4 link and
        // must not be dragged down by whatever is further downstream:
        // `activeTBGbps` caps using the FIRST-HOP partner (the dock),
        // which has no TB1/TB2 cap of its own, so the negotiated figure
        // stays 40. The device figure comes from the TERMINAL switch (the
        // TB1 leaf, walked past the dock by `deepTerminalSwitch`) and
        // must be capped at 10. This gives the two cap sites (activeTBGbps
        // vs the device-figure resolution) two genuinely distinct
        // fixtures: the direct-attach tests above collapse partner and
        // terminal into the same switch.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .usb4Tb4)
        let dock = partnerSwitch(parent: host, parentLanePortNumber: 1, supportedRaw: 0xC)   // TB4 dock, no cap
        let leaf = partnerSwitch(
            parent: dock, parentLanePortNumber: 1, supportedRaw: 0x8,
            thunderboltVersion: 1, deviceID: 0x1549                                          // TB1 leaf
        )
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps cable
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),           // 40 Gbps, agrees with the dock's real link
            thunderboltSwitches: [host, dock, leaf]
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.activeGbps == 40,
            "The dock's own link must not be dragged down by a downstream TB1 leaf. Got: \(facts.activeGbps)")
        #expect(facts.deviceGbps == 10,
            "The terminal TB1 leaf's cap must still apply to the device figure. Got: \(String(describing: facts.deviceGbps))")
    }

    @Test("Direct-attached Falcon Ridge TB2 device caps both negotiated and device figures at 20 Gbps")
    func directAttachedFalconRidgeTB2CapsAt20() {
        let hostLane = IOThunderboltPort(
            portNumber: 1, socketID: "1", adapterType: .lane,
            currentSpeed: .tb3, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil
        )
        let host = IOThunderboltSwitch(
            id: 320,
            className: "IOThunderboltSwitchType5",
            vendorID: 1452,
            vendorName: "Apple Inc.",
            modelName: "Mac",
            routerID: 0,
            depth: 0,
            routeString: 0,
            upstreamPortNumber: 0,
            maxPortNumber: 8,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xC),
            ports: [hostLane],
            parentSwitchUID: nil
        )
        let partner = IOThunderboltSwitch(
            id: 321,
            className: "IOThunderboltSwitchType2",
            vendorID: 0x8086,
            vendorName: "Intel",
            modelName: "Falcon Ridge TB2 Dock",
            routerID: 1,
            depth: 1,
            routeString: 1,
            upstreamPortNumber: 3,
            maxPortNumber: 4,
            supportedSpeed: SupportedSpeedMask(rawValue: 0x8),
            ports: [],
            parentSwitchUID: host.id,
            thunderboltVersion: 2,
            deviceID: 0x156d
        )
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 2),   // controller reads 20 Gbps, agrees
            thunderboltSwitches: [host, partner],
            hostMaxGbps: 40
        )
        guard let facts = diag?.facts else {
            Issue.record("expected a diagnostic, got nil")
            return
        }
        #expect(facts.activeGbps == 20,
            "Negotiated figure must be capped to the Falcon Ridge TB2 ceiling. Got: \(facts.activeGbps)")
        #expect(facts.deviceGbps == 20,
            "Device figure must be capped to the Falcon Ridge TB2 ceiling. Got: \(String(describing: facts.deviceGbps))")
    }

    @Test("min() preserves an already-lower raw device figure instead of raising it to a further-hop cap")
    func capMinPreservesAlreadyLowerRawFigure() {
        // Two-hop chain: host -> TB1 mid (cap 10) -> Falcon Ridge TB2
        // terminal (cap 20). The terminal has no supportedSpeed mask and
        // no active leg of its own, so its device figure falls all the
        // way back to `activeTBGbps`, which is already capped by the
        // FIRST-HOP partner (the TB1 mid, cap 10). The terminal's own
        // (higher) cap of 20 must not raise that already-lower figure
        // back up: min(10, 20) stays 10. A buggy implementation that
        // clamped with max(), or unconditionally overwrote the raw figure
        // with the cap, would read 20 here.
        let hostLane = IOThunderboltPort(
            portNumber: 1, socketID: "1", adapterType: .lane,
            currentSpeed: .tb3, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil
        )
        let host = IOThunderboltSwitch(
            id: 330,
            className: "IOThunderboltSwitchType5",
            vendorID: 1452,
            vendorName: "Apple Inc.",
            modelName: "Mac",
            routerID: 0,
            depth: 0,
            routeString: 0,
            upstreamPortNumber: 0,
            maxPortNumber: 8,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xC),
            ports: [hostLane],
            parentSwitchUID: nil
        )
        let midUpstream = IOThunderboltPort(
            portNumber: 3, socketID: nil, adapterType: .lane,
            currentSpeed: .usb4Tb4, currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil, rawTargetSpeed: nil, linkBandwidthRaw: nil
        )
        let mid = IOThunderboltSwitch(
            id: 331,
            className: "IOThunderboltSwitchType2",
            vendorID: 0x8086,
            vendorName: "Intel",
            modelName: "TB1 Adapter",
            routerID: 1,
            depth: 1,
            routeString: 1,
            upstreamPortNumber: 3,
            maxPortNumber: 4,
            supportedSpeed: SupportedSpeedMask(rawValue: 0x8),
            ports: [midUpstream],
            parentSwitchUID: host.id,
            thunderboltVersion: 1,
            deviceID: 0x1549
        )
        let terminal = IOThunderboltSwitch(
            id: 332,
            className: "IOThunderboltSwitchType2",
            vendorID: 0x8086,
            vendorName: "Intel",
            modelName: "Falcon Ridge TB2 Terminal",
            routerID: 2,
            depth: 2,
            routeString: 1,
            upstreamPortNumber: 3,
            maxPortNumber: 4,
            supportedSpeed: SupportedSpeedMask(rawValue: 0),   // no mask -> forces the fallback chain
            ports: [],                                          // no upstream leg -> forces the host-side fallback
            parentSwitchUID: mid.id,
            thunderboltVersion: 2,
            deviceID: 0x156d
        )
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [],
            usb3Transports: [],
            cio: nil,
            thunderboltSwitches: [host, mid, terminal]
        )
        #expect(diag?.facts.deviceGbps == 10,
            "Already-capped raw figure (10, from the first-hop TB1 mid) must not be raised to the terminal's own 20 Gbps cap. Got: \(String(describing: diag?.facts.deviceGbps))")
    }

    // MARK: - Culprit priority on tied floors (issue #190, Port 1)

    @Test("Cable + device tied at the floor: blame device, not cable")
    func cableAndDeviceTiedAtFloorBlamesDevice() {
        // WERO TBT3 SSD scenario: TB3 device (40 Gbps), TB3 cable (40 Gbps
        // via controller), TB5 host (80 Gbps), active 40 Gbps. Both cable
        // and device are at the floor; replacing the cable would not
        // unlock more speed because the device caps there too. The verdict
        // must be device-side, not "cable is limiting."
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .usb4Tb4)
        let partner = partnerSwitch(parent: host, parentLanePortNumber: 1, supportedRaw: 0x8)   // TB3
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],   // 40 Gbps cable
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),                     // 40 Gbps
            thunderboltSwitches: [host, partner],
            tbActiveGbps: 40
        )
        if case .cableLimit = diag?.bottleneck {
            Issue.record("Cable tied with device at 40 must not be blamed as the cable limit: got \(String(describing: diag?.bottleneck))")
        }
        guard case .deviceLimit(let d) = diag?.bottleneck else {
            Issue.record("expected .deviceLimit when cable + device tie at the floor, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(d == 40)
    }

    @Test("Partner switch matching uses routeString, not its own upstreamPortNumber")
    func partnerMatchingUsesRouteStringNotUpstreamPortNumber() {
        // Critical regression guard. Real partner switches report their
        // OWN upstream port number (3 on the Samsung C34J79x), which is
        // different from the parent host port they connect through (1).
        // Earlier drafts of this fix incorrectly matched against the
        // child's upstreamPortNumber and would not find the real partner.
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .usb4Tb4)
        let partner = partnerSwitch(
            parent: host,
            parentLanePortNumber: 1,                 // parent's downstream port is 1
            supportedRaw: 0x8,                        // TB3-class partner
            partnerOwnUpstreamPortNumber: 3          // partner's own upstream is 3 (Samsung pattern)
        )
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),
            thunderboltSwitches: [host, partner],
            tbActiveGbps: 40
        )
        #expect(diag?.facts.deviceGbps == 40,
            "Partner must be found by routeString (low byte == parent port number), not by upstreamPortNumber. Got: \(String(describing: diag?.facts.deviceGbps))")
    }

    @Test("Partner with empty supportedSpeed mask uses active TB rate")
    func partnerWithEmptyMaskUsesActiveRate() {
        // Defence-in-depth: a partner switch can be present but expose an
        // empty `supportedSpeed` mask (unrecognised bits, firmware that
        // doesn't populate the field). Falling back to USB devices would
        // re-introduce the "Device runs at 10 Gbps" bug whenever the dock
        // has a USB hub IC. Instead, the active negotiated TB rate is the
        // floor: the partner is at least that fast (it just negotiated).
        let host = hostSwitch(socketID: "1", supportedRaw: 0xE, activeSpeed: .usb4Tb4)
        let partner = partnerSwitch(
            parent: host,
            parentLanePortNumber: 1,
            supportedRaw: 0                          // empty mask
        )
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 3)],
            devices: [device(speedRaw: 4)],          // 10 Gbps USB IC behind the dock
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),
            thunderboltSwitches: [host, partner],
            tbActiveGbps: 40
        )
        #expect(diag?.facts.deviceGbps == 40,
            "Empty partner mask should fall back to the active TB rate (40), not the USB IC (10). Got: \(String(describing: diag?.facts.deviceGbps))")
    }

    // MARK: - E-marker claim above the CIO floor (issue #393)

    @Test("E-marker claim above the CIO floor resolves directly, independent of `active`")
    func cableSpeedFlooredAtActiveRate() {
        // Historical name: this used to test the old "promote cable to
        // active" floor hack for a hypothetical stale-CIO reading. That
        // branch is gone (CIO and the active TB rate are read from the
        // same lane state, so CIO can never legitimately disagree with
        // `active` in real data; see the deleted comment this test used
        // to reference). This fixture still exercises a real code path:
        // the e-marker's claim (80) is above the CIO floor (40), so per
        // the rule-B resolution `cableMaxGbps` takes the e-marker's value
        // (80) directly. It does not matter what `active` happens to be
        // here (80, in this fixture, purely as a test seam value); the
        // e-marker's claim is not derived from `active` at all.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 4)],   // e-marker says 80
            devices: [],
            usb3Transports: [],
            cio: cio(negotiatedLinkSpeed: 3),            // controller floor: 40
            tbActiveGbps: 80,                            // link active (test seam value)
            hostMaxGbps: 80
        )
        #expect(diag?.facts.cableGbps == 80,
            "E-marker claim above the CIO floor resolves directly to the claim. Got: \(String(describing: diag?.facts.cableGbps))")
        #expect(diag?.cableSignalConflict == false,
            "Not a conflict: CIO tier is lower than the e-marker's claim")
    }

    @Test("Cable is unique floor: still blame cable")
    func cableUniqueFloorStillBlamesCable() {
        // 5 Gbps cable, 20 Gbps device, 20 Gbps host, active 5 Gbps.
        // Cable is the only thing at the floor; the priority swap must
        // not stop it from being identified as the actionable culprit.
        // issue #181: corroborate with a low-speed port-matched device.
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [cableEmarker(speedCode: 1)],   // 5 Gbps
            devices: [device(speedRaw: 5), corroboratingPortMatchedDevice()],  // 20 Gbps + corroboration
            usb3Transports: [usb3(signaling: 1)],        // active 5 Gbps
            cio: nil,
            hostMaxGbps: 20
        )
        guard case .cableLimit = diag?.bottleneck else {
            Issue.record("expected .cableLimit when cable is the unique floor, got \(String(describing: diag?.bottleneck))")
            return
        }
    }

    @Test("Explicit hostMaxGbps wins over the inference")
    func explicitHostMaxGbpsWins() {
        // Caller passes 5 Gbps explicitly even though the switch graph
        // would infer 40. The explicit value should be honoured (test seam).
        let host = hostSwitch(socketID: "1", supportedRaw: 0xC, activeSpeed: .usb4Tb4)
        let diag = DataLinkDiagnostic(
            port: makePort(),
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 2)],
            cio: nil,
            thunderboltSwitches: [host],
            hostMaxGbps: 5
        )
        #expect(diag?.facts.hostGbps == 5)
    }

    // MARK: - Hub uplink (issue #245)

    @Test("USB3 hub: headline follows the Mac-to-hub uplink, not a slower deeper link (issue #245)")
    func hubUplinkSpeedNotDeeperLink() {
        // Satechi-hub shape from issue #245: a root 10 Gbps hub is the
        // Mac-to-hub uplink; a secondary 5 Gbps hub sits one hop deeper
        // inside it. The HPM USB3 transport reports the slower Gen 1 (5)
        // link. The verdict must follow the uplink (10), matching the port
        // summary's `usb3Speed` bullet, not the deeper 5 Gbps link. Before
        // this fix the active rate was taken straight from the transport
        // signaling and the headline read "Running at 5 Gbps" while the
        // bullet said 10.
        let rootHub = USBDevice(
            id: 20, locationID: 0x0020_0000,        // one nibble -> root device
            vendorID: 0x1234, productID: 0x0001,
            vendorName: nil, productName: "4-Port USB 3.0 Hub", serialNumber: nil,
            usbVersion: nil, speedRaw: 4,            // SuperSpeed+ 10 Gbps
            busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
        let deeperHub = USBDevice(
            id: 21, locationID: 0x0024_0000,        // two nibbles -> behind the hub
            vendorID: 0x2109, productID: 0x0817,
            vendorName: nil, productName: "USB3.0 Hub", serialNumber: nil,
            usbVersion: nil, speedRaw: 3,            // SuperSpeed 5 Gbps
            busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )

        let diag = DataLinkDiagnostic(
            port: makePort(transportsActive: ["CC", "USB3", "USB2"]),
            identities: [],                          // no e-marker
            devices: [rootHub, deeperHub],
            usb3Transports: [usb3(signaling: 1)],    // controller reports the slow Gen 1 link
            cio: nil
        )

        #expect(diag?.facts.activeGbps == 10)
        #expect(diag?.bottleneck == .fine(activeGbps: 10))
    }

    @Test("USB3 without a resolvable root device still falls back to transport signaling")
    func usb3FallsBackToTransportSignalingWithoutRootDevice() {
        // No clean root-nibble device present (e.g. an Apple Silicon front
        // USB-C port whose internal virtual root inflates the locationID
        // nibbles). rootSuperSpeed is empty, so the controller's USB3
        // signaling remains the active rate, exactly as before this fix.
        // issue #181: TRM-restricted corroborates on its own, without needing
        // a root/portMatched device (which would defeat the "no resolvable
        // root device" premise this test is pinning). The restricted-path
        // Facts still set `activeGbps: active` identically, so this is a
        // corroboration-only change, not a behaviour change for this test.
        let diag = DataLinkDiagnostic(
            port: makePort(transportsActive: ["CC", "USB3", "USB2"]),
            identities: [],
            devices: [device(speedRaw: 4)],          // locationID 0x0100_0000, not a root nibble
            usb3Transports: [usb3(signaling: 2, transportRestricted: true)],    // Gen 2 (10)
            cio: nil
        )

        #expect(diag?.facts.activeGbps == 10)
    }

    // MARK: - TRM blocked-by-security verdict (DAR-134)

    @Test("TRM-restricted USB3 transport yields .blockedBySecurity (DAR-134)")
    func trmRestrictedYieldsBlockedBySecurity() {
        // When TRM_TransportRestricted is true on the USB3 transport the link
        // is physically capable but macOS is withholding data. The old behaviour
        // falsely returned .fine; the fix emits .blockedBySecurity instead.
        let diag = DataLinkDiagnostic(
            port: makePort(transportsActive: ["CC", "USB3"]),
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 1, transportRestricted: true)],  // Gen 1 (5 Gbps), restricted
            cio: nil
        )
        guard case .blockedBySecurity(let signaledGbps) = diag?.bottleneck else {
            Issue.record("Expected .blockedBySecurity, got \(String(describing: diag?.bottleneck))")
            return
        }
        #expect(signaledGbps == 5, "signaledGbps should be 5 from Gen 1 signaling")
        #expect(diag!.isWarning, "blockedBySecurity must be a warning verdict")
        #expect(diag!.summary == "Data blocked by macOS accessory security")
        #expect(diag!.detail.contains("5 Gbps"))
    }

    @Test("TRM-restricted false leaves previous verdict path unchanged")
    func trmRestrictedFalseDoesNotBlock() {
        // transportRestricted=false must not trigger the security verdict.
        // The diagnostic should proceed normally: in this case .unknownCable
        // because no e-marker and no host cap is supplied.
        // issue #181: an unrestricted transport with no device does not
        // corroborate at all, so the correct outcome is now no verdict --
        // still, critically, NOT `.blockedBySecurity` (that's what this
        // test pins: restricted=false must never look blocked).
        let diag = DataLinkDiagnostic(
            port: makePort(transportsActive: ["CC", "USB3"]),
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 2, transportRestricted: false)],
            cio: nil
        )
        if case .blockedBySecurity = diag?.bottleneck {
            Issue.record("transportRestricted=false must not produce .blockedBySecurity")
        }
        #expect(diag == nil, "got: \(String(describing: diag?.bottleneck))")
    }

    @Test("TRM-restricted nil leaves previous verdict path unchanged")
    func trmRestrictedNilDoesNotBlock() {
        // transportRestricted=nil (field absent) must not trigger the security verdict.
        // issue #181: a non-restricted transport with no device does not
        // corroborate at all, so the correct outcome is now no verdict --
        // still, critically, NOT `.blockedBySecurity` (that's what this
        // test pins: restricted=nil must never look blocked).
        let diag = DataLinkDiagnostic(
            port: makePort(transportsActive: ["CC", "USB3"]),
            identities: [],
            devices: [],
            usb3Transports: [usb3(signaling: 2)],    // nil transportRestricted by default
            cio: nil
        )
        if case .blockedBySecurity = diag?.bottleneck {
            Issue.record("transportRestricted=nil must not produce .blockedBySecurity")
        }
        #expect(diag == nil, "got: \(String(describing: diag?.bottleneck))")
    }

    // MARK: - Verdict matrix: unrelated restriction never corroborates
    //
    // Review finding: the existing "corroborated" tunnelled-vs-direct test
    // in USB3SelectorCharacterisationTests always carries a valid restricted
    // DIRECT transport alongside the tunnelled one, so it proves selection
    // excludes tunnelled, not that a restriction on an unrelated entry is
    // correctly ignored. These two cases isolate that: a restriction that
    // exists ONLY on an entry the selector would never pick (wrong port,
    // or tunnelled-only) must produce no verdict at all, not
    // .blockedBySecurity and not a "fine" fallback.

    @Test("A TRM-restricted transport for a DIFFERENT port neither corroborates nor blocks")
    func restrictedTransportForWrongPortNeitherCorroboratesNorBlocks() {
        // Restricted, but portKey "2/99" -- a different physical port. The
        // canonical selector must not match it to port 1, so it can
        // neither supply a speed nor a .blockedBySecurity verdict for THIS
        // port.
        let wrongPortRestricted = USB3Transport(
            id: 60, portKey: "2/99", signaling: 2,
            signalingDescription: "Gen 2", dataRole: "host",
            transportRestricted: true
        )
        let diag = DataLinkDiagnostic(
            port: makePort(transportsActive: ["CC", "USB3"]),
            identities: [],
            devices: [],
            usb3Transports: [wrongPortRestricted],
            cio: nil
        )
        if case .blockedBySecurity = diag?.bottleneck {
            Issue.record("a restriction on a different port's transport must not produce .blockedBySecurity")
        }
        #expect(diag == nil, "got: \(String(describing: diag?.bottleneck))")
    }

    @Test("A TRM-restricted TUNNELLED-ONLY transport neither corroborates nor blocks")
    func restrictedTunnelledOnlyTransportNeitherCorroboratesNorBlocks() {
        // Restricted AND canonically matches this port's portKey, but
        // tunnelled == true and NO direct entry exists alongside it (a
        // dock's own internal plumbing sharing this port's portKey). The
        // selector excludes tunnelled entries unconditionally, so this
        // restriction belongs to the dock, not the physical port, and must
        // not corroborate or block this port's verdict.
        let tunnelledOnlyRestricted = USB3Transport(
            id: 61, portKey: "2/1", signaling: 2,
            signalingDescription: "Gen 2", dataRole: "host",
            transportRestricted: true, tunnelled: true
        )
        let diag = DataLinkDiagnostic(
            port: makePort(transportsActive: ["CC", "USB3"]),
            identities: [],
            devices: [],
            usb3Transports: [tunnelledOnlyRestricted],
            cio: nil
        )
        if case .blockedBySecurity = diag?.bottleneck {
            Issue.record("a restriction on a tunnelled-only transport must not produce .blockedBySecurity")
        }
        #expect(diag == nil, "got: \(String(describing: diag?.bottleneck))")
    }
}
