import XCTest
@testable import WhatCable

/// `reconcileChargers` posted one `UNUserNotificationCenter.add` PER changed
/// port; once charger events shared a single "charger-event" identifier
/// (issue #567), each later post replaced the one before it, so 2+ charger
/// changes in one settle window silently lost all but the last. Mirrors
/// `NotificationManagerAddedContentTests`: `chargerNotificationContents` is
/// the pure merge decision, testable without `UNUserNotificationCenter`.
final class NotificationManagerChargerContentTests: XCTestCase {
    func testTwoAddedChargersMergeIntoOneContentWithBothLines() {
        let contents = NotificationManager.chargerNotificationContents(
            addedLabels: ["30W negotiated", "65W negotiated"],
            removedLabels: []
        )

        XCTAssertEqual(contents, [
            NotificationManager.NotificationContent(
                title: "Charger connected",
                body: "30W negotiated\n65W negotiated"
            )
        ])
    }

    func testOneAddedChargerIsUnchanged() {
        let contents = NotificationManager.chargerNotificationContents(
            addedLabels: ["30W negotiated"],
            removedLabels: []
        )

        XCTAssertEqual(contents, [
            NotificationManager.NotificationContent(title: "Charger connected", body: "30W negotiated")
        ])
    }

    func testMixedAddAndRemoveProducesRemovedContentThenAddedContent() {
        let contents = NotificationManager.chargerNotificationContents(
            addedLabels: ["65W negotiated"],
            removedLabels: ["30W negotiated"]
        )

        XCTAssertEqual(contents, [
            NotificationManager.NotificationContent(title: "Charger disconnected", body: "30W negotiated"),
            NotificationManager.NotificationContent(title: "Charger connected", body: "65W negotiated")
        ])
    }

    func testNoChangesProducesNoContent() {
        let contents = NotificationManager.chargerNotificationContents(addedLabels: [], removedLabels: [])
        XCTAssertEqual(contents, [])
    }

    /// `addedPortKeys` is a `Set` and `removedLabels` used to inherit
    /// Dictionary iteration order, neither of which is stable between runs.
    /// `sortedChargerLabels` is what `reconcileChargers` now calls to turn a
    /// batch of changed port keys into labels, sorted on the stable port key
    /// rather than left to iteration order, so the merged notification's
    /// line order is deterministic.
    func testChargerLabelsAreSortedByPortKeyNotIterationOrder() {
        let labels = [
            "portZ": "65W negotiated",
            "portA": "30W negotiated",
            "portM": "45W negotiated"
        ]
        // Fed in deliberately unsorted order (Set doesn't preserve insertion
        // order, so this exercises the same shape reconcileChargers would
        // otherwise be exposed to).
        let unsortedKeys: Set<String> = ["portZ", "portA", "portM"]

        let sorted = NotificationManager.sortedChargerLabels(for: unsortedKeys, labels: labels)

        XCTAssertEqual(sorted, ["30W negotiated", "45W negotiated", "65W negotiated"])
    }
}
