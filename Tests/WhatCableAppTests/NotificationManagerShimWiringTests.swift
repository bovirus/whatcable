import XCTest
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

        var posted: [(NotificationManager.NotificationCategory, NotificationManager.NotificationContent)] = []
        manager.notificationSink = { category, content in posted.append((category, content)) }

        sequencer.runNowOrDelayForRecentChargerPost([fakeDevice(id: 9001)])

        XCTAssertEqual(
            posted.map(\.0),
            [.device],
            "a sequencer-generated device post must reach NotificationManager.shared's own notificationSink"
        )
        XCTAssertEqual(posted.first?.1.title, "Connected: Shim Wiring Test Device")
    }
}
