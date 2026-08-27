import Foundation
import Combine
import UserNotifications
import os.log
import WhatCableCore
import WhatCableNotifications
import WhatCableDarwinBackend

/// The subset of `UNUserNotificationCenter` the default `notificationSink`
/// drives. Extracted as a protocol so a test can inject a fake, recording
/// center and exercise the REAL `notificationSink` closure end to end
/// (rather than replacing it wholesale, which is all the older wiring tests
/// could do), proving the shim executes removals BEFORE add, not just that
/// it eventually calls both. `UNUserNotificationCenter` conforms
/// structurally below: every method here matches its real signature.
protocol NotificationCenterExecuting: AnyObject {
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?)
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    /// Matches `UNUserNotificationCenter`'s real
    /// `removePendingNotificationRequests(withIdentifiers:)`. `add`
    /// enqueues a request that isn't necessarily delivered yet (it can
    /// still be sitting pending), so a same-category repost that only
    /// called `removeDeliveredNotifications` could leave an EARLIER,
    /// not-yet-delivered request to land on its own moments later,
    /// standing alongside the new one (Codex P2 finding). Removing both
    /// pending and delivered before every `add` closes that gap.
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func getDeliveredNotifications(completionHandler: @escaping @Sendable ([UNNotification]) -> Void)
    func getNotificationSettings(completionHandler: @escaping @Sendable (UNNotificationSettings) -> Void)
}

extension UNUserNotificationCenter: NotificationCenterExecuting {}

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

    /// `NotificationCategory` moved to `WhatCableNotifications` (pure, no
    /// `UNUserNotificationCenter` dependency). Typealiased here so every
    /// existing call site (`NotificationManager.NotificationCategory`,
    /// `.device`, `.charger`) keeps compiling unchanged.
    typealias NotificationCategory = WhatCableNotifications.NotificationCategory

    /// `NotificationContent` itself moved to `WhatCableNotifications` as a
    /// top-level type; typealiased here so every existing call site
    /// (`NotificationManager.NotificationContent`) keeps compiling unchanged.
    typealias NotificationContent = WhatCableNotifications.NotificationContent

    /// `DeliveryDirective` decides the identifier a post uses and what to
    /// remove first; typealiased for the same reason as the two above.
    typealias DeliveryDirective = WhatCableNotifications.NotificationDecision.DeliveryDirective

    /// Where `notificationSink` actually calls `UNUserNotificationCenter`.
    /// `lazy`, not a plain stored default: `UNUserNotificationCenter.current()`
    /// aborts outside a real, signed app bundle (`bundleProxyForCurrentProcess
    /// is nil`), which is exactly the environment `swift test` runs in. A
    /// plain `= UNUserNotificationCenter.current()` default is evaluated
    /// during `init`, i.e. the moment ANYTHING first touches
    /// `NotificationManager.shared`, so it would crash every test in the
    /// suite, not just ones that use this property. `lazy` defers that
    /// resolution to the first actual READ, and nothing reads `center`
    /// except `notificationSink`'s own body and a test that assigns a fake
    /// first. `var`: a test swaps this for a fake, recording center to
    /// drive the real `notificationSink` closure and observe ordering.
    lazy var center: NotificationCenterExecuting = UNUserNotificationCenter.current()

    /// A string unique to this app launch, generated ONCE here (the only
    /// place in this feature allowed to call `UUID()`: the
    /// `WhatCableNotifications` module itself never does, see
    /// `DeviceDiffSequencer.init`'s `launchToken` parameter doc comment)
    /// and threaded into the sequencer, which threads it into
    /// `NotificationDeliveryLedger`. The full UUID string, not a truncated
    /// prefix: a 4-character prefix collides across two launches at 1 in
    /// 65536, and a collision landing during the sweep race guard's exact
    /// window (`NotificationDecision.sweepShouldRemove`'s doc comment) would
    /// recreate the very identifier-reuse bug that guard exists to close,
    /// just with the token matching by accident instead of the sweep simply
    /// running late. The full UUID makes that negligible. This also feeds
    /// the sweep's own exclusion check (`sweepShouldRemove`'s
    /// `currentLaunchToken` parameter), so it needs to keep being this
    /// launch's actual token, not just "distinct enough" for identifier
    /// construction.
    private static let launchToken = UUID().uuidString

    private init() {
        sequencer = DeviceDiffSequencer(
            clock: ContinuousClock(),
            currentDevices: { WatcherHub.shared.deviceWatcher.devices },
            currentChargerSources: { WatcherHub.shared.powerWatcher.sources },
            currentDownstreamTBSwitchIDs: {
                Set(WatcherHub.shared.tbWatcher.switches.filter { $0.depth > 0 }.map(\.id))
            },
            notifyOnChanges: { AppSettings.shared.notifyOnChanges },
            // Not a `[weak self]` capture: `self` isn't fully initialized
            // yet at this point in `init` (this closure is itself part of
            // the expression that initializes `sequencer`, one of `self`'s
            // own stored properties), so Swift refuses to capture it here.
            // Indirecting through the static `shared` singleton instead
            // reads `notificationSink` lazily, at call time (always after
            // `init` has completed), which also means a test that swaps
            // `NotificationManager.shared.notificationSink` is honoured.
            post: { category, content, directive in
                NotificationManager.shared.notificationSink(category, content, directive)
            },
            log: { message in
                NotificationManager.log.info("\(message, privacy: .public)")
            },
            launchToken: Self.launchToken
        )
    }

    func start() {
        // Startup sweep (Codex P1, part 2): clear every delivered
        // notification this module still owns from a PREVIOUS launch. The
        // launch-token fix above stops a fresh launch's own posts from
        // colliding with a stale one, but does nothing about a stale one
        // already sitting in Notification Centre from before this launch
        // even started; this sweep is what actually removes it. Called
        // unconditionally, before anything else in `start()` posts.
        //
        // This USED to reason that nothing has been posted this launch yet
        // at the point this call is made, so every owned identifier found
        // by the completion handler is, by definition, from an earlier
        // launch. That reasoning doesn't hold: `getDeliveredNotifications`
        // is async with unbounded latency, so under login contention its
        // completion can run AFTER this launch's own first post has already
        // landed, well after this call site executed. The sweep no longer
        // relies on timing to make that distinction; it excludes anything
        // carrying this launch's own token instead (`sweepShouldRemove`,
        // threaded through below).
        sweepDeliveredNotificationsOwnedFromEarlierLaunches()

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

    /// Fetches delivered notifications from `center` and removes every one
    /// `NotificationDecision.ownsIdentifier` claims. `center` is captured
    /// as a local `let` (not re-read as `self.center` inside the
    /// completion), for the same reason `notificationSink` below captures
    /// it the same way: `UNUserNotificationCenter` can call completion
    /// handlers on an arbitrary queue, and `center` is a plain,
    /// non-actor-isolated protocol requirement, so reading it once up
    /// front (on the `@MainActor` call site) and using the captured value
    /// inside the closure avoids ever touching `self` off the main actor.
    ///
    /// Split from `removeOwnedDeliveredNotifications(identifiers:via:currentLaunchToken:)`
    /// below on purpose: `UNNotification` has no public initializer, so no
    /// test in this codebase can construct one to drive this method's own
    /// completion handler end to end (see `RecordingCenter`'s doc comment
    /// on `NotificationManagerDeliveryExecutionTests`). The actual
    /// decision-and-removal logic lives in the `nonisolated static` method
    /// below instead, which takes a plain `[String]` and so IS directly
    /// testable; this method is the thin, untestable wrapper that adapts
    /// the real API's `[UNNotification]` down to that shape.
    private func sweepDeliveredNotificationsOwnedFromEarlierLaunches() {
        let sweepCenter = center
        // Captured as a local `let`, same reasoning as `sweepCenter` right
        // above: the completion handler below can run off the main actor,
        // and `launchToken` is a main-actor-isolated static property, so
        // reading it once here (on the `@MainActor` call site) rather than
        // as `Self.launchToken` inside the closure is what keeps the
        // closure itself free of any main-actor-isolated reference.
        let currentLaunchToken = Self.launchToken
        sweepCenter.getDeliveredNotifications { notifications in
            NotificationManager.removeOwnedDeliveredNotifications(
                identifiers: notifications.map(\.request.identifier),
                via: sweepCenter,
                currentLaunchToken: currentLaunchToken
            )
        }
    }

    /// The actual startup-sweep decision: filter `identifiers` down to the
    /// ones `NotificationDecision.sweepShouldRemove` says are safe to clear
    /// (owned by this module AND not carrying `currentLaunchToken`), and if
    /// any survive, remove them via `center`. `nonisolated static` rather
    /// than an instance method: it touches no `NotificationManager` state
    /// (`center` and `currentLaunchToken` are parameters, not read from
    /// `self`), so it needs no main-actor isolation, which is what lets
    /// `sweepDeliveredNotificationsOwnedFromEarlierLaunches` call it
    /// directly from inside a completion handler that may run off the main
    /// actor. Not `private`: a wiring test calls this directly with a
    /// plain `[String]`, proving the filter-and-remove behaviour without
    /// needing a real `UNNotification`.
    nonisolated static func removeOwnedDeliveredNotifications(
        identifiers: [String],
        via center: NotificationCenterExecuting,
        currentLaunchToken: String
    ) {
        let owned = identifiers.filter {
            WhatCableNotifications.NotificationDecision.sweepShouldRemove($0, currentLaunchToken: currentLaunchToken)
        }
        guard !owned.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: owned)
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
    /// real `UNUserNotificationCenter` flow, via `center`) so a test can
    /// drive `notificationSink` itself, the real call site, rather than only
    /// the pure content-decision functions in `WhatCableNotifications`.
    /// Mirrors `UpdateChecker.notificationSink`: without a seam like this, a
    /// wiring test can only prove the pure rules agree with each other,
    /// never that the plumbing between them (e.g. the sequencer's
    /// parked-diff landing actually reaching `UNUserNotificationCenter`) is
    /// still wired up.
    ///
    /// The module decides delivery (`DeliveryDirective`); this closure only
    /// EXECUTES it: remove whatever the directive names, then post under its
    /// identifier. It makes no delivery decisions of its own, and never
    /// reuses an identifier, so every post always banners regardless of what
    /// still sits in Notification Centre (the point of this change: see
    /// `NotificationDecision.DeliveryDirective`'s doc comment for the
    /// no-banner fault this replaces).
    var notificationSink: (NotificationCategory, NotificationContent, DeliveryDirective) -> Void = { category, content, directive in
        let center = NotificationManager.shared.center

        let mutableContent = UNMutableNotificationContent()
        mutableContent.title = content.title
        if !content.body.isEmpty { mutableContent.body = content.body }
        mutableContent.sound = nil

        let bodyLineCount = content.body.isEmpty ? 0 : content.body.split(separator: "\n").count
        NotificationManager.log.info("postNotification: identifier=\(directive.identifier, privacy: .public) removals=\(directive.removeDeliveredIdentifiers.joined(separator: ", "), privacy: .public) title=\(content.title, privacy: .public) bodyLines=\(bodyLineCount, privacy: .public)")

        // Executes the directive's removal, BEFORE the add below. One
        // notification per category standing in Notification Centre at any
        // time is now enforced here, explicitly, rather than by macOS's own
        // identifier-replacement semantics (which the fresh-identifier-per-
        // post scheme below deliberately stops relying on).
        //
        // Both delivered AND pending are removed (Codex P2 finding):
        // `removeDeliveredNotifications` only touches notifications that
        // have already reached Notification Centre. A same-category post
        // from moments ago can still be PENDING (enqueued via `add` but not
        // yet delivered) when this one goes out, and if only the delivered
        // one gets cleared, that pending request can still land on its own
        // a moment later, leaving two notifications standing for a category
        // that's meant to only ever show one.
        if !directive.removeDeliveredIdentifiers.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: directive.removeDeliveredIdentifiers)
            center.removePendingNotificationRequests(withIdentifiers: directive.removeDeliveredIdentifiers)
        }

        // Diagnostic only, async, non-blocking: snapshot of what's actually
        // sitting in Notification Centre right around this post, the
        // forensic hook for the unreproduced no-banner fault (owner report,
        // 2026-08-26). Doesn't gate or delay the add below.
        center.getDeliveredNotifications { notifications in
            let ids = notifications.map(\.request.identifier).joined(separator: ", ")
            NotificationManager.log.info("postNotification: deliveredCount=\(notifications.count, privacy: .public) deliveredIdentifiers=\(ids, privacy: .public)")
        }

        // Diagnostic only: surface whether the system would even show this,
        // so a "posted but never seen" report can be told apart from
        // "never posted". Doesn't gate or change the post below.
        center.getNotificationSettings { settings in
            NotificationManager.log.info("postNotification: authorizationStatus=\(settings.authorizationStatus.rawValue, privacy: .public) alertSetting=\(settings.alertSetting.rawValue, privacy: .public)")
        }

        // Never a reused identifier (see `DeliveryDirective`'s doc comment):
        // macOS therefore has nothing to "replace" and always banners this.
        let request = UNNotificationRequest(
            identifier: directive.identifier,
            content: mutableContent,
            trigger: nil
        )
        center.add(request, withCompletionHandler: { error in
            if let error {
                NotificationManager.log.error("Post failed: \(error.localizedDescription, privacy: .public)")
            }
        })
    }
}
