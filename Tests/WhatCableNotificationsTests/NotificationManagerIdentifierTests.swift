import XCTest
import WhatCableNotifications

/// `NotificationDecision.notificationIdentifier(for:)` decides the
/// identifier a category posts under. Posting with the same identifier
/// replaces the previous notification in Notification Centre instead of
/// stacking a new one, so two events of the same category must produce the
/// same identifier, and different categories must produce different ones
/// (issue #567).
final class NotificationManagerIdentifierTests: XCTestCase {
    func testDeviceCategoryAlwaysReturnsTheSameIdentifier() {
        let first = NotificationDecision.notificationIdentifier(for: .device)
        let second = NotificationDecision.notificationIdentifier(for: .device)
        XCTAssertEqual(first, second, "two device events must share one identifier so the second replaces the first")
    }

    func testChargerCategoryAlwaysReturnsTheSameIdentifier() {
        let first = NotificationDecision.notificationIdentifier(for: .charger)
        let second = NotificationDecision.notificationIdentifier(for: .charger)
        XCTAssertEqual(first, second, "two charger events must share one identifier so the second replaces the first")
    }

    func testDeviceAndChargerIdentifiersAreDistinct() {
        XCTAssertNotEqual(
            NotificationDecision.notificationIdentifier(for: .device),
            NotificationDecision.notificationIdentifier(for: .charger),
            "a charger event must never replace a device event, or vice versa"
        )
    }
}
