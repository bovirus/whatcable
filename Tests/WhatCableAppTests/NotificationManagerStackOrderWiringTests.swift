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

    @MainActor
    func testReconcileChargersLandsAParkedDeviceDiffAfterItsOwnPosts() {
        let manager = NotificationManager.shared
        let settings = AppSettings.shared

        let originalSink = manager.notificationSink
        let originalDidPrimeBaseline = manager.didPrimeBaseline
        let originalKnownDevices = manager.knownDevices
        let originalKnownChargerLabels = manager.knownChargerLabels
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
            settings.notifyOnChanges = originalNotifyOnChanges
            settings.requestNotificationAuthorization = originalRequester
        }

        settings.notifyOnChanges = true
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
            [.charger, .device],
            "the parked device diff must land after reconcileChargers's own posts, so the device notification stacks on top"
        )
        XCTAssertEqual(posted.last?.1.title, "Connected: Test Hub")
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
