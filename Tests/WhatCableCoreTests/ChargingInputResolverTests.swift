import Testing
@testable import WhatCableCore

// Charging-path resistance rework (2026-08): eligibility gates for the charging-path resistance regression.
// Each test names the owner acceptance criterion it pins.

private func source(
    id: UInt64 = 1,
    name: String = "USB-PD",
    portType: Int = 0x2,
    portNumber: Int = 4,
    winningVoltageMV: Int? = 20_000,
    winningCurrentMA: Int = 4_700,
    uuid: String? = "0123456789abcdef0123456789abcdef"
) -> PowerSource {
    let winning = winningVoltageMV.map {
        PowerOption(voltageMV: $0, maxCurrentMA: winningCurrentMA, maxPowerMW: $0 * winningCurrentMA / 1000)
    }
    return PowerSource(
        id: id, name: name, parentPortType: portType, parentPortNumber: portNumber,
        options: winning.map { [$0] } ?? [], winning: winning, hpmControllerUUID: uuid
    )
}

private func resolve(
    _ sources: [PowerSource],
    batteryInstalled: Bool = true,
    externalConnected: Bool = true,
    chargerAttached: Bool = true
) -> ChargingInputResolver.Fingerprint? {
    ChargingInputResolver.fingerprint(
        sources: sources,
        batteryInstalled: batteryInstalled,
        externalConnected: externalConnected,
        chargerAttached: chargerAttached
    )
}

@Suite("ChargingInputResolver")
struct ChargingInputResolverTests {

    @Test("One USB-C fixed-SPR charging input resolves with port and contract identity")
    func happyPath() {
        let fp = resolve([source()])
        #expect(fp != nil)
        #expect(fp?.portKey == "2/4")
        #expect(fp?.contractVoltageMV == 20_000)
        #expect(fp?.contractCurrentMA == 4_700)
        // Canonical join key is the normalised controller UUID when present.
        #expect(fp?.portJoinKey == "0123456789abcdef0123456789abcdef")
    }

    @Test("Laptops only: no battery, no fingerprint")
    func laptopsOnly() {
        #expect(resolve([source()], batteryInstalled: false) == nil)
    }

    @Test("Requires external power on this tick")
    func requiresExternalPower() {
        #expect(resolve([source()], externalConnected: false) == nil)
        #expect(resolve([source()], chargerAttached: false) == nil)
    }

    @Test("MagSafe (port type 0x11) is rejected in phase 1")
    func magSafeRejected() {
        #expect(resolve([source(portType: 0x11, uuid: nil)]) == nil)
    }

    @Test("Exactly one resolved charging input: two contracted ports resolve to nil")
    func twoChargersRejected() {
        let a = source(id: 1, portNumber: 1, uuid: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let b = source(id: 2, portNumber: 2, uuid: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        #expect(resolve([a, b]) == nil)
    }

    @Test("Two source nodes on the SAME port (USB-PD + Brick ID) still resolve")
    func multipleNodesOnePort() {
        let pd = source(id: 1, name: "USB-PD")
        let brick = source(id: 2, name: "Brick ID")
        let fp = resolve([pd, brick])
        #expect(fp != nil)
        #expect(fp?.contractVoltageMV == 20_000, "USB-PD is the preferred representative node")
        #expect(fp?.sourceID == 1, "the representative node's registry ID is the connection identity")
    }

    @Test("Sibling nodes with mixed UUID resolution are one input, not two")
    func mixedUUIDSiblingsAreOneInput() {
        // Same physical port, but only one node's HPM UUID walk succeeded (a
        // registry teardown race can do this). Grouping by canonical key
        // would split them into two groups and wrongly fail the exactly-one
        // gate; grouping by portKey must not.
        let pd = source(id: 1, name: "USB-PD", uuid: "0123456789abcdef0123456789abcdef")
        let brick = source(id: 2, name: "Brick ID", uuid: nil)
        let fp = resolve([pd, brick])
        #expect(fp != nil)
        // And the join key still prefers the UUID-bearing sibling.
        #expect(fp?.portJoinKey == "0123456789abcdef0123456789abcdef")
    }

    @Test("The representative node's UUID walk failing still yields the sibling's UUID join key")
    func joinKeyPrefersUUIDBearingSibling() {
        let pd = source(id: 1, name: "USB-PD", uuid: nil)
        let brick = source(id: 2, name: "Brick ID", uuid: "0123456789abcdef0123456789abcdef")
        let fp = resolve([pd, brick])
        #expect(fp != nil)
        #expect(fp?.sourceID == 1, "USB-PD stays the representative")
        #expect(fp?.portJoinKey == "0123456789abcdef0123456789abcdef")
    }

    @Test("No winning contract anywhere resolves to nil")
    func noContract() {
        #expect(resolve([source(winningVoltageMV: nil)]) == nil)
        #expect(resolve([]) == nil)
    }

    @Test("Fixed SPR tiers only: a PPS-style 17.4 V contract is rejected")
    func nonFixedVoltageRejected() {
        #expect(resolve([source(winningVoltageMV: 17_400)]) == nil)
        // EPR fixed 28 V is also out in phase 1 (owner: SPR only).
        #expect(resolve([source(winningVoltageMV: 28_000)]) == nil)
        // Every standard SPR tier passes.
        for tier in [5_000, 9_000, 12_000, 15_000, 20_000] {
            #expect(resolve([source(winningVoltageMV: tier)]) != nil, "\(tier) mV must resolve")
        }
    }
}
