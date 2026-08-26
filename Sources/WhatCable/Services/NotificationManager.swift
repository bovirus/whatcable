import Foundation
import Combine
import UserNotifications
import os.log
import WhatCableCore
import WhatCableNotifications
import WhatCableDarwinBackend

/// Posts user notifications when USB-C cables / power sources connect or
/// disconnect, gated by the user's `AppSettings.notifyOnChanges` preference.
///
/// All timing and sequencing (settle debounce, parked-diff bookkeeping,
/// presentation gap, absolute deadline, token/generation guards) lives in
/// `DeviceDiffSequencer`, in `WhatCableNotifications`. This type is the thin
/// app-side shim around it: it subscribes to `WatcherHub`'s publishers and
/// feeds the sequencer plain values, executes the sequencer's post requests
/// via `UNUserNotificationCenter`, gates on `AppSettings.notifyOnChanges`,
/// and forwards diagnostic log lines. See `DeviceDiffSequencer`'s own doc
/// comment for the ordering mechanism itself.
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private nonisolated static let log = Logger(subsystem: "uk.whatcable.whatcable", category: "notifications")

    private var cancellables = Set<AnyCancellable>()

    /// The sequencer this shim drives. `ContinuousClock` in production; a
    /// sequencer test builds its own instance with a fake clock instead.
    /// Not `private`: a wiring test still reaches into `NotificationManager`
    /// via `@testable import` for the handful of concerns that remain here
    /// (`notificationSink`), and the sequencer itself needs to be readable
    /// for `AppSettings.requestNotificationAuthorization`-style plumbing if
    /// that ever grows.
    let sequencer: DeviceDiffSequencer<ContinuousClock>

    /// `NotificationCategory` and `notificationIdentifier(for:)` moved to
    /// `WhatCableNotifications` (pure, no `UNUserNotificationCenter`
    /// dependency). Typealiased here so every existing call site
    /// (`NotificationManager.NotificationCategory`, `.device`, `.charger`)
    /// keeps compiling unchanged.
    typealias NotificationCategory = WhatCableNotifications.NotificationCategory

    /// `NotificationContent` itself moved to `WhatCableNotifications` as a
    /// top-level type; typealiased here so every existing call site
    /// (`NotificationManager.NotificationContent`) keeps compiling unchanged.
    typealias NotificationContent = WhatCableNotifications.NotificationContent

    private init() {
        sequencer = DeviceDiffSequencer(
            clock: ContinuousClock(),
            currentDevices: { WatcherHub.shared.deviceWatcher.devices },
            currentChargerSources: { WatcherHub.shared.powerWatcher.sources },
            notifyOnChanges: { AppSettings.shared.notifyOnChanges },
            // Not a `[weak self]` capture: `self` isn't fully initialized
            // yet at this point in `init` (this closure is itself part of
            // the expression that initializes `sequencer`, one of `self`'s
            // own stored properties), so Swift refuses to capture it here.
            // Indirecting through the static `shared` singleton instead
            // reads `notificationSink` lazily, at call time (always after
            // `init` has completed), which also means a test that swaps
            // `NotificationManager.shared.notificationSink` is honoured.
            post: { category, content in
                NotificationManager.shared.notificationSink(category, content)
            },
            log: { message in
                NotificationManager.log.info("\(message, privacy: .public)")
            }
        )
    }

    func start() {
        // Prime baseline on the next runloop tick so we don't fire a flurry
        // of "connected" notifications for things already plugged in at launch.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sequencer.primeBaseline(
                devices: WatcherHub.shared.deviceWatcher.devices,
                chargerSources: WatcherHub.shared.powerWatcher.sources
            )
        }

        WatcherHub.shared.deviceWatcher.$devices
            .sink { [weak self] _ in self?.sequencer.scheduleDeviceDiff() }
            .store(in: &cancellables)

        WatcherHub.shared.powerWatcher.$sources
            .sink { [weak self] sources in self?.sequencer.diffSources(sources) }
            .store(in: &cancellables)
    }

    /// Request notification permission. Call when the user enables the toggle.
    func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        Self.log.error("Notification auth failed: \(error.localizedDescription, privacy: .public)")
                    } else {
                        Self.log.info("Notification auth granted: \(granted)")
                    }
                }
            default:
                break
            }
        }
    }

    /// Where a notification actually gets posted. Injected (default is the
    /// real `UNUserNotificationCenter` flow) so a test can drive
    /// `notificationSink` itself, the real call site, rather than only the
    /// pure content-decision functions in `WhatCableNotifications`. Mirrors
    /// `UpdateChecker.notificationSink`: without a seam like this, a wiring
    /// test can only prove the pure rules agree with each other, never that
    /// the plumbing between them (e.g. the sequencer's parked-diff landing
    /// actually reaching `UNUserNotificationCenter`) is still wired up.
    var notificationSink: (NotificationCategory, NotificationContent) -> Void = { category, content in
        let mutableContent = UNMutableNotificationContent()
        mutableContent.title = content.title
        if !content.body.isEmpty { mutableContent.body = content.body }
        mutableContent.sound = nil

        let identifier = NotificationDecision.notificationIdentifier(for: category)
        let bodyLineCount = content.body.isEmpty ? 0 : content.body.split(separator: "\n").count
        NotificationManager.log.info("postNotification: identifier=\(identifier, privacy: .public) title=\(content.title, privacy: .public) bodyLines=\(bodyLineCount, privacy: .public)")

        // Diagnostic only: surface whether the system would even show this,
        // so a "posted but never seen" report can be told apart from
        // "never posted". Doesn't gate or change the post below.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            NotificationManager.log.info("postNotification: authorizationStatus=\(settings.authorizationStatus.rawValue, privacy: .public) alertSetting=\(settings.alertSetting.rawValue, privacy: .public)")
        }

        // Same identifier per category replaces the previous notification
        // in place rather than stacking a new one (issue #567): a second
        // device event leaves ONE entry in Notification Centre, not two.
        let request = UNNotificationRequest(
            identifier: identifier,
            content: mutableContent,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NotificationManager.log.error("Post failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
