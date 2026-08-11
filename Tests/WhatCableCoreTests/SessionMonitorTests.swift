import Testing
@testable import WhatCableCore

@Suite("Session monitor (behavioural red bedrock)")
struct SessionMonitorTests {

    private let fp = "2/1#cableA"

    // Build and replay a sequence of observations on one fingerprint.
    private func replay(
        _ deliveries: [SessionMonitor.DataDelivery],
        resistance: [CableResistanceEstimate.Tier?] = [],
        fingerprint: String? = nil
    ) -> SessionMonitor {
        var monitor = SessionMonitor()
        let fingerprint = fingerprint ?? fp
        let count = max(deliveries.count, resistance.count)
        for i in 0..<count {
            let delivery = i < deliveries.count ? deliveries[i] : .notApplicable
            let tier = i < resistance.count ? resistance[i] : nil
            monitor.record(.init(fingerprint: fingerprint, dataDelivery: delivery, resistanceTier: tier))
        }
        return monitor
    }

    // MARK: Performing

    @Test("A fresh monitor performs")
    func freshPerforms() {
        let m = SessionMonitor()
        #expect(m.verdict == .performing)
        #expect(m.observationCount == 0)
    }

    @Test("Steady confirmed delivery performs")
    func steadyConfirmed() {
        let m = replay([.confirmed, .confirmed, .confirmed, .confirmed])
        #expect(m.verdict == .performing)
        #expect(m.observationCount == 4)
    }

    @Test("Host and device limits are never the cable's fault")
    func someoneElsesLimit() {
        // A whole session of notApplicable (host/device cap, no claim) is
        // never red and never even a caution.
        let m = replay([.notApplicable, .notApplicable, .notApplicable, .notApplicable])
        #expect(m.verdict == .performing)
    }

    // MARK: Must NOT convict (the asymmetry)

    @Test("One transient below-claim poll is a caution, not red")
    func singleTransientIsCaution() {
        let m = replay([.confirmed, .belowClaim, .confirmed, .confirmed])
        #expect(m.verdict == .caution)
        #expect(!m.dataNotDelivering)
    }

    @Test("Two consecutive below-claim polls (one short episode) is still caution")
    func shortEpisodeIsCaution() {
        // Below the sustained threshold (3) and only one episode, so a reseat
        // that takes two polls to settle does not convict.
        let m = replay([.belowClaim, .belowClaim, .confirmed])
        #expect(m.verdict == .caution)
        #expect(!m.dataNotDelivering)
    }

    @Test("One stable high-resistance reading is a caution, not red")
    func singleHighResistanceIsCaution() {
        let m = replay([], resistance: [.good, .high, .good])
        #expect(m.verdict == .caution)
        #expect(!m.resistanceOutOfSpec)
    }

    // MARK: Red (corroborated non-delivery)

    @Test("A sustained degradation episode goes red")
    func sustainedDegradationIsRed() {
        // Three consecutive below-claim polls with no recovery: sustained.
        let m = replay([.confirmed, .belowClaim, .belowClaim, .belowClaim])
        #expect(m.verdict == .notPerforming)
        #expect(m.dataNotDelivering)
    }

    @Test("Two separate degradation episodes (flap) go red")
    func repeatedEpisodesAreRed() {
        // drop, recover, drop again: the classic marginal-cable flap.
        let m = replay([.belowClaim, .confirmed, .belowClaim])
        #expect(m.verdict == .notPerforming)
        #expect(m.dataNotDelivering)
    }

    @Test("A notApplicable gap does not split one episode into two")
    func gapDoesNotSplitEpisode() {
        // belowClaim, then a device-limit gap, then belowClaim again, with no
        // confirmed recovery between. That is one ongoing episode of length 2,
        // not two episodes, so it stays a caution.
        let m = replay([.belowClaim, .notApplicable, .belowClaim])
        #expect(m.verdict == .caution)
        #expect(!m.dataNotDelivering)
    }

    @Test("Out-of-spec resistance sustained under load goes red")
    func sustainedHighResistanceIsRed() {
        let m = replay([], resistance: [.high, .high])
        #expect(m.verdict == .notPerforming)
        #expect(m.resistanceOutOfSpec)
    }

    @Test("A good reading between high readings resets the resistance streak")
    func resistanceStreakResets() {
        // high, good, high: never two highs in a row, so not convicted.
        let m = replay([], resistance: [.high, .good, .high])
        #expect(m.verdict == .caution)
        #expect(!m.resistanceOutOfSpec)
    }

    @Test("Marginal resistance never contributes to red")
    func marginalResistanceIsFine() {
        let m = replay([], resistance: [.marginal, .marginal, .marginal])
        #expect(m.verdict == .performing)
    }

    // MARK: Overcurrent

    @Test("An overcurrent trip during the session goes straight to red")
    func overcurrentTripIsRed() {
        var m = SessionMonitor()
        // Baseline count of 4 (lifetime, from before this cable): not an event.
        m.record(.init(fingerprint: fp, dataDelivery: .confirmed, resistanceTier: nil, overcurrentCount: 4))
        #expect(m.verdict == .performing)
        #expect(!m.overcurrentTripped)
        // Count climbs while still connected: a real event on this cable.
        m.record(.init(fingerprint: fp, dataDelivery: .confirmed, resistanceTier: nil, overcurrentCount: 5))
        #expect(m.verdict == .notPerforming)
        #expect(m.overcurrentTripped)
    }

    @Test("A pre-existing overcurrent count is not blamed on the new cable")
    func overcurrentBaselineNotBlamed() {
        // A high lifetime count that never moves is the baseline, not a trip.
        let m = replay([.confirmed, .confirmed, .confirmed])
        var n = m
        for _ in 0..<3 {
            n.record(.init(fingerprint: fp, dataDelivery: .confirmed, resistanceTier: nil, overcurrentCount: 99))
        }
        #expect(!n.overcurrentTripped)
        #expect(n.verdict == .performing)
    }

    @Test("Overcurrent baseline resets when the cable is swapped")
    func overcurrentResetsOnSwap() {
        var m = SessionMonitor()
        m.record(.init(fingerprint: "p#A", dataDelivery: .confirmed, resistanceTier: nil, overcurrentCount: 4))
        m.record(.init(fingerprint: "p#A", dataDelivery: .confirmed, resistanceTier: nil, overcurrentCount: 6))
        #expect(m.verdict == .notPerforming)
        // New cable: its baseline is the current lifetime count (6), so it
        // starts clean even though the lifetime total is non-zero.
        m.record(.init(fingerprint: "p#B", dataDelivery: .confirmed, resistanceTier: nil, overcurrentCount: 6))
        #expect(!m.overcurrentTripped)
        #expect(m.verdict == .performing)
    }

    // MARK: Session identity

    @Test("Swapping cables resets the accumulated evidence")
    func fingerprintChangeResets() {
        var m = SessionMonitor()
        // Cable A racks up a sustained failure.
        for _ in 0..<3 {
            m.record(.init(fingerprint: "2/1#A", dataDelivery: .belowClaim, resistanceTier: nil))
        }
        #expect(m.verdict == .notPerforming)
        // Cable B is plugged in: clean slate, one confirmed poll.
        m.record(.init(fingerprint: "2/1#B", dataDelivery: .confirmed, resistanceTier: nil))
        #expect(m.verdict == .performing)
        #expect(m.observationCount == 1)
    }

    // `resistanceAttributedPortKey` and its tests were removed in the 2026-08 charging-path rework:
    // attribution now happens in `ChargingInputResolver`, covered by
    // `ChargingInputResolverTests`.

    // MARK: Bottleneck mapping

    @Test("Bottleneck mapping matches the trust model")
    func bottleneckMapping() {
        typealias D = SessionMonitor.DataDelivery
        #expect(D.from(.cableLimit(cableGbps: 10, capableGbps: 40), hasCableSpeedClaim: true) == .confirmed)
        #expect(D.from(.fine(activeGbps: 40), hasCableSpeedClaim: true) == .confirmed)
        // .fine with no cable claim has no claim to confirm.
        #expect(D.from(.fine(activeGbps: 40), hasCableSpeedClaim: false) == .notApplicable)
        // The one under-delivery signal.
        #expect(D.from(.degraded(activeGbps: 10, expectedGbps: 40), hasCableSpeedClaim: true) == .belowClaim)
        // Someone else's cap, or unjudgeable, or a contradiction pointer.
        #expect(D.from(.hostLimit(hostGbps: 10, capableGbps: 40), hasCableSpeedClaim: true) == .notApplicable)
        #expect(D.from(.deviceLimit(deviceGbps: 0.48), hasCableSpeedClaim: true) == .notApplicable)
        #expect(D.from(.unknownCable(activeGbps: 10), hasCableSpeedClaim: false) == .notApplicable)
        #expect(D.from(.cableContradictsActive(cableGbps: 10, activeGbps: 40), hasCableSpeedClaim: true) == .notApplicable)
        #expect(D.from(nil, hasCableSpeedClaim: false) == .notApplicable)
    }
}
