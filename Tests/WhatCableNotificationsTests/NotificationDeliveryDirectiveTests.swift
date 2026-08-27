import XCTest
import WhatCableNotifications

/// `NotificationDecision.deliveryDirective(for:sequence:previousIdentifier:)`
/// and `NotificationDeliveryLedger` decide what a post's identifier is and
/// what to remove first. This replaces the old fixed-per-category identifier
/// design (`notificationIdentifier(for:)`, removed): posting under a shared
/// "device-event" / "charger-event" identifier relied on macOS's own
/// identifier-replacement semantics to keep one notification standing,
/// which is exactly what the owner's no-banner fault (2026-08-26) pointed
/// at. Every post now gets a fresh, never-reused identifier, and the module
/// tells the shim explicitly what to remove instead.
final class NotificationDeliveryDirectiveTests: XCTestCase {
    // MARK: - Directive uniqueness

    func testTwoConsecutiveDevicePostsGetDistinctIdentifiers() {
        let ledger = NotificationDeliveryLedger(launchToken: "abcd")
        let first = ledger.nextDirective(for: .device)
        let second = ledger.nextDirective(for: .device)
        XCTAssertNotEqual(
            first.identifier, second.identifier,
            "an identifier must never be reused, or macOS treats the second post as replacing the first and no banner fires"
        )
    }

    // MARK: - Removal chain

    func testSecondPostRemovesExactlyTheFirstPostsIdentifierSameCategoryOnly() {
        let ledger = NotificationDeliveryLedger(launchToken: "abcd")
        let firstDevice = ledger.nextDirective(for: .device)
        let secondDevice = ledger.nextDirective(for: .device)
        XCTAssertEqual(
            secondDevice.removeDeliveredIdentifiers, [firstDevice.identifier],
            "post N must remove exactly post N-1's identifier in the same category"
        )

        let firstCharger = ledger.nextDirective(for: .charger)
        XCTAssertEqual(
            firstCharger.removeDeliveredIdentifiers, [],
            "a charger post must never remove a device identifier, even when a device post came immediately before it"
        )
    }

    func testChargerAndDeviceLedgersNeverCrossRemove() {
        let ledger = NotificationDeliveryLedger(launchToken: "abcd")
        let device1 = ledger.nextDirective(for: .device)
        let charger1 = ledger.nextDirective(for: .charger)
        let device2 = ledger.nextDirective(for: .device)
        let charger2 = ledger.nextDirective(for: .charger)

        XCTAssertEqual(device2.removeDeliveredIdentifiers, [device1.identifier])
        XCTAssertEqual(charger2.removeDeliveredIdentifiers, [charger1.identifier])
        XCTAssertNotEqual(device1.identifier, charger1.identifier)
    }

    // MARK: - First post per category

    func testFirstPostPerCategoryRemovesNothing() {
        let ledger = NotificationDeliveryLedger(launchToken: "abcd")
        XCTAssertEqual(ledger.nextDirective(for: .device).removeDeliveredIdentifiers, [])
        XCTAssertEqual(ledger.nextDirective(for: .charger).removeDeliveredIdentifiers, [])
    }

    // MARK: - Per-instance isolation

    func testLedgerSurvivesAcrossCallsButIsPerInstance() {
        let ledger = NotificationDeliveryLedger(launchToken: "abcd")
        _ = ledger.nextDirective(for: .device)
        let third = ledger.nextDirective(for: .device)
        // Third post still chains off the ledger's own running state.
        XCTAssertNotEqual(third.removeDeliveredIdentifiers, [])

        let freshLedger = NotificationDeliveryLedger(launchToken: "abcd")
        let freshFirst = freshLedger.nextDirective(for: .device)
        XCTAssertEqual(
            freshFirst.removeDeliveredIdentifiers, [],
            "a fresh ledger instance must start clean, independent of any other instance's history"
        )
    }

    // MARK: - Cross-launch uniqueness (Codex P1)

    /// Two ledgers built with DIFFERENT launch tokens, each starting fresh,
    /// both post their category's sequence-1 directive. Without the token
    /// folded into the identifier, both would produce the bare
    /// "device-event-1", which is exactly the cross-launch collision Codex
    /// flagged: a relaunch's first post would reuse the previous launch's
    /// still-delivered identifier and silently replace it instead of
    /// banner-ing.
    func testDifferentLaunchTokensNeverCollideOnTheSameCategoryAndSequence() {
        let launchOne = NotificationDeliveryLedger(launchToken: "aaaa")
        let launchTwo = NotificationDeliveryLedger(launchToken: "bbbb")

        let firstDeviceOfLaunchOne = launchOne.nextDirective(for: .device)
        let firstDeviceOfLaunchTwo = launchTwo.nextDirective(for: .device)

        XCTAssertNotEqual(
            firstDeviceOfLaunchOne.identifier, firstDeviceOfLaunchTwo.identifier,
            "the same category and the same sequence number, from two different launches, must never produce the same identifier"
        )
    }
}

/// `NotificationDecision.ownsIdentifier(_:)` decides which delivered
/// identifiers the app-side startup sweep (`NotificationManager.start()`)
/// is allowed to remove: only ones this module posted, in either the old
/// fixed-identifier scheme or the current per-launch one, never a foreign
/// identifier (e.g. `UpdateChecker`'s `"update-<version>"`).
final class OwnsIdentifierTests: XCTestCase {
    func testTrueForLegacyFixedIdentifiers() {
        XCTAssertTrue(NotificationDecision.ownsIdentifier("device-event"))
        XCTAssertTrue(NotificationDecision.ownsIdentifier("charger-event"))
    }

    func testTrueForCurrentSchemeIdentifiers() {
        XCTAssertTrue(NotificationDecision.ownsIdentifier("device-event-abc-7"))
        XCTAssertTrue(NotificationDecision.ownsIdentifier("charger-event-4f2a-1"))
    }

    func testFalseForAForeignIdentifier() {
        XCTAssertFalse(NotificationDecision.ownsIdentifier("update-1.2.3"))
    }

    /// Adversarial: a naive `hasPrefix("device")` (dropping the "-event-"
    /// part of the category's own `rawValue`) would wrongly claim this one,
    /// since it starts with the letters "device" but is not this module's
    /// identifier shape at all. `ownsIdentifier` must match on the full
    /// category `rawValue` plus a trailing dash, not a bare word fragment.
    func testFalseForAnArbitraryStringThatMerelyStartsWithACategoryWord() {
        XCTAssertFalse(NotificationDecision.ownsIdentifier("deviceXYZ"))
        XCTAssertFalse(NotificationDecision.ownsIdentifier("chargerXYZ"))
    }

    func testFalseForAnEmptyOrCompletelyUnrelatedString() {
        XCTAssertFalse(NotificationDecision.ownsIdentifier(""))
        XCTAssertFalse(NotificationDecision.ownsIdentifier("some-random-string"))
    }

    /// Boundary case (adversarial P4): the bare legacy identifier, exactly
    /// `"<category rawValue>-"` with nothing after the trailing dash, is
    /// unreachable in production (a real posted identifier always has a
    /// token and sequence number after that dash, and the pre-launch-token
    /// legacy shape had no trailing dash at all). This just pins the
    /// prefix rule's actual behaviour on that shape: `hasPrefix` matches it,
    /// so it counts as owned.
    func testTrueForBareCategoryPrefixWithTrailingDashAndNothingAfter() {
        XCTAssertTrue(NotificationDecision.ownsIdentifier("device-event-"))
    }
}

/// `NotificationDecision.sweepShouldRemove(_:currentLaunchToken:)` is the
/// startup sweep's actual removal guard (final gate finding, sweep race):
/// owned by ownsIdentifier's rules AND not carrying the CURRENT launch's own
/// token, because `getDeliveredNotifications`'s completion has no bounded
/// latency and can land after this launch's own first post, under login
/// contention.
final class SweepShouldRemoveTests: XCTestCase {
    func testRemovesOwnedIdentifiersFromEarlierLaunchesButNeverTheCurrentLaunchsOwn() {
        let identifiers = ["device-event", "device-event-OLDTOKEN-3", "device-event-CURRENT-1", "foreign"]
        let toRemove = identifiers.filter {
            NotificationDecision.sweepShouldRemove($0, currentLaunchToken: "CURRENT")
        }
        XCTAssertEqual(
            toRemove, ["device-event", "device-event-OLDTOKEN-3"],
            "the sweep must remove exactly the legacy and earlier-launch identifiers, never the current launch's own, and never a foreign one"
        )
    }

    /// Cross-category symmetry: the exclusion isn't special-cased to
    /// `.device`, it applies identically to a charger identifier.
    func testChargerIdentifierWithTheCurrentTokenAlsoSurvives() {
        XCTAssertFalse(
            NotificationDecision.sweepShouldRemove("charger-event-CURRENT-1", currentLaunchToken: "CURRENT"),
            "a charger identifier carrying the current launch's token must survive the sweep exactly like a device one does"
        )
    }
}
