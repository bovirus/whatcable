import Foundation

/// One immutable, pre-joined view of a CableSnapshot: the per-port filtering,
/// charger-source resolution, cross-port charging state, and device
/// attribution that every renderer needs before it can construct
/// PortSummary / ChargingDiagnostic / DataLinkDiagnostic correctly.
///
/// JSONFormatter, TextFormatter, and DashboardCommand each carry a private
/// copy of this assembly today; a follow-up migrates them onto this builder.
/// Until then this type must stay behaviourally identical to those copies.
///
/// Guarantees:
/// - `portContexts` preserves `snapshot.ports` order, one entry per port.
/// - Every filtered array preserves the input array's order.
/// - `portCIO` is the FIRST canonical match (mirrors all three copies).
/// - `attributedDevices` is the ID-deduplicated union of `matchedDevices`
///   then `structurallyScopedTunnelledDevices`, first occurrence wins, which
///   is exactly `TunnelledDeviceGrouping.attributedDevices(for:in:thunderboltSwitches:)`.
///
/// Deliberately NOT here (formatter concerns, or policy settled by the follow-up migration):
/// showRaw, switch index maps, dashboard sort order, DTOs, unmatched-USB
/// grouping (`TunnelledDeviceGrouping.group`), and any e-marker selection
/// policy: this exposes `portIdentities` unfiltered by endpoint.
///
/// Not Sendable: CableSnapshot itself is not Sendable yet. No @MainActor.
public struct CableSnapshotContext {
    public struct PortContext {
        public let port: AppleHPMInterface
        /// Power sources canonically matched to this port, input order kept.
        public let portSources: [PowerSource]
        /// PD identities (SOP / SOP' / SOP'') canonically matched to this
        /// port. No endpoint selection policy is applied here.
        public let portIdentities: [USBPDSOP]
        public let portUSB3: [USB3Transport]
        public let portTRM: [TRMTransport]
        /// First canonical CIO match, mirroring the formatters.
        public let portCIO: CIOCableCapability?
        public let portDisplayPorts: [IOPortTransportStateDisplayPort]
        /// Native-bus matches (`AppleHPMInterface.matchingDevices`). Feeds
        /// PortSummary / DataLinkDiagnostic, whose speed corroboration is
        /// native-bus-local by design.
        public let matchedDevices: [USBDevice]
        /// Tunnelled devices structurally scoped to this port by apciecN
        /// root name.
        public let structurallyScopedTunnelledDevices: [USBDevice]
        /// ID-deduplicated union, matched-first ordering. Feeds device lists.
        public let attributedDevices: [USBDevice]
        public let chargerWattageSource: ChargerWattageSource
        /// True when a DIFFERENT port holds a live charging contract (#264).
        public let anotherPortActivelyCharging: Bool
    }

    public let adapter: AdapterInfo?
    public let batteryFullyCharged: Bool?
    public let batteryIsCharging: Bool?
    public let federatedIdentities: [FederatedIdentity]
    public let thunderboltSwitches: [IOThunderboltSwitch]
    public let isDesktopMac: Bool
    /// One entry per `snapshot.ports` element, same order.
    public let portContexts: [PortContext]

    public init(snapshot: CableSnapshot) {
        let ports = snapshot.ports
        let sources = snapshot.powerSources
        // Machine-wide intermediates. Kept private on purpose: consumers get
        // the resolved per-port answers, not the raw counts.
        let activePortCount = ports.filter { $0.connectionActive == true }.count
        let chargerSourceCount = ChargerWattageSource.chargerSourceCount(
            ports: ports, sources: sources)
        // Port keys with a live negotiated contract (#264). Deliberately
        // ungated on adapter/battery: this only feeds
        // anotherPortActivelyCharging, and ChargingDiagnostic applies the
        // system-power gate before acting on it.
        let chargingPortKeys = Set(ports.compactMap { port -> String? in
            let portSources = sources.filter { $0.canonicallyMatches(port: port) }
            return PowerSource.hasLiveChargingContract(in: portSources) ? port.portKey : nil
        })
        self.portContexts = ports.map { port in
            let portSources = sources.filter { $0.canonicallyMatches(port: port) }
            let matched = port.matchingDevices(from: snapshot.usbDevices)
            let scoped = TunnelledDeviceGrouping.structurallyScopedTunnelledDevices(
                for: port, in: snapshot.usbDevices,
                thunderboltSwitches: snapshot.thunderboltSwitches)
            var seen = Set<UInt64>()
            var union: [USBDevice] = []
            for device in matched + scoped where seen.insert(device.id).inserted {
                union.append(device)
            }
            return PortContext(
                port: port,
                portSources: portSources,
                portIdentities: snapshot.identities.filter { $0.canonicallyMatches(port: port) },
                portUSB3: snapshot.usb3Transports.filter { $0.canonicallyMatches(port: port) },
                portTRM: snapshot.trmTransports.filter { $0.canonicallyMatches(port: port) },
                portCIO: snapshot.cioCapabilities.first { $0.canonicallyMatches(port: port) },
                portDisplayPorts: snapshot.displayPorts.filter { $0.canonicallyMatches(port: port) },
                matchedDevices: matched,
                structurallyScopedTunnelledDevices: scoped,
                attributedDevices: union,
                chargerWattageSource: ChargerWattageSource.resolve(
                    portSources: portSources,
                    activePortCount: activePortCount,
                    chargerSourceCount: chargerSourceCount,
                    adapter: snapshot.adapter),
                anotherPortActivelyCharging: port.portKey.map { key in
                    chargingPortKeys.contains { $0 != key }
                } ?? false
            )
        }
        self.adapter = snapshot.adapter
        self.batteryFullyCharged = snapshot.batteryFullyCharged
        self.batteryIsCharging = snapshot.batteryIsCharging
        self.federatedIdentities = snapshot.federatedIdentities
        self.thunderboltSwitches = snapshot.thunderboltSwitches
        self.isDesktopMac = snapshot.isDesktopMac
    }
}
