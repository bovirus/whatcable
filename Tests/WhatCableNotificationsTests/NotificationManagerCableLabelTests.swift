import XCTest
import WhatCableCore
import WhatCableNotifications

/// Issue #570 part B: when a settled device notification's window coincides
/// with exactly ONE saved (labelled) cable appearing or disappearing, the
/// title carries that cable's saved name. Mirrors
/// `NotificationManagerThunderboltInvolvedTests`'s shape: the pure rule
/// (`NotificationDecision.cableLabelChange`) first, then the content-decision
/// wiring that appends the label suffix. `DeviceDiffSequencerTests` covers
/// the third half: the sequencer actually deriving the label from a live
/// labelled-cables closure and threading it through to
/// `deviceNotificationContents`, including the settle-time snapshot rule.
final class NotificationManagerCableLabelTests: XCTestCase {
    // MARK: - Pure rule: NotificationDecision.cableLabelChange(previous:current:)

    /// A labelled cable appearing (baseline empty, current has one) reports
    /// that cable's name, added.
    ///
    /// Red-proof: hardcode the function to always return `nil`; this goes
    /// red (expects a non-nil result).
    func testCableAppearingReportsItsNameAsAdded() {
        let result = NotificationDecision.cableLabelChange(previous: [:], current: ["cable-1": "Office cable"])
        XCTAssertEqual(result?.name, "Office cable")
        XCTAssertEqual(result?.wasAdded, true)
    }

    /// A labelled cable disappearing (baseline has one, current empty)
    /// reports that cable's name, removed. Its name has to come from the
    /// PREVIOUS map, since it's absent from current by definition.
    ///
    /// Red-proof: swap `current[id]` for `previous[id]` unconditionally (so
    /// the removed case reads a missing key and falls through to nil); this
    /// goes red (expects "Office cable", gets nil).
    func testCableDisappearingReportsItsNameAsRemoved() {
        let result = NotificationDecision.cableLabelChange(previous: ["cable-1": "Office cable"], current: [:])
        XCTAssertEqual(result?.name, "Office cable")
        XCTAssertEqual(result?.wasAdded, false)
    }

    /// No change to the labelled set (same single id, or both empty) is nil.
    ///
    /// Red-proof: hardcode the function to always synthesise a result from
    /// whichever map is non-empty; this goes red (expects nil, gets a
    /// non-nil result for the non-empty-both case).
    func testNoKeySetChangeIsNil() {
        XCTAssertNil(NotificationDecision.cableLabelChange(previous: ["cable-1": "Office cable"], current: ["cable-1": "Office cable"]))
        XCTAssertNil(NotificationDecision.cableLabelChange(previous: [:], current: [:]))
    }

    /// Two changed ids in the same window (one appears, a different one
    /// disappears, or two both appear) is ambiguous: nil, not a guess.
    ///
    /// Red-proof: change the `changedIDs.count == 1` guard to `>= 1`; this
    /// goes red (expects nil, gets a result for the two-id case).
    func testTwoChangedCablesIsAmbiguousAndNil() {
        XCTAssertNil(NotificationDecision.cableLabelChange(
            previous: ["cable-1": "Office cable"],
            current: ["cable-2": "Studio cable"]
        ))
        XCTAssertNil(NotificationDecision.cableLabelChange(
            previous: [:],
            current: ["cable-1": "Office cable", "cable-2": "Studio cable"]
        ))
    }

    /// Same-id-relabelled: the saved cable stays connected (key unchanged)
    /// but its NAME changes (the user renamed it in Saved Cables mid-session).
    /// The key set is unchanged, so this must read as nil, not as a label
    /// change: nothing about the connection itself changed.
    ///
    /// Red-proof: compare the dictionaries' VALUES instead of just their key
    /// sets; this goes red (expects nil, gets a result because the values
    /// differ).
    func testSameIDRelabelledIsNil() {
        XCTAssertNil(NotificationDecision.cableLabelChange(
            previous: ["cable-1": "Office cable"],
            current: ["cable-1": "Renamed cable"]
        ))
    }

    /// Edge case from the spec: one saved record, two identical physical
    /// cables. Attribution matches by e-marker fingerprint, so BOTH physical
    /// cables report the SAME cableID. Unplugging the first and plugging in
    /// the second within one settle window never changes the key set (the
    /// id is present throughout), so this must be nil: accepted, not a bug.
    ///
    /// Red-proof: same as `testNoKeySetChangeIsNil`'s mutation; this test
    /// exists separately because it documents the SPECIFIC scenario the
    /// spec calls out by name, not just the general "no change" case.
    func testSamePhysicalCableIDSwapWithinWindowIsNil() {
        XCTAssertNil(NotificationDecision.cableLabelChange(
            previous: ["cable-1": "Office cable"],
            current: ["cable-1": "Office cable"]
        ))
    }

    // MARK: - Content: the label suffix appears on single-device, merged,
    // and reconnect titles; nil label keeps today's wording byte-identical.

    private func snapshot(id: UInt64, locationID: UInt32, name: String) -> USBDeviceChangeGrouper.Snapshot {
        USBDeviceChangeGrouper.Snapshot(id: id, locationID: locationID, name: name)
    }

    /// A single added group with a non-nil `cableLabel` gets the suffix.
    ///
    /// Red-proof: hardcode `cableLabel` to nil at the `applyCableLabel` call
    /// site in `addedNotificationContents`'s single-group branch; this goes
    /// red (expects "Connected: SSD Enclosure (Office cable)", gets the
    /// unlabelled title).
    func testSingleGroupAddedTitleGetsCableLabelSuffix() {
        let current = [snapshot(id: 7, locationID: 0x01100000, name: "SSD Enclosure")]
        let (added, _) = USBDeviceChangeGrouper.diff(previous: [], current: current)

        let contents = NotificationDecision.addedNotificationContents(groups: added, cableLabel: "Office cable") { _ in nil }

        XCTAssertEqual(contents.first?.title, "Connected: SSD Enclosure (Office cable)")
    }

    /// A single removed group with a non-nil `cableLabel` gets the suffix.
    ///
    /// Red-proof: same hardcode-to-nil mutation in
    /// `removedNotificationContents`'s single-group branch; this goes red
    /// (expects "Disconnected: SSD Enclosure (Office cable)").
    func testSingleGroupRemovedTitleGetsCableLabelSuffix() {
        let previous = [snapshot(id: 7, locationID: 0x01100000, name: "SSD Enclosure")]
        let (_, removed) = USBDeviceChangeGrouper.diff(previous: previous, current: [])

        let contents = NotificationDecision.removedNotificationContents(groups: removed, cableLabel: "Office cable")

        XCTAssertEqual(contents.first?.title, "Disconnected: SSD Enclosure (Office cable)")
    }

    /// A MERGED (>1 group) added title also gets the suffix: the spec is
    /// explicit that both single-device and merged titles carry the label.
    ///
    /// Red-proof: gate `applyCableLabel` behind `groups.count == 1` in
    /// `addedNotificationContents` (apply only to the single-group branch);
    /// this goes red (expects "USB devices connected (Office cable)", gets
    /// the unlabelled merged title).
    func testMergedAddedTitleGetsCableLabelSuffix() {
        let current = [
            snapshot(id: 1, locationID: 0x01100000, name: "USB3 Hub"),
            snapshot(id: 3, locationID: 0x01200000, name: "USB2 Hub")
        ]
        let (added, _) = USBDeviceChangeGrouper.diff(previous: [], current: current)
        XCTAssertEqual(added.count, 2, "fixture should produce 2 groups; test is invalid otherwise")

        let contents = NotificationDecision.addedNotificationContents(groups: added, cableLabel: "Office cable") { _ in nil }

        XCTAssertEqual(contents.first?.title, "USB devices connected (Office cable)")
    }

    /// A MERGED removed title also gets the suffix.
    ///
    /// Red-proof: same gating mutation on the removed side; this goes red
    /// (expects "USB devices disconnected (Office cable)").
    func testMergedRemovedTitleGetsCableLabelSuffix() {
        let previous = [
            snapshot(id: 1, locationID: 0x01100000, name: "USB3 Hub"),
            snapshot(id: 3, locationID: 0x01200000, name: "USB2 Hub")
        ]
        let (_, removed) = USBDeviceChangeGrouper.diff(previous: previous, current: [])
        XCTAssertEqual(removed.count, 2, "fixture should produce 2 groups; test is invalid otherwise")

        let contents = NotificationDecision.removedNotificationContents(groups: removed, cableLabel: "Office cable")

        XCTAssertEqual(contents.first?.title, "USB devices disconnected (Office cable)")
    }

    /// The reconnect gate (one removed, one added, same port and name) ALSO
    /// gets the suffix: unlike `thunderboltInvolved`, which deliberately
    /// never touches the reconnect title, a labelled cable reconnecting is
    /// the spec's own "strongest use case", so `deviceNotificationContents`
    /// threads `addedCableLabel` into the reconnect path.
    ///
    /// Red-proof: drop the `cableLabel:` argument at the
    /// `reconnectedNotificationContent` call site inside
    /// `deviceNotificationContents`; this goes red (expects "Reconnected:
    /// SSD Enclosure (Office cable)", gets the unlabelled title).
    func testReconnectTitleGetsCableLabelSuffix() {
        let (_, removed) = USBDeviceChangeGrouper.diff(
            previous: [snapshot(id: 1, locationID: 0x01100000, name: "SSD Enclosure")],
            current: []
        )
        let (added, _) = USBDeviceChangeGrouper.diff(
            previous: [],
            current: [snapshot(id: 2, locationID: 0x01100000, name: "SSD Enclosure")]
        )

        let contents = NotificationDecision.deviceNotificationContents(
            removedGroups: removed,
            addedGroups: added,
            addedCableLabel: "Office cable"
        ) { _ in nil }

        XCTAssertEqual(contents, [
            NotificationContent(title: "Reconnected: SSD Enclosure (Office cable)", body: "")
        ])
    }

    /// `deviceNotificationContents` only ever passes ONE of
    /// `addedCableLabel` / `removedCableLabel` as non-nil at a real call
    /// site (direction-aware), so a genuine remove+add pair that ISN'T a
    /// reconnect (different port) must label only the side that matches the
    /// direction the cable actually changed.
    ///
    /// Red-proof: swap which content function receives which label
    /// (`removedCableLabel` into `addedNotificationContents`, and vice
    /// versa) inside `deviceNotificationContents`; this goes red (the added
    /// title would come back unlabelled and the removed title labelled,
    /// opposite of what's asserted).
    func testDirectionAwareLabelOnlyAppliesToTheMatchingSide() {
        let (_, removed) = USBDeviceChangeGrouper.diff(
            previous: [snapshot(id: 1, locationID: 0x01100000, name: "SSD Enclosure A")],
            current: []
        )
        let (added, _) = USBDeviceChangeGrouper.diff(
            previous: [],
            current: [snapshot(id: 2, locationID: 0x02100000, name: "SSD Enclosure B")]
        )
        // Different ports and different names: NOT a reconnect pair, so the
        // removed-then-added composition runs, not the reconnect gate.

        let contents = NotificationDecision.deviceNotificationContents(
            removedGroups: removed,
            addedGroups: added,
            addedCableLabel: "Office cable",
            removedCableLabel: nil
        ) { _ in nil }

        XCTAssertEqual(contents.count, 2)
        XCTAssertEqual(contents[0].title, "Disconnected: SSD Enclosure A", "the removed side got no label, so its title stays unlabelled")
        XCTAssertEqual(contents[1].title, "Connected: SSD Enclosure B (Office cable)", "the added side got the label")
    }

    /// `cableLabel: nil` (the default, every existing call site) must
    /// produce a BYTE-IDENTICAL title to today's wording, across all three
    /// content functions and the merged path, so a caller that never passes
    /// a label (every call site before this feature) sees no change at all.
    ///
    /// Red-proof: hardcode a label unconditionally in `applyCableLabel`
    /// (ignore the `nil` guard); this goes red on every assertion below
    /// (each title would gain an unwanted "(...)" suffix).
    func testNilLabelKeepsTodaysTitlesByteIdentical() {
        let singleAdded = USBDeviceChangeGrouper.diff(
            previous: [],
            current: [snapshot(id: 7, locationID: 0x01100000, name: "SSD Enclosure")]
        ).added
        XCTAssertEqual(
            NotificationDecision.addedNotificationContents(groups: singleAdded) { _ in nil }.first?.title,
            "Connected: SSD Enclosure"
        )

        let singleRemoved = USBDeviceChangeGrouper.diff(
            previous: [snapshot(id: 7, locationID: 0x01100000, name: "SSD Enclosure")],
            current: []
        ).removed
        XCTAssertEqual(
            NotificationDecision.removedNotificationContents(groups: singleRemoved).first?.title,
            "Disconnected: SSD Enclosure"
        )

        let mergedAdded = USBDeviceChangeGrouper.diff(
            previous: [],
            current: [
                snapshot(id: 1, locationID: 0x01100000, name: "USB3 Hub"),
                snapshot(id: 3, locationID: 0x01200000, name: "USB2 Hub")
            ]
        ).added
        XCTAssertEqual(
            NotificationDecision.addedNotificationContents(groups: mergedAdded) { _ in nil }.first?.title,
            "USB devices connected"
        )

        let reconnectAdded = USBDeviceChangeGrouper.diff(
            previous: [],
            current: [snapshot(id: 2, locationID: 0x01100000, name: "SSD Enclosure")]
        ).added
        let reconnectRemoved = USBDeviceChangeGrouper.diff(
            previous: [snapshot(id: 1, locationID: 0x01100000, name: "SSD Enclosure")],
            current: []
        ).removed
        XCTAssertEqual(
            NotificationDecision.deviceNotificationContents(removedGroups: reconnectRemoved, addedGroups: reconnectAdded) { _ in nil },
            [NotificationContent(title: "Reconnected: SSD Enclosure", body: "")]
        )
    }
}
