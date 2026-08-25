import XCTest
import WhatCableCore
@testable import WhatCable

/// Drives the ACTUAL call sites of the stack-order fix (`deferDeviceDiff`
/// and `reconcileChargers`'s `defer`), not just the pure rules they read.
///
/// This gap is not theoretical: adversarial review deleted the single
/// `defer { landDeferredDeviceDiff(...) }` line in `reconcileChargers` (all
/// the wiring the fix depends on) and every existing `NotificationManager`
/// test, including the pure `deviceDiffDisposition` / `shouldLandDeferredDiff`
/// tests in `NotificationManagerStackOrderTests`, stayed green. Those tests
/// pin the two decisions correctly; neither one calls the code that actually
/// connects a finished charger reconcile to a parked device diff. This file
/// exercises that connection directly, via `NotificationManager.shared`'s own
/// `notificationSink` seam (mirrors `UpdateChecker.notificationSink`, see its
/// doc comment) instead of `UNUserNotificationCenter`, which crashes under
/// the `swift test` runner (no signed app bundle).
final class NotificationManagerStackOrderWiringTests: XCTestCase {
    /// Minimal single-device fixture. Only `id`/`productName` matter here:
    /// `diffDevices` groups by these via `USBDeviceChangeGrouper`, and an
    /// empty `knownDevices` baseline means this one device is a clean "added"
    /// group, producing exactly one "Connected: <name>" content.
    private func fakeDevice(id: UInt64) -> USBDevice {
        USBDevice(
            id: id, locationID: 0x01_00_00_00, vendorID: 0, productID: 0,
            vendorName: nil, productName: "Test Hub", serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
    }

    /// Live verification found that landing the parked diff SYNCHRONOUSLY put
    /// both posts in the same millisecond, and macOS presents only the LAST
    /// of two simultaneous banners: "Charger disconnected" reached
    /// Notification Centre but never showed on screen. So when
    /// `reconcileChargers` actually posted charger content, the parked
    /// device diff must wait out a deliberate presentation gap
    /// (`deferredDeviceDiffPresentationGapWindow`, shrunk here to 30ms)
    /// before landing, not land in the same call.
    @MainActor
    func testReconcileChargersLandsAParkedDeviceDiffAfterAPresentationGapWhenItPostedChargerContent() async {
        let manager = NotificationManager.shared
        let settings = AppSettings.shared

        let originalSink = manager.notificationSink
        let originalDidPrimeBaseline = manager.didPrimeBaseline
        let originalKnownDevices = manager.knownDevices
        let originalKnownChargerLabels = manager.knownChargerLabels
        let originalGapWindow = manager.deferredDeviceDiffPresentationGapWindow
        let originalNotifyOnChanges = settings.notifyOnChanges
        let originalRequester = settings.requestNotificationAuthorization
        // Flipping notifyOnChanges on requests OS permission, which crashes
        // under the swift test runner (no signed app bundle). Same guard the
        // BetaUpdateChannelTests use around UpdateChecker.
        settings.requestNotificationAuthorization = {}
        defer {
            manager.notificationSink = originalSink
            manager.didPrimeBaseline = originalDidPrimeBaseline
            manager.knownDevices = originalKnownDevices
            manager.knownChargerLabels = originalKnownChargerLabels
            manager.deferredDeviceDiffPresentationGapWindow = originalGapWindow
            settings.notifyOnChanges = originalNotifyOnChanges
            settings.requestNotificationAuthorization = originalRequester
        }

        settings.notifyOnChanges = true
        manager.deferredDeviceDiffPresentationGapWindow = .milliseconds(30)
        manager.didPrimeBaseline = true
        manager.knownDevices = [:]
        // The live WatcherHub.shared.powerWatcher.sources this test process
        // sees is empty (no watchers ever started), so reconcileChargers's
        // "current" set is empty. Seeding a baseline charger here means it
        // reads as a removal, giving reconcileChargers real content to post
        // ("Charger disconnected"), not just a landing with nothing before it.
        manager.knownChargerLabels = ["fake-port-1": "30W negotiated"]

        var posted: [(NotificationManager.NotificationCategory, NotificationManager.NotificationContent)] = []
        manager.notificationSink = { category, content in posted.append((category, content)) }

        // Park a device diff exactly as scheduleDeviceDiff would on
        // .deferUntilChargerReconcile, without its own 1.5s Task.sleep or a
        // live WatcherHub.shared.deviceWatcher.devices read.
        manager.deferDeviceDiff([fakeDevice(id: 901)])

        manager.reconcileChargers()

        XCTAssertEqual(
            posted.map(\.0),
            [.charger],
            "the device post must not land in the same call as the charger post it needs to stack on top of"
        )

        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(
            posted.map(\.0),
            [.charger, .device],
            "after the presentation gap, the parked device diff must land, still after the charger post"
        )
        XCTAssertEqual(posted.last?.1.title, "Connected: Test Hub")
    }

    /// When `reconcileChargers` posts nothing (no charger change in this
    /// settle), there is no simultaneous-banner problem to avoid, so the
    /// parked diff must still land synchronously, exactly as before the
    /// presentation-gap fix.
    @MainActor
    func testReconcileChargersLandsAParkedDeviceDiffSynchronouslyWhenItPostedNothing() {
        let manager = NotificationManager.shared
        let settings = AppSettings.shared

        let originalSink = manager.notificationSink
        let originalDidPrimeBaseline = manager.didPrimeBaseline
        let originalKnownDevices = manager.knownDevices
        let originalKnownChargerLabels = manager.knownChargerLabels
        let originalNotifyOnChanges = settings.notifyOnChanges
        let originalRequester = settings.requestNotificationAuthorization
        settings.requestNotificationAuthorization = {}
        defer {
            manager.notificationSink = originalSink
            manager.didPrimeBaseline = originalDidPrimeBaseline
            manager.knownDevices = originalKnownDevices
            manager.knownChargerLabels = originalKnownChargerLabels
            settings.notifyOnChanges = originalNotifyOnChanges
            settings.requestNotificationAuthorization = originalRequester
        }

        settings.notifyOnChanges = true
        manager.didPrimeBaseline = true
        manager.knownDevices = [:]
        // Empty baseline, matching the live (empty, in this test process)
        // WatcherHub.shared.powerWatcher.sources: reconcileChargers sees no
        // added or removed ports and posts nothing.
        manager.knownChargerLabels = [:]

        var posted: [(NotificationManager.NotificationCategory, NotificationManager.NotificationContent)] = []
        manager.notificationSink = { category, content in posted.append((category, content)) }

        manager.deferDeviceDiff([fakeDevice(id: 903)])
        manager.reconcileChargers()

        XCTAssertEqual(
            posted.map(\.0),
            [.device],
            "a reconcile that posted nothing must land the parked diff synchronously, no presentation gap needed"
        )
    }

    /// Codex review: a SECOND `reconcileChargers` call that posts nothing of
    /// its own, arriving while the presentation gap from a FIRST (which DID
    /// post charger content) is still pending, must not land the parked
    /// diff early. Landing it right there, next to the second call's return,
    /// would defeat the gap the first call scheduled: the device post would
    /// still cluster close to the charger post, just relative to the wrong
    /// reconcile. `isPresentationGapPending` must make the second call's
    /// `.immediate` disposition yield to the pending gap instead.
    @MainActor
    func testASecondReconcileThatPostsNothingDoesNotLandBeforeAPendingGapElapses() async {
        let manager = NotificationManager.shared
        let settings = AppSettings.shared

        let originalSink = manager.notificationSink
        let originalDidPrimeBaseline = manager.didPrimeBaseline
        let originalKnownDevices = manager.knownDevices
        let originalKnownChargerLabels = manager.knownChargerLabels
        let originalGapWindow = manager.deferredDeviceDiffPresentationGapWindow
        let originalNotifyOnChanges = settings.notifyOnChanges
        let originalRequester = settings.requestNotificationAuthorization
        settings.requestNotificationAuthorization = {}
        defer {
            manager.notificationSink = originalSink
            manager.didPrimeBaseline = originalDidPrimeBaseline
            manager.knownDevices = originalKnownDevices
            manager.knownChargerLabels = originalKnownChargerLabels
            manager.deferredDeviceDiffPresentationGapWindow = originalGapWindow
            settings.notifyOnChanges = originalNotifyOnChanges
            settings.requestNotificationAuthorization = originalRequester
        }

        settings.notifyOnChanges = true
        manager.deferredDeviceDiffPresentationGapWindow = .milliseconds(30)
        manager.didPrimeBaseline = true
        manager.knownDevices = [:]
        // Baseline charger so the FIRST reconcileChargers call below reads as
        // a removal and posts real content, scheduling the gap.
        manager.knownChargerLabels = ["fake-port-1": "30W negotiated"]

        var posted: [(NotificationManager.NotificationCategory, NotificationManager.NotificationContent)] = []
        manager.notificationSink = { category, content in posted.append((category, content)) }

        manager.deferDeviceDiff([fakeDevice(id: 904)])

        manager.reconcileChargers() // A: posts "Charger disconnected", schedules the gap
        // B: knownChargerLabels is already [:] after A, so the live (empty)
        // WatcherHub set matches it exactly. This posts nothing and, absent
        // the guard, would take .immediate and land the parked diff right
        // here, defeating A's still-pending gap.
        manager.reconcileChargers()

        XCTAssertEqual(
            posted.map(\.0),
            [.charger],
            "a second reconcile posting nothing must not land the diff while an earlier gap is still pending"
        )

        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(
            posted.map(\.0),
            [.charger, .device],
            "the pending gap from the first reconcile must still land the diff once it elapses"
        )
    }

    /// Codex review, second finding: two reconciles that BOTH post real
    /// charger content, close enough together that the second supersedes the
    /// first's still-pending gap.
    ///
    /// Window choice is deliberate and load-bearing for red-proofing this:
    /// A (the one that gets superseded) is given the SHORT window, B (the
    /// newer, "real" one) the LONG window. If the bug is present (no cancel,
    /// no generation guard on the outgoing task), A's stale task is exactly
    /// the one that fires FIRST (its short window elapses well before B's
    /// long one) and lands the diff early via the pre-existing token check
    /// alone (nothing has landed yet at that point, so the token still
    /// matches). Swapping the windows the other way round would make the bug
    /// invisible: whichever of the two happens to have the shorter window
    /// would "correctly" land it regardless of whether it was properly
    /// cancelled, since token-refusal already makes a same-diff double
    /// landing harmless either way. The middle assertion below, taken after A's
    /// window has elapsed but before B's, is what actually distinguishes
    /// "landed early via the stale task" from "still correctly waiting on B".
    @MainActor
    func testANewerGapSupersedesAnOlderStillPendingOne() async {
        let manager = NotificationManager.shared
        let settings = AppSettings.shared

        let originalSink = manager.notificationSink
        let originalDidPrimeBaseline = manager.didPrimeBaseline
        let originalKnownDevices = manager.knownDevices
        let originalKnownChargerLabels = manager.knownChargerLabels
        let originalGapWindow = manager.deferredDeviceDiffPresentationGapWindow
        let originalNotifyOnChanges = settings.notifyOnChanges
        let originalRequester = settings.requestNotificationAuthorization
        settings.requestNotificationAuthorization = {}
        defer {
            manager.notificationSink = originalSink
            manager.didPrimeBaseline = originalDidPrimeBaseline
            manager.knownDevices = originalKnownDevices
            manager.knownChargerLabels = originalKnownChargerLabels
            manager.deferredDeviceDiffPresentationGapWindow = originalGapWindow
            settings.notifyOnChanges = originalNotifyOnChanges
            settings.requestNotificationAuthorization = originalRequester
        }

        settings.notifyOnChanges = true
        manager.didPrimeBaseline = true
        manager.knownDevices = [:]
        manager.knownChargerLabels = ["fake-port-1": "30W negotiated"]

        var posted: [(NotificationManager.NotificationCategory, NotificationManager.NotificationContent)] = []
        manager.notificationSink = { category, content in posted.append((category, content)) }

        manager.deferDeviceDiff([fakeDevice(id: 905)])

        // A: posts "Charger disconnected" (removes fake-port-1), schedules a
        // SHORT gap. This is the one that must end up cancelled/superseded.
        manager.deferredDeviceDiffPresentationGapWindow = .milliseconds(30)
        manager.reconcileChargers()

        // A's gap Task reads `deferredDeviceDiffPresentationGapWindow` lazily,
        // the moment its body actually starts running on the MainActor, not
        // at the point `Task { ... }` was written above: creating a Task from
        // already-running MainActor code enqueues it, it doesn't run inline.
        // Without yielding here, A wouldn't get a turn to start (and capture
        // its 30ms sleep) until AFTER the window is mutated to 300ms below,
        // so it would wrongly end up sleeping 300ms too, and this test would
        // never be able to tell A and B apart. Yielding lets A's body begin
        // (and commit to its `Task.sleep(30ms)` call) before that mutation.
        await Task.yield()

        // B: re-seed a DIFFERENT baseline charger so this call ALSO reads as
        // a removal (of "fake-port-2", which the live, empty WatcherHub set
        // doesn't have either) and posts real content of its own, superseding
        // A's still-pending gap with a LONG one.
        manager.knownChargerLabels = ["fake-port-2": "45W negotiated"]
        manager.deferredDeviceDiffPresentationGapWindow = .milliseconds(300)
        manager.reconcileChargers()

        XCTAssertEqual(
            posted.map(\.0),
            [.charger, .charger],
            "neither reconcile lands the diff itself; both just post charger content"
        )

        // Past A's 30ms window, well short of B's 300ms one. The stale-task
        // bug lands the diff HERE; the fix must not have landed it yet.
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            posted.map(\.0),
            [.charger, .charger],
            "the superseded (shorter) gap must not land the diff; only the newer gap may"
        )

        // Past B's 300ms window too.
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(
            posted.map(\.0),
            [.charger, .charger, .device],
            "the newer gap must still land the diff once its own window elapses"
        )
    }

    /// The bounded fallback: if `reconcileChargers` never runs (charger side
    /// stayed quiet), the parked diff must still land, capped at
    /// `deferredDeviceDiffTimeoutWindow` rather than waiting forever.
    /// Shrunk to well under a second so this stays a fast, non-flaky test;
    /// only the WINDOW is faked, not the mechanism.
    @MainActor
    func testATimedOutDeferralLandsWithoutAReconcile() async {
        let manager = NotificationManager.shared
        let settings = AppSettings.shared

        let originalSink = manager.notificationSink
        let originalDidPrimeBaseline = manager.didPrimeBaseline
        let originalKnownDevices = manager.knownDevices
        let originalTimeoutWindow = manager.deferredDeviceDiffTimeoutWindow
        let originalNotifyOnChanges = settings.notifyOnChanges
        let originalRequester = settings.requestNotificationAuthorization
        settings.requestNotificationAuthorization = {}
        defer {
            manager.notificationSink = originalSink
            manager.didPrimeBaseline = originalDidPrimeBaseline
            manager.knownDevices = originalKnownDevices
            manager.deferredDeviceDiffTimeoutWindow = originalTimeoutWindow
            settings.notifyOnChanges = originalNotifyOnChanges
            settings.requestNotificationAuthorization = originalRequester
        }

        settings.notifyOnChanges = true
        manager.deferredDeviceDiffTimeoutWindow = .milliseconds(50)
        manager.didPrimeBaseline = true
        manager.knownDevices = [:]

        var posted: [(NotificationManager.NotificationCategory, NotificationManager.NotificationContent)] = []
        manager.notificationSink = { category, content in posted.append((category, content)) }

        manager.deferDeviceDiff([fakeDevice(id: 902)])
        // Deliberately never call reconcileChargers: only the bounded
        // timeout can land this diff.
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(
            posted.map(\.0),
            [.device],
            "a deferred diff with no reconcile must still land via the bounded timeout"
        )
    }
}
