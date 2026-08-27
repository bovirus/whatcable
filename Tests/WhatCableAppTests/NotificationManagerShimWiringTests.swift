import XCTest
import UserNotifications
import WhatCableCore
@testable import WhatCable
@testable import WhatCableNotifications

/// Proves the app-side shim's `post` closure actually reaches
/// `NotificationManager.shared.notificationSink`, not just that the
/// sequencer's OWN unit tests agree with themselves. Since unit 2 of the
/// notifications-module extraction, nothing else in the suite drives
/// `NotificationManager.shared.sequencer` end to end: every timing behaviour
/// moved to `DeviceDiffSequencerTests`, which constructs its own standalone
/// sequencer and never touches the app's shared singleton or its `post`
/// closure at all. If that closure's indirection through `notificationSink`
/// (`NotificationManager.swift`'s `init`, documented there as necessary
/// because `self` isn't fully initialized yet at that point) were ever
/// silently disconnected, this suite would otherwise stay green.
///
/// Drives `runNowOrDelayForRecentChargerPost` directly (internal on
/// `DeviceDiffSequencer`, reachable via `@testable import
/// WhatCableNotifications`) rather than `reconcileChargers`: that path posts
/// synchronously with no dependency on the real, live charger set
/// `WatcherHub.shared.powerWatcher.sources` returns in the `swift test`
/// process (which the old, now-removed wiring tests' equivalent charger-path
/// tests DID depend on, and is genuinely nondeterminate: this Mac may or may
/// not be on external power when the suite runs). `lastChargerPostTime` is
/// reset to `nil` first so `devicePostDelay` always resolves to zero delay,
/// regardless of what an earlier test in the suite may have left behind.
final class NotificationManagerShimWiringTests: XCTestCase {
    private func fakeDevice(id: UInt64) -> USBDevice {
        USBDevice(
            id: id, locationID: 0x01_00_00_00, vendorID: 0, productID: 0,
            vendorName: nil, productName: "Shim Wiring Test Device", serialNumber: nil,
            usbVersion: nil, speedRaw: 3, busPowerMA: nil, currentMA: nil,
            rawProperties: [:]
        )
    }

    @MainActor
    func testASequencerGeneratedPostReachesNotificationManagersSink() {
        let manager = NotificationManager.shared
        let sequencer = manager.sequencer
        let settings = AppSettings.shared

        let originalSink = manager.notificationSink
        let originalDidPrimeBaseline = sequencer.didPrimeBaseline
        let originalKnownDevices = sequencer.knownDevices
        let originalLastChargerPostTime = sequencer.lastChargerPostTime
        let originalNotifyOnChanges = settings.notifyOnChanges
        let originalRequestAuth = settings.requestNotificationAuthorization
        settings.requestNotificationAuthorization = {}
        defer {
            manager.notificationSink = originalSink
            sequencer.didPrimeBaseline = originalDidPrimeBaseline
            sequencer.knownDevices = originalKnownDevices
            sequencer.lastChargerPostTime = originalLastChargerPostTime
            settings.notifyOnChanges = originalNotifyOnChanges
            settings.requestNotificationAuthorization = originalRequestAuth
        }

        settings.notifyOnChanges = true
        sequencer.didPrimeBaseline = true
        sequencer.knownDevices = [:]
        sequencer.lastChargerPostTime = nil

        var posted: [(NotificationManager.NotificationCategory, NotificationManager.NotificationContent, NotificationManager.DeliveryDirective)] = []
        manager.notificationSink = { category, content, directive in posted.append((category, content, directive)) }

        sequencer.runNowOrDelayForRecentChargerPost([fakeDevice(id: 9001)])

        XCTAssertEqual(
            posted.map(\.0),
            [.device],
            "a sequencer-generated device post must reach NotificationManager.shared's own notificationSink"
        )
        XCTAssertEqual(posted.first?.1.title, "Connected: Shim Wiring Test Device")
        XCTAssertFalse(
            posted.first?.2.identifier.isEmpty ?? true,
            "the sink must receive a non-empty delivery directive identifier"
        )
    }
}

/// Proves the DEFAULT `notificationSink` implementation (not a test double
/// standing in for it) executes a `DeliveryDirective`'s removals BEFORE it
/// adds the new notification, by injecting a fake, recording
/// `NotificationCenterExecuting` in place of the real
/// `UNUserNotificationCenter`. `NotificationManagerShimWiringTests` above
/// only proves the sequencer's post reaches `notificationSink`; it swaps
/// `notificationSink` out entirely, so it can't see anything about what the
/// real closure body does. This class drives the real closure directly.
final class NotificationManagerDeliveryExecutionTests: XCTestCase {
    /// Records calls in the order they happen, so ordering (not just
    /// "both happened") is what the test asserts.
    private final class RecordingCenter: NotificationCenterExecuting {
        enum Call: Equatable {
            case remove([String])
            case removePending([String])
            case add(String)
            case getDelivered
        }

        private(set) var calls: [Call] = []

        func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?) {
            calls.append(.add(request.identifier))
            completionHandler?(nil)
        }

        func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
            calls.append(.remove(identifiers))
        }

        func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
            calls.append(.removePending(identifiers))
        }

        func getDeliveredNotifications(completionHandler: @escaping @Sendable ([UNNotification]) -> Void) {
            // No real `UNNotification` can be constructed in a test (no
            // public initializer), so this records that the call happened
            // (proving `start()`/`notificationSink` actually reach it) but
            // never invokes the completion handler. `NotificationManager
            // .removeOwnedDeliveredNotifications(identifiers:via:)` below
            // is where the filter-and-remove logic that would normally run
            // INSIDE this completion handler is tested directly instead,
            // with a plain `[String]` standing in for what real
            // `UNNotification`s would supply.
            calls.append(.getDelivered)
        }

        func getNotificationSettings(completionHandler: @escaping @Sendable (UNNotificationSettings) -> Void) {
            // Same reasoning as above: `UNNotificationSettings` has no
            // public initializer either, and this diagnostic isn't under
            // test here.
        }
    }

    @MainActor
    func testDefaultSinkExecutesRemovalsBeforeAdd() {
        let manager = NotificationManager.shared

        // No save/restore of `manager.center` around this test (unlike the
        // `notificationSink` swap above): `center` is `lazy`, specifically
        // so nothing resolves the real `UNUserNotificationCenter` under
        // `swift test` (see its doc comment). READING it here just to save
        // the original would force that resolution and crash. Nothing else
        // in this suite depends on `center`'s value, so leaving the fake in
        // place after this test is harmless -- DELIBERATELY, not an
        // oversight. This is a shared, process-wide singleton
        // (`NotificationManager.shared`): once this test runs, EVERY test
        // that runs afterward in the same process (in this file or any
        // other target sharing the process) that touches `manager.center`,
        // or drives the default `notificationSink` without swapping its own
        // fake in first, inherits THIS fake, not the real
        // `UNUserNotificationCenter`. That is intentional and safe here
        // (nothing else currently reads `center` without first assigning
        // its own fake), but it is the reason no `defer { manager.center =
        // original }` exists below: restoring it would force the very
        // `UNUserNotificationCenter.current()` resolution this test exists
        // to avoid, which aborts outside a signed app bundle (no
        // `bundleProxyForCurrentProcess`), i.e. it would crash `swift test`
        // itself. If a future test needs to observe the REAL
        // `UNUserNotificationCenter` default, it cannot rely on `center`
        // still being unassigned by the time it runs.
        let recording = RecordingCenter()
        manager.center = recording

        let directive = NotificationManager.DeliveryDirective(
            identifier: "device-event-2",
            removeDeliveredIdentifiers: ["device-event-1"]
        )
        manager.notificationSink(.device, NotificationManager.NotificationContent(title: "Connected: Test Device", body: ""), directive)

        XCTAssertEqual(
            recording.calls,
            // `.getDelivered` between the removals and the add is the
            // sink's own pre-existing forensic diagnostic call (see
            // `notificationSink`'s doc comment: a snapshot of what's
            // sitting in Notification Centre right around this post),
            // unrelated to the startup sweep this fake's `.getDelivered`
            // case also records; it's asserted here purely because it's
            // part of the real, observed call sequence, not because this
            // test cares about it.
            [.remove(["device-event-1"]), .removePending(["device-event-1"]), .getDelivered, .add("device-event-2")],
            "both the delivered removal and the pending removal must be executed before the add, both using the directive's own removal list, and the add must use the directive's own identifier"
        )
    }

    // MARK: - Startup sweep (Codex P1, part 2)

    /// Direct test of the filter-and-remove decision, bypassing
    /// `getDeliveredNotifications` entirely (see that method's doc comment
    /// above for why): a mix of legacy, current-scheme, and foreign
    /// identifiers goes in, and only the ones `ownsIdentifier` claims come
    /// out the other end, in one `removeDeliveredNotifications` call.
    func testRemoveOwnedDeliveredNotificationsRemovesExactlyTheOwnedIdentifiers() {
        let recording = RecordingCenter()
        // "CURRENT" is a fixed stand-in launch token, deliberately not
        // present in any identifier below: none of these are meant to be
        // excluded by the sweep race guard, only by ownership.
        NotificationManager.removeOwnedDeliveredNotifications(
            identifiers: [
                "device-event", // legacy, owned
                "charger-event", // legacy, owned
                "device-event-abc-7", // current scheme, owned
                "charger-event-4f2a-1", // current scheme, owned
                "update-1.2.3", // foreign, not owned
                "some-random-string", // foreign, not owned
            ],
            via: recording,
            currentLaunchToken: "CURRENT"
        )

        XCTAssertEqual(
            recording.calls,
            [.remove(["device-event", "charger-event", "device-event-abc-7", "charger-event-4f2a-1"])],
            "only identifiers this module owns must be removed; foreign identifiers (update-*, arbitrary strings) must never be touched"
        )
    }

    /// A pure "nothing owned" case gets no removal call at all, not a call
    /// with an empty array: `removeDeliveredNotifications(withIdentifiers:
    /// [])` is a harmless no-op on the real API, but asserting the call
    /// never happens is a stronger, more precise proof of the guard.
    func testRemoveOwnedDeliveredNotificationsCallsNothingWhenNoneAreOwned() {
        let recording = RecordingCenter()
        NotificationManager.removeOwnedDeliveredNotifications(
            identifiers: ["update-1.2.3", "some-random-string"],
            via: recording,
            currentLaunchToken: "CURRENT"
        )
        XCTAssertEqual(recording.calls, [])
    }

    /// Sweep race guard (final gate finding): an identifier carrying THIS
    /// launch's own token must never be removed by the startup sweep, even
    /// though `ownsIdentifier` alone would claim it, because
    /// `getDeliveredNotifications`'s completion has no bounded latency and
    /// can run after this launch's own first post has already landed. Mixed
    /// in with an owned-but-foreign-token identifier and a genuinely foreign
    /// one, to prove the guard is additive on top of ownership, not a
    /// replacement for it.
    func testRemoveOwnedDeliveredNotificationsNeverRemovesTheCurrentLaunchsOwnIdentifier() {
        let recording = RecordingCenter()
        NotificationManager.removeOwnedDeliveredNotifications(
            identifiers: [
                "device-event", // legacy, owned, no token to exclude on
                "device-event-OLDTOKEN-3", // owned, earlier launch's token
                "device-event-CURRENT-1", // owned, but THIS launch's token: must survive
                "foreign", // not owned
            ],
            via: recording,
            currentLaunchToken: "CURRENT"
        )

        XCTAssertEqual(
            recording.calls,
            [.remove(["device-event", "device-event-OLDTOKEN-3"])],
            "the sweep must remove the legacy and earlier-launch identifiers but never the current launch's own"
        )
    }

    /// Cross-category symmetry: the same current-token exclusion must hold
    /// for a charger identifier, not just a device one, since
    /// `sweepShouldRemove` is category-agnostic.
    func testRemoveOwnedDeliveredNotificationsNeverRemovesAChargerIdentifierWithTheCurrentToken() {
        let recording = RecordingCenter()
        NotificationManager.removeOwnedDeliveredNotifications(
            identifiers: ["charger-event-CURRENT-1"],
            via: recording,
            currentLaunchToken: "CURRENT"
        )

        XCTAssertEqual(
            recording.calls, [],
            "a charger identifier carrying the current launch's token must survive the sweep exactly like a device one does"
        )
    }

    /// Proves `start()` itself is wired to fetch delivered notifications for
    /// the sweep, not just that the filter-and-remove logic works in
    /// isolation (the two tests above). Doesn't assert on what happens
    /// inside the completion handler (see `getDeliveredNotifications`'s
    /// fake above for why it can't), only that `start()` reaches
    /// `center.getDeliveredNotifications` at all.
    @MainActor
    func testStartFetchesDeliveredNotificationsForTheStartupSweep() {
        let manager = NotificationManager.shared
        let recording = RecordingCenter()
        manager.center = recording

        manager.start()

        XCTAssertTrue(
            recording.calls.contains(.getDelivered),
            "start() must fetch delivered notifications so the startup sweep can clear anything this module still owns from an earlier launch"
        )
    }
}
