import XCTest
@testable import WhatCable

/// The stack-order fix defers the DEVICE post (never flushes the charger
/// reconcile early) when a device settle window fires and a charger settle
/// task is still pending from the same physical event, so the charger post
/// always lands first and the device post stacks on top (macOS puts the
/// newest notification on top). Both `NotificationManager.deviceDiffDisposition`
/// (should this diff wait?) and `shouldLandDeferredDiff` (has it already been
/// landed by the other path?) are pure, unit-tested here without `Task` or
/// `UNUserNotificationCenter`.
final class NotificationManagerStackOrderTests: XCTestCase {
    // MARK: - deviceDiffDisposition

    func testDefersWhenAChargerSettleIsPending() {
        XCTAssertEqual(
            NotificationManager.deviceDiffDisposition(chargerSettlePending: true),
            .deferUntilChargerReconcile,
            "a same-episode charger settle still waiting to fire must hold the device post back"
        )
    }

    func testRunsNowWhenNoChargerSettleIsPending() {
        XCTAssertEqual(
            NotificationManager.deviceDiffDisposition(chargerSettlePending: false),
            .runNow,
            "a device-only event (no charger settle in flight) must post immediately, unchanged"
        )
    }

    // MARK: - shouldLandDeferredDiff (exactly-once landing)

    func testALandingAttemptWithTheLiveTokenMayProceed() {
        XCTAssertTrue(
            NotificationManager.shouldLandDeferredDiff(token: 1, liveToken: 1),
            "the first landing attempt, whichever path reaches it, must be allowed to run the diff"
        )
    }

    func testASecondLandingAttemptForTheSameDeferralIsRejected() {
        // Mirrors landDeferredDeviceDiff's own sequence: the winning path
        // invalidates the live token (increments it) before it runs the
        // diff, so a second attempt still holding the ORIGINAL captured
        // token must see a stale value and back out.
        let capturedToken = 1
        var liveToken = capturedToken
        XCTAssertTrue(NotificationManager.shouldLandDeferredDiff(token: capturedToken, liveToken: liveToken))

        liveToken += 1 // the winning landing path's invalidation

        XCTAssertFalse(
            NotificationManager.shouldLandDeferredDiff(token: capturedToken, liveToken: liveToken),
            "a deferred diff must land exactly once: reconcile-completion and timeout must not both run it"
        )
    }

    func testANewerDeferralInvalidatesAnOlderCapturedToken() {
        // deferDeviceDiff supersedes an earlier still-waiting diff by
        // incrementing the token before storing new devices, the same shape
        // as deviceSettleTask/chargerSettleTask's own "latest wins" rule.
        let staleToken = 1
        let liveTokenAfterASecondDefer = 2
        XCTAssertFalse(
            NotificationManager.shouldLandDeferredDiff(token: staleToken, liveToken: liveTokenAfterASecondDefer),
            "a diff superseded by a newer deferral must not land using the old, now-stale devices"
        )
    }
}
