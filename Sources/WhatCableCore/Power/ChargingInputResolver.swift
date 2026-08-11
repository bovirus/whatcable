import Foundation

/// Decides whether this tick's power state is eligible for the charging-path
/// resistance regression, and if so, which port and contract the estimate
/// belongs to (charging-path resistance rework, 2026-08).
///
/// The regression measures the DC-in slope (SMC `VD0R` vs `ID0R`), which is a
/// machine-wide reading, so it is only attributable when exactly one charging
/// input is resolved and stable. Every gate here is an owner-set acceptance
/// criterion; loosening one is a spec change, not a cleanup:
///
/// - laptops only (a desktop's DC-in is its internal PSU, not a cable);
/// - charger attached and externally connected;
/// - exactly one port holding a winning contract (two chargers split the
///   DC-in reading between cables, so neither slope means anything);
/// - USB-C only, MagSafe rejected in phase 1;
/// - fixed-voltage SPR contract only. PPS / AVS sources move their own
///   output voltage, which the single-ended slope cannot distinguish from
///   cable drop. Membership in the fixed SPR tier set is the phase-1 proxy
///   for "fixed contract": a PPS source holding a non-standard voltage fails
///   it, and one holding exactly a standard tier that later moves is caught
///   by the fingerprint reset and the R-squared gate.
///
/// Pure logic, no platform imports: unit-tested directly in Core tests.
public enum ChargingInputResolver {

    /// Identity of the charging path a regression sample belongs to. Any
    /// change (port, connection, renegotiated contract) invalidates every
    /// previously collected sample, so the accumulator resets when this
    /// value changes.
    public struct Fingerprint: Equatable, Sendable {
        /// Canonical join key of the charging port (HPM controller UUID when
        /// present, else "type/number"). Internal only, never serialised.
        public let portJoinKey: String
        /// Display key ("type/number") for attribution in the UI and JSON.
        public let portKey: String
        /// IOKit registry entry ID of the representative power-source node.
        /// This is the CONNECTION identity: a replug (which is how a cable
        /// swap happens physically) tears the node down and recreates it with
        /// a new ID, so two cables negotiating the identical contract on the
        /// same port still get distinct fingerprints. Review finding on the
        /// first cut, which carried port + contract only and would have
        /// spliced them.
        public let sourceID: UInt64
        public let contractVoltageMV: Int
        public let contractCurrentMA: Int

        public init(
            portJoinKey: String,
            portKey: String,
            sourceID: UInt64,
            contractVoltageMV: Int,
            contractCurrentMA: Int
        ) {
            self.portJoinKey = portJoinKey
            self.portKey = portKey
            self.sourceID = sourceID
            self.contractVoltageMV = contractVoltageMV
            self.contractCurrentMA = contractCurrentMA
        }
    }

    /// `IOPortFeaturePowerSource.ParentPortType` for USB-C. MagSafe 3 is 0x11.
    static let usbCPortType = 0x2

    /// The fixed SPR PDO voltage tiers (USB-PD r3.x table 6-9): the only
    /// contracts phase 1 accepts. EPR fixed tiers (28/36/48 V) are excluded
    /// on the owner's "SPR only" criterion, not for a physics reason.
    static let fixedSPRVoltagesMV: Set<Int> = [5000, 9000, 12000, 15000, 20000]

    /// Resolve this tick's charging input, or nil when any gate fails.
    ///
    /// - Parameters:
    ///   - sources: every power source read this tick (real and synthesized).
    ///   - batteryInstalled: laptop check.
    ///   - externalConnected: `AppleSmartBattery.ExternalConnected`.
    ///   - chargerAttached: live system adapter presence.
    public static func fingerprint(
        sources: [PowerSource],
        batteryInstalled: Bool,
        externalConnected: Bool,
        chargerAttached: Bool
    ) -> Fingerprint? {
        guard batteryInstalled, externalConnected, chargerAttached else { return nil }

        // Ports holding a winning (negotiated) contract, grouped by port so a
        // port publishing several source nodes ("USB-PD" + "Brick ID") counts
        // once. Grouped by `portKey` (type/number), NOT `canonicalJoinKey`:
        // sibling nodes on one physical port each walk the registry for their
        // own HPM UUID, and if one walk fails while the other succeeds their
        // canonical keys differ, which would split one real charging input
        // into two groups and wrongly fail the exactly-one gate (review
        // finding, reproduced in `ChargingInputResolverTests`). `portKey` is
        // identical for siblings by construction.
        let byPort = Dictionary(grouping: sources.filter { ($0.winning?.maxPowerMW ?? 0) > 0 }) {
            $0.portKey
        }
        // Exactly one resolved charging input. Zero means nothing to
        // attribute; two or more means the DC-in rail blends both cables.
        guard byPort.count == 1,
              let portSources = byPort.values.first,
              let source = PowerSource.preferredChargingSource(in: portSources),
              let winning = source.winning else { return nil }

        // USB-C only; MagSafe (0x11) waits for phase 2.
        guard source.parentPortType == usbCPortType else { return nil }

        // Fixed SPR tiers only.
        guard fixedSPRVoltagesMV.contains(winning.voltageMV) else { return nil }

        // Prefer a UUID-bearing sibling's join key: the representative node
        // may be the one whose UUID walk failed while a sibling's succeeded.
        let joinKey = portSources.first { $0.hpmControllerUUID != nil }?.canonicalJoinKey
            ?? source.canonicalJoinKey
        return Fingerprint(
            portJoinKey: joinKey,
            portKey: source.portKey,
            sourceID: source.id,
            contractVoltageMV: winning.voltageMV,
            contractCurrentMA: winning.maxCurrentMA
        )
    }
}
