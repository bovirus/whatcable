import Foundation
import Combine
import UserNotifications
import os.log
import WhatCableCore
import WhatCableDarwinBackend

/// Posts user notifications when USB-C cables / power sources connect or
/// disconnect, gated by the user's `AppSettings.notifyOnChanges` preference.
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private nonisolated static let log = Logger(subsystem: "uk.whatcable.whatcable", category: "notifications")

    private var cancellables = Set<AnyCancellable>()

    // The three below are `private` in production terms (nothing outside
    // this file should touch them) but not marked `private` in Swift's sense:
    // a wiring test primes them directly to drive `diffDevices`/
    // `reconcileChargers` themselves, the actual call sites, without the real
    // `WatcherHub`/`UNUserNotificationCenter` machinery behind them. `@testable
    // import` only reaches `internal` (Swift's default access level), not
    // `private`, so that's the level these sit at.
    var knownDevices: [UInt64: USBDeviceChangeGrouper.Snapshot] = [:]
    var knownChargerLabels: [String: String] = [:]
    var didPrimeBaseline = false

    /// One notification category per event type (issue #567). Posting with
    /// the same identifier replaces the previous notification in place
    /// (Apple's sanctioned "one standing notification per topic" pattern),
    /// so a second device event doesn't leave two separate banners sitting
    /// in Notification Centre. Charger and device events use distinct
    /// identifiers so one never replaces the other.
    enum NotificationCategory: String, Equatable {
        case device = "device-event"
        case charger = "charger-event"
    }

    /// Pure identifier lookup, kept separate from `postNotification` so the
    /// "same category -> same identifier, different category -> different
    /// identifier" rule is unit-testable without `UNUserNotificationCenter`.
    nonisolated static func notificationIdentifier(for category: NotificationCategory) -> String {
        category.rawValue
    }

    private var chargerSettleTask: Task<Void, Never>?
    /// True from the moment a charger settle task is scheduled until the
    /// moment it actually runs `reconcileChargers` (or is superseded). A
    /// non-nil `chargerSettleTask` isn't enough on its own to mean "still
    /// pending": the task reference is never cleared after it fires, so a
    /// long-finished task would look identical to one still waiting out its
    /// window. This is the value `scheduleDeviceDiff` feeds into
    /// `deviceDiffDisposition`, and it gates a DEFERRAL of the device post,
    /// never an early run of the charger reconcile itself (see
    /// `deferDeviceDiff`'s doc comment for why an early flush was rejected on
    /// review). `private(set)`, not `private`: a wiring test drives
    /// `NotificationManager.shared` end to end and needs to read it.
    private(set) var isChargerSettlePending = false

    /// State for a device diff that is waiting on a same-episode charger
    /// reconcile to post first (see `deviceDiffDisposition`). Only one diff
    /// can be deferred at a time: a device settle firing again while one is
    /// already waiting means a fresh device episode is starting, so the
    /// waiting one is superseded, same as `deviceSettleTask` itself.
    private var deferredDeviceDiffDevices: [USBDevice]?
    /// Bounds how long a deferred diff waits for `reconcileChargers` to land
    /// it naturally. A continuously flapping charger would otherwise keep
    /// re-arming `chargerSettleTask` forever and starve every device
    /// notification behind it, so this fires the diff anyway after one
    /// charger settle window with no natural landing.
    private var deferredDeviceDiffTimeoutTask: Task<Void, Never>?
    /// How long `deferDeviceDiff` waits before landing anyway. `var`, and
    /// defaulted separately from `chargerSettleWindow` (deliberately not a
    /// reference to it), purely so a test can shrink it to a few tens of
    /// milliseconds and exercise the timeout landing path without a real
    /// 1.5s sleep. Production never touches this; it starts at, and stays
    /// at, the same 1.5s value as every other settle window in this file.
    var deferredDeviceDiffTimeoutWindow: Duration = .milliseconds(1500)
    /// Presentation-gap fix (owner, live verification): when a parked device
    /// diff landed synchronously inside `reconcileChargers`'s `defer`, the
    /// charger post and the device post both reached
    /// `UNUserNotificationCenter` in the same millisecond. macOS presents
    /// only the LAST of two simultaneous banners, so "Charger disconnected"
    /// never showed on screen (it only reached Notification Centre's list):
    /// the fix that made ordering correct accidentally made the older of the
    /// two invisible. The old code's accidental ~300ms gap between the two
    /// posts is what used to let both banners present, so a deliberate delay
    /// restores that presentation gap on purpose. Task, not a stored
    /// deadline: cancelled the same way `deferredDeviceDiffTimeoutTask` is,
    /// see `deferDeviceDiff` and `landDeferredDeviceDiffNow`.
    private var deferredDeviceDiffPresentationGapTask: Task<Void, Never>?
    /// True from the moment `landDeferredDeviceDiff` schedules a presentation
    /// gap until that gap actually lands the diff (or is cancelled by a
    /// fresh deferral). Guards a specific interleaving Codex review raised:
    /// a SECOND `reconcileChargers` call that lands while the gap from a
    /// FIRST is still pending, and posts no charger content of its own,
    /// would otherwise take the `.immediate` branch below and land the diff
    /// right there, defeating the gap the first call scheduled. Timing
    /// analysis says this is unreachable live: `reconcileChargers` is
    /// trailing-debounced to `chargerSettleWindow` (1.5s), and the gap is
    /// only 500ms, so two reconciles for the same charger cannot land this
    /// close together in production. This guard exists anyway so the
    /// exactly-once invariant doesn't rest on that timing coincidence.
    private var isPresentationGapPending = false
    /// Identity for the CURRENT gap task, bumped every time
    /// `landDeferredDeviceDiff`'s `.afterPresentationGap` case schedules one.
    /// A second Codex finding on the guard above: scheduling a new gap task
    /// used to just overwrite `deferredDeviceDiffPresentationGapTask` without
    /// cancelling the outgoing one, so a stale task could wake later, run its
    /// body (its `Task.isCancelled` check never tripped, because nothing
    /// cancelled it), and unconditionally clear `isPresentationGapPending` --
    /// even though a NEWER gap for the same diff was still legitimately
    /// pending. That wrong clear is exactly what would let a subsequent
    /// `.immediate` reconcile land the diff early. Two independent guards
    /// close this, both required per review ("neither a cancelled nor a
    /// superseded task can mutate shared state"):
    ///  1. `landDeferredDeviceDiff` now explicitly cancels any existing gap
    ///     task before scheduling a new one, so `Task.isCancelled` trips for
    ///     the outgoing task.
    ///  2. Every gap task also captures its own generation here and checks it
    ///     against the live value before touching ANYTHING (not just before
    ///     landing, before even clearing the flag). This is the one that
    ///     actually matters: it makes "a stale task can't mutate shared
    ///     state" true by construction, not by relying on `.cancel()` having
    ///     been observed in time. In this codebase's single `@MainActor`
    ///     scheduling, `.cancel()` alone would already be sufficient (it
    ///     completes synchronously before any queued continuation resumes),
    ///     so this is deliberate belt-and-braces on top of belt-and-braces:
    ///     it holds even if this code is ever restructured off the actor.
    private var deferredDeviceDiffPresentationGapGeneration = 0
    /// How long `landDeferredDeviceDiff(token:afterChargerPost:)` waits
    /// before landing a diff that reconciled alongside real charger content.
    /// `var`, mirroring `deferredDeviceDiffTimeoutWindow`, so a test can
    /// shrink it to a few tens of milliseconds. Production stays at 500ms:
    /// long enough for macOS to have already started presenting the charger
    /// banner before the device banner posts, short enough not to read as a
    /// separate, unrelated notification.
    var deferredDeviceDiffPresentationGapWindow: Duration = .milliseconds(500)
    /// Guards against the deferred diff landing twice. Incremented both when
    /// a new diff is deferred (invalidating any earlier one still in
    /// flight) and by whichever landing path actually runs the diff
    /// (`landDeferredDeviceDiffNow`, reached either straight from
    /// `reconcileChargers` when it posted nothing, or after the timeout
    /// above, or after the presentation gap above). All three paths hop
    /// through the `@MainActor`, so two can never truly run at the same
    /// instant; the token exists so whichever arrives SECOND sees a value
    /// that no longer matches what it captured and backs out instead of
    /// running the diff again. `shouldLandDeferredDiff` is the pure
    /// comparison this reads. See `landDeferredDeviceDiff(token:afterChargerPost:)`'s
    /// doc comment for the full three-path interleaving walk-through.
    private var deferredDeviceDiffToken = 0
    /// A charger's power-source services can briefly disappear and reappear
    /// during PD renegotiation / re-enumeration, so the published list flaps
    /// (present -> absent -> present). Comparing each publish in isolation
    /// fires a "connected" notification per flap. Instead we wait for the set
    /// to stop changing, then reconcile once. The window must exceed the gap
    /// between consecutive publishes during a connect. Those publishes are
    /// driven by the power-source IOKit notifications (match/terminated), not
    /// by WatcherHub's steady poll, so the flap happens at IOKit speed
    /// regardless of the poll cadence; the gap is sub-second. 1.5s clears it
    /// with margin. See issue #227 follow-up.
    private let chargerSettleWindow: Duration = .milliseconds(1500)

    private var deviceSettleTask: Task<Void, Never>?
    /// A hub's own termination and its children's terminations don't arrive
    /// from IOKit as one atomic batch: unplugging a hub can surface the
    /// child's "gone" callback and the hub's "gone" callback in separate
    /// fires, sometimes with the hub arriving late, sometimes the other way
    /// round. Diffing every publish in isolation reports whatever happened to
    /// have settled by that point, so which device names show up in the
    /// notification varies. Mirrors `chargerSettleWindow`: wait for the
    /// published device list to stop changing, then diff once, so a hub
    /// teardown (or a hub-and-children connect) lands inside a single diff
    /// instead of being split across several. See issue #551.
    private let deviceSettleWindow: Duration = .milliseconds(1500)

    private init() {}

    func start() {
        // Prime baseline on the next runloop tick so we don't fire a flurry
        // of "connected" notifications for things already plugged in at launch.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let baselineSnapshots = WatcherHub.shared.deviceWatcher.devices.map(self.snapshot(for:))
            self.knownDevices = Dictionary(
                baselineSnapshots.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            // Prime with canonicalJoinKey to match reconcileChargers, so the
            // baseline and the diff use the same key space (else every connected
            // charger would fire a spurious "connected" on the first poll).
            self.knownChargerLabels = self.chargerLabels(for: WatcherHub.shared.powerWatcher.sources)
            self.didPrimeBaseline = true
        }

        WatcherHub.shared.deviceWatcher.$devices
            .sink { [weak self] _ in self?.scheduleDeviceDiff() }
            .store(in: &cancellables)

        WatcherHub.shared.powerWatcher.$sources
            .sink { [weak self] sources in self?.diffSources(sources) }
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

    /// Trailing-edge debounce mirroring `diffSources`/`reconcileChargers`:
    /// keep resetting the timer while the device list is still changing,
    /// then diff once it settles. This is what coalesces a hub's split-fire
    /// termination (child gone, then hub gone in a later publish) into one
    /// diff. See `deviceSettleWindow` and issue #551.
    private func scheduleDeviceDiff() {
        deviceSettleTask?.cancel()
        deviceSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.deviceSettleWindow ?? .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            let devices = WatcherHub.shared.deviceWatcher.devices
            switch Self.deviceDiffDisposition(chargerSettlePending: self.isChargerSettlePending) {
            case .runNow:
                self.diffDevices(devices)
            case .deferUntilChargerReconcile:
                self.deferDeviceDiff(devices)
            }
        }
    }

    /// Stack-order fix (owner report): unplugging a powered dock fires a
    /// device settle and a charger settle from the same physical event, and
    /// they used to post device-then-charger. macOS stacks the newest post
    /// on top, so the charger banner landed on top of the richer device
    /// banner, the one users actually read. When both settle windows belong
    /// to the same episode, the charger content must post FIRST so the
    /// device content posts LAST and stacks on top.
    ///
    /// An earlier version of this fix cancelled the pending charger settle
    /// timer and ran `reconcileChargers` early, synchronously, from here.
    /// Review (Codex) caught that `isChargerSettlePending` only means "a
    /// charger update happened in the last `chargerSettleWindow`", not "the
    /// charger set has stopped changing": running the reconcile on that
    /// signal can fire mid-flap, posting exactly the spurious
    /// disconnected/connected pair issue #227's debounce exists to
    /// suppress. So the charger side is never touched early. Instead the
    /// DEVICE post is deferred: `reconcileChargers` still runs on its own
    /// undisturbed 1.5s window, and once it finishes it lands the waiting
    /// device diff itself, so the charger post always precedes it.
    enum DeviceDiffDisposition: Equatable {
        case runNow
        case deferUntilChargerReconcile
    }

    /// Pure ordering rule: given a charger settle task still pending in the
    /// same episode as a settling device diff, the device diff must wait for
    /// that charger reconcile to land it, not run immediately.
    nonisolated static func deviceDiffDisposition(chargerSettlePending: Bool) -> DeviceDiffDisposition {
        chargerSettlePending ? .deferUntilChargerReconcile : .runNow
    }

    /// Park a settled device diff until the pending charger reconcile lands
    /// it (see `reconcileChargers`'s `defer`) or `deferredDeviceDiffTimeoutTask`
    /// times it out. Superseding an earlier still-waiting diff (rather than
    /// composing with it) mirrors `deviceSettleTask`/`chargerSettleTask`:
    /// only the latest settled state matters. Cancelling BOTH the timeout
    /// task and the presentation-gap task here (not just the timeout) is
    /// what keeps a superseded episode's stale gap wait from doing anything
    /// once it eventually fires: see the interleaving walk-through on
    /// `landDeferredDeviceDiff(token:afterChargerPost:)`.
    ///
    /// Not `private`: a wiring test calls this directly to park a diff
    /// without going through `scheduleDeviceDiff`'s own 1.5s `Task.sleep` and
    /// live `WatcherHub` read, so it can drive the actual landing plumbing
    /// (this function plus `reconcileChargers`'s `defer`) rather than only
    /// the pure rules that decide it.
    ///
    /// Accepted trade-off: a charger event that is UNRELATED to the parked
    /// device diff (arrives, and its own settle task overlaps the window)
    /// can delay that device notification by up to one settle window
    /// (`deferredDeviceDiffTimeoutWindow`, 1.5s in production), because
    /// `isChargerSettlePending` can't distinguish "the same physical episode"
    /// from "an unrelated charger event that happens to overlap". That delay
    /// is bounded by the timeout below and never drops the notification, so
    /// it's accepted for the sake of getting the ordering right on the
    /// common case (the same episode) this fix targets.
    func deferDeviceDiff(_ devices: [USBDevice]) {
        deferredDeviceDiffToken += 1
        let token = deferredDeviceDiffToken
        deferredDeviceDiffDevices = devices

        deferredDeviceDiffTimeoutTask?.cancel()
        deferredDeviceDiffPresentationGapTask?.cancel()
        deferredDeviceDiffPresentationGapGeneration += 1
        isPresentationGapPending = false
        deferredDeviceDiffTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.deferredDeviceDiffTimeoutWindow ?? .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            self.landDeferredDeviceDiffNow(token: token)
        }
    }

    /// Whether landing a parked device diff, on the reconcile-completion
    /// path specifically, should wait out a deliberate presentation gap
    /// first or run immediately. Pure rule extracted so the decision is
    /// unit-testable without `Task`. Only `landDeferredDeviceDiff(token:
    /// afterChargerPost:)` reads it; the timeout path in `deferDeviceDiff`
    /// never asks, because a diff that timed out waiting for a reconcile has,
    /// by definition, no charger post to clash with.
    enum DeferredDiffLanding: Equatable {
        case immediate
        case afterPresentationGap
    }

    /// `reconcileChargers` actually posted charger content this time ->
    /// its post and the device post would otherwise land in the same
    /// millisecond and macOS would show only the later one. Nothing posted
    /// -> nothing on screen to clash with, so land immediately, unchanged
    /// from before this fix.
    nonisolated static func deferredDiffLanding(reconcilePostedChargerContent: Bool) -> DeferredDiffLanding {
        reconcilePostedChargerContent ? .afterPresentationGap : .immediate
    }

    /// Entry point for the reconcile-completion landing path (called from
    /// `reconcileChargers`'s `defer`). Decides gap vs immediate via
    /// `deferredDiffLanding`, then either lands right away or schedules the
    /// gap. A no-op when nothing is deferred, so `reconcileChargers` can call
    /// this unconditionally on every exit without checking whether a diff was
    /// actually waiting.
    ///
    /// Interleavings this has to survive, all of them exercised by walking
    /// through what each landing path does to `deferredDeviceDiffToken` /
    /// `deferredDeviceDiffDevices`:
    ///
    /// 1. **Gap completes normally.** `landDeferredDeviceDiffNow` runs after
    ///    the sleep, token still matches (nothing superseded it), lands, and
    ///    cancels the (now finished) timeout task. One landing.
    /// 2. **The timeout fires DURING the gap** (only possible if a test
    ///    shrinks the timeout window below the gap window; in production the
    ///    gap, 500ms, is always shorter than the timeout, 1.5s). The timeout
    ///    task calls `landDeferredDeviceDiffNow` directly with its own
    ///    captured token, which still matches (nothing has landed yet): it
    ///    lands, increments the token, and cancels the still-pending gap
    ///    task. When the gap task's sleep later completes, its `Task.isCancelled`
    ///    check is true and it never reaches `landDeferredDeviceDiffNow` at
    ///    all; even if it somehow did, `shouldLandDeferredDiff` would see the
    ///    now-stale token and back out. One landing either way.
    /// 3. **A new device diff is deferred during the gap** (a fresh device
    ///    settle episode starts before the gap finishes). `deferDeviceDiff`
    ///    increments the token and cancels both the old timeout task AND
    ///    this old gap task. The old gap task never lands the superseded
    ///    diff; the NEW diff gets its own timeout/gap treatment from here on.
    ///    Nothing is orphaned: the new diff is exactly as pending as if it
    ///    had arrived with no gap in flight at all.
    /// 4. **A second `reconcileChargers` call lands while a gap from the
    ///    first is still pending** (two charger settles close together,
    ///    unusual but not impossible). Since nothing was deferred a second
    ///    time in between, `deferredDeviceDiffDevices` still holds the SAME
    ///    devices and the token is unchanged, so this call schedules a
    ///    SECOND gap task. Two more Codex findings live here (see property 5
    ///    below and `deferredDeviceDiffPresentationGapGeneration`'s doc
    ///    comment): the first gap task IS now explicitly cancelled before the
    ///    second is scheduled, and each gap task carries its own generation,
    ///    checked before it does ANYTHING (not just before landing). So the
    ///    first task never reaches its body at all (`Task.isCancelled`), and
    ///    even if it somehow did, the generation check would still stop it.
    ///    Only the second (newest) gap task can ever land this diff. Still
    ///    exactly one landing, and now the NEWER gap deterministically wins,
    ///    not "whichever fires first".
    /// 5. **A second `reconcileChargers` call posts NOTHING while a gap from
    ///    a FIRST (which posted real content) is still pending** (Codex
    ///    review). This call's own `afterChargerPost` is false, so on its
    ///    own `deferredDiffLanding` would say `.immediate` -- but running
    ///    that immediately would land the diff right next to THIS call's
    ///    return, defeating the gap the first call is still waiting out (the
    ///    two charger posts and the device post would again cluster).
    ///    `isPresentationGapPending` is the guard: while a gap is in flight,
    ///    `.immediate` yields to it instead of landing early. Belt-and-braces
    ///    only: `reconcileChargers`'s 1.5s trailing debounce means a second
    ///    reconcile this close to the first (the gap is 500ms) cannot happen
    ///    live, but the invariant shouldn't rest on that timing coincidence.
    func landDeferredDeviceDiff(token: Int, afterChargerPost: Bool) {
        guard deferredDeviceDiffDevices != nil else { return }
        switch Self.deferredDiffLanding(reconcilePostedChargerContent: afterChargerPost) {
        case .immediate:
            guard !isPresentationGapPending else { return }
            landDeferredDeviceDiffNow(token: token)
        case .afterPresentationGap:
            // Cancel any outgoing gap task before scheduling a new one (not
            // just overwriting the property), and give this one its own
            // generation so it can tell later whether it's still the live
            // gap. Both guards are checked together below, after the sleep:
            // see `deferredDeviceDiffPresentationGapGeneration`'s doc comment
            // for why this task must confirm it's still current before
            // touching `isPresentationGapPending` OR landing, not just before
            // landing.
            deferredDeviceDiffPresentationGapTask?.cancel()
            deferredDeviceDiffPresentationGapGeneration += 1
            let gapGeneration = deferredDeviceDiffPresentationGapGeneration
            isPresentationGapPending = true
            deferredDeviceDiffPresentationGapTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: self?.deferredDeviceDiffPresentationGapWindow ?? .milliseconds(500))
                guard !Task.isCancelled, let self,
                      gapGeneration == self.deferredDeviceDiffPresentationGapGeneration
                else { return }
                self.isPresentationGapPending = false
                self.landDeferredDeviceDiffNow(token: token)
            }
        }
    }

    /// The single place a deferred device diff actually runs, reached from
    /// three places: directly from `landDeferredDeviceDiff(token:afterChargerPost:)`'s
    /// `.immediate` case, after the presentation gap it schedules, or after
    /// `deferDeviceDiff`'s own timeout. `shouldLandDeferredDiff` is the guard
    /// that keeps only the first of those to actually arrive from doing
    /// anything; see the interleaving walk-through above.
    private func landDeferredDeviceDiffNow(token: Int) {
        guard let devices = deferredDeviceDiffDevices,
              Self.shouldLandDeferredDiff(token: token, liveToken: deferredDeviceDiffToken)
        else { return }
        deferredDeviceDiffToken += 1
        deferredDeviceDiffDevices = nil
        deferredDeviceDiffTimeoutTask?.cancel()
        deferredDeviceDiffPresentationGapTask?.cancel()
        deferredDeviceDiffPresentationGapGeneration += 1
        // Defensive, not load-bearing on the timeout/immediate paths (which
        // never set this true): once ANY path actually lands the diff, no
        // gap should be treated as still pending for it.
        isPresentationGapPending = false
        diffDevices(devices)
    }

    /// Pure guard behind the "lands exactly once" property: a landing
    /// attempt may proceed only while its captured `token` still matches the
    /// live one. `landDeferredDeviceDiffNow` invalidates the live token (by
    /// incrementing it) as the very first thing it does after this check
    /// passes, before running the diff, so a second attempt with the same
    /// captured token always sees a stale value and backs out.
    nonisolated static func shouldLandDeferredDiff(token: Int, liveToken: Int) -> Bool {
        token == liveToken
    }

    private func diffDevices(_ current: [USBDevice]) {
        guard didPrimeBaseline else { return }

        let previousSnapshots = Array(knownDevices.values)
        let currentSnapshots = current.map(snapshot(for:))
        knownDevices = Dictionary(
            currentSnapshots.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        guard AppSettings.shared.notifyOnChanges else { return }

        let (addedGroups, removedGroups) = USBDeviceChangeGrouper.diff(
            previous: previousSnapshots,
            current: currentSnapshots
        )

        // Diagnostic: reconstruct the same reconnect-gate check
        // `deviceNotificationContents` runs below, so the log line reflects
        // what actually decides "Reconnected" vs "Disconnected"+"Connected".
        let reconnectGateFired = removedGroups.count == 1 && addedGroups.count == 1
            && Self.isReconnectPair(removed: removedGroups[0], added: addedGroups[0])
        Self.log.info("diffDevices: addedGroups=\(addedGroups.count, privacy: .public) removedGroups=\(removedGroups.count, privacy: .public) addedRoots=\(addedGroups.map(\.rootName).joined(separator: ", "), privacy: .public) removedRoots=\(removedGroups.map(\.rootName).joined(separator: ", "), privacy: .public) reconnectGateFired=\(reconnectGateFired, privacy: .public)")

        // Recover the full USBDevice for the speed/vendor body of a
        // single-member group by identity (rootID), not by name: two hubs of
        // the same model report the same product name, so name matching
        // could pick the wrong one.
        let currentByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let contents = Self.deviceNotificationContents(removedGroups: removedGroups, addedGroups: addedGroups) { rootID in
            currentByID[rootID].map { "\($0.speedLabel)\($0.vendorName.map { " · \($0)" } ?? "")" }
        }
        for content in contents {
            postNotification(category: .device, title: content.title, body: content.body)
        }
    }

    /// Decides the full batch of notification content for one settled device
    /// diff: the reconnect gate first, then (when it doesn't fire) the usual
    /// removed-then-added composition. Pure and separate from `diffDevices`
    /// so the GATE ITSELF, not just its two halves, is unit-testable without
    /// `UNUserNotificationCenter`.
    ///
    /// A device can disconnect and re-enumerate under a new entryID within
    /// one settle window (e.g. a hub power-cycling), so the same settled
    /// diff can hold both a removal and an addition for what was physically
    /// one event. Both post under the shared "device-event" identifier
    /// (issue #567), so the second post replaces the first in Notification
    /// Centre: only the LATEST post is ever shown, not both. Removed-before-
    /// added ordering means a device that reconnects within the window
    /// leaves "Connected" standing (its true current state); a device that
    /// only disconnects leaves "Disconnected" standing because there's no
    /// later add to replace it.
    ///
    /// A narrow subset of that "reconnects within the window" case gets its
    /// own wording: exactly one removed group and one added group, matching
    /// by physical port. That flap deserves to say "Reconnected" rather than
    /// silently reading as a fresh "Connected", since to the user it looked
    /// like a fault, not a first-time plug-in. Every other shape (multiple
    /// groups, no match, adds only, removes only) keeps the removed-then-
    /// added composition below untouched.
    nonisolated static func deviceNotificationContents(
        removedGroups: [USBDeviceChangeGrouper.ChangeGroup],
        addedGroups: [USBDeviceChangeGrouper.ChangeGroup],
        singleDeviceBody: (UInt64) -> String?
    ) -> [NotificationContent] {
        if let removed = removedGroups.first, removedGroups.count == 1,
           let added = addedGroups.first, addedGroups.count == 1,
           isReconnectPair(removed: removed, added: added) {
            return [reconnectedNotificationContent(for: added, singleDeviceBody: singleDeviceBody)]
        }
        return removedNotificationContents(groups: removedGroups)
            + addedNotificationContents(groups: addedGroups, singleDeviceBody: singleDeviceBody)
    }

    /// True when a removed group and an added group are almost certainly the
    /// same physical device re-enumerating rather than a genuine disconnect
    /// paired with an unrelated connect: same physical port path
    /// (`rootLocationID`, which survives a re-enumeration even though the
    /// entryID doesn't) AND the same product name. A different name at the
    /// same port (a device swapped on that port within the settle window) is
    /// deliberately NOT a reconnect: it falls through to today's separate
    /// "Disconnected" / "Connected" pair instead.
    nonisolated static func isReconnectPair(
        removed: USBDeviceChangeGrouper.ChangeGroup,
        added: USBDeviceChangeGrouper.ChangeGroup
    ) -> Bool {
        removed.rootLocationID == added.rootLocationID && removed.rootName == added.rootName
    }

    /// Content for the single "Reconnected: <name>" notification posted for
    /// a matched drop-and-return pair. Same body treatment as
    /// `addedNotificationContents`'s single-group case (member names, or the
    /// speed/vendor line for a memberless group), because the added group's
    /// content is what's true of the device right now.
    nonisolated static func reconnectedNotificationContent(
        for added: USBDeviceChangeGrouper.ChangeGroup,
        singleDeviceBody: (UInt64) -> String?
    ) -> NotificationContent {
        let title = String(localized: "Reconnected: \(added.rootName)", bundle: _appLocalizedBundle)
        let body = added.memberNames.isEmpty
            ? (singleDeviceBody(added.rootID) ?? "")
            : added.memberNames.joined(separator: "\n")
        return NotificationContent(title: title, body: body)
    }

    /// A single notification's title and body, decided independently of
    /// `UNUserNotificationCenter` so the merge decision below is testable
    /// without posting anything. See issue #556.
    struct NotificationContent: Equatable {
        let title: String
        let body: String
    }

    /// Decides what to post for one settled batch of added groups. A dock
    /// with several subtrees (main USB3 hub, USB2 companion hubs, PD device)
    /// arrives as multiple groups in a single settle window; posting one
    /// `UNUserNotificationCenter.add` per group produced 2-3 simultaneous
    /// banners with only the last one visible, so most of the devices never
    /// showed up as "connected" even though they were posted. Mirrors
    /// `removedNotificationContents`'s merge so >1 group becomes ONE
    /// notification, same as a disconnect. See issue #556.
    nonisolated static func addedNotificationContents(
        groups: [USBDeviceChangeGrouper.ChangeGroup],
        singleDeviceBody: (UInt64) -> String?
    ) -> [NotificationContent] {
        if groups.count == 1, let group = groups.first {
            let title = String(localized: "Connected: \(group.rootName)", bundle: _appLocalizedBundle)
            let body = group.memberNames.isEmpty
                ? (singleDeviceBody(group.rootID) ?? "")
                : group.memberNames.joined(separator: "\n")
            return [NotificationContent(title: title, body: body)]
        } else if groups.count > 1 {
            let allNames = groups.flatMap { [$0.rootName] + $0.memberNames }
            return [NotificationContent(
                title: String(localized: "USB devices connected", bundle: _appLocalizedBundle),
                body: allNames.joined(separator: "\n")
            )]
        }
        return []
    }

    /// Decides what to post for one settled batch of removed groups. Mirrors
    /// `addedNotificationContents`'s merge (>1 group becomes ONE "USB
    /// devices disconnected" notification), extracted so
    /// `deviceNotificationContents` can compose it with the reconnect gate.
    /// See issue #556.
    nonisolated static func removedNotificationContents(
        groups: [USBDeviceChangeGrouper.ChangeGroup]
    ) -> [NotificationContent] {
        if groups.count == 1, let group = groups.first {
            let title = String(localized: "Disconnected: \(group.rootName)", bundle: _appLocalizedBundle)
            return [NotificationContent(title: title, body: group.memberNames.joined(separator: "\n"))]
        } else if groups.count > 1 {
            let allNames = groups.flatMap { [$0.rootName] + $0.memberNames }
            return [NotificationContent(
                title: String(localized: "USB devices disconnected", bundle: _appLocalizedBundle),
                body: allNames.joined(separator: "\n")
            )]
        }
        return []
    }

    private func snapshot(for device: USBDevice) -> USBDeviceChangeGrouper.Snapshot {
        USBDeviceChangeGrouper.Snapshot(
            id: device.id,
            locationID: device.locationID,
            name: device.productName ?? String(localized: "USB device", bundle: _appLocalizedBundle)
        )
    }

    private func diffSources(_ current: [PowerSource]) {
        guard didPrimeBaseline else { return }
        // Trailing-edge debounce: keep resetting the timer while the set is
        // still changing, then reconcile once it settles. This absorbs the
        // flap so a single connect produces a single notification.
        chargerSettleTask?.cancel()
        isChargerSettlePending = true
        chargerSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.chargerSettleWindow ?? .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            self.isChargerSettlePending = false
            self.reconcileChargers()
        }
    }

    /// Decides what to post for one settled charger reconcile. With the
    /// shared "charger-event" identifier (issue #567), posting one
    /// notification per changed port meant each later post replaced the
    /// one before it under Notification Centre's own rules, so 2+ charger
    /// changes in a single settle window silently lost all but the last.
    /// Mirrors the device path's merge: every added charger becomes ONE
    /// "Charger connected" post (labels joined by newline), every removed
    /// charger becomes ONE "Charger disconnected" post, same as before for
    /// the single-charger case. Removed comes first, added second, mirroring
    /// `diffDevices`'s ordering so the same "latest post wins" reasoning
    /// applies if a charger both drops and reconnects within the window.
    nonisolated static func chargerNotificationContents(
        addedLabels: [String],
        removedLabels: [String]
    ) -> [NotificationContent] {
        var contents: [NotificationContent] = []
        if !removedLabels.isEmpty {
            contents.append(NotificationContent(
                title: String(localized: "Charger disconnected", bundle: _appLocalizedBundle),
                body: removedLabels.joined(separator: "\n")
            ))
        }
        if !addedLabels.isEmpty {
            contents.append(NotificationContent(
                title: String(localized: "Charger connected", bundle: _appLocalizedBundle),
                body: addedLabels.joined(separator: "\n")
            ))
        }
        return contents
    }

    /// Turns a set of changed charger port keys into their labels, sorted by
    /// the stable port key rather than left in Set iteration order. Set and
    /// Dictionary don't guarantee a stable order between runs, so without
    /// this the merged notification's line order would flap for no reason a
    /// user could see. Pure and separate from `reconcileChargers` so the
    /// ordering is unit-testable without `WatcherHub`.
    nonisolated static func sortedChargerLabels(for portKeys: some Sequence<String>, labels: [String: String]) -> [String] {
        portKeys.sorted().compactMap { labels[$0] }
    }

    /// Reconcile the current charger ports against the last-notified set, after
    /// the published list has settled. Notify once per charger (port), not once
    /// per power-source entry: a single charger advertises several entries on
    /// the same port (USB-PD, Brick ID, TypeC). See issue #227 follow-up.
    func reconcileChargers() {
        // Lands any device diff waiting on this reconcile (stack-order fix),
        // whichever exit path is taken below, and AFTER every charger post
        // below has already gone out, so the device post that follows always
        // lands on top. `chargerPostedContent` starts false and is flipped
        // just before the posting loop runs; the closure reads whatever
        // value it holds at the moment this function actually returns, not
        // the value at the point `defer` was written, which is how it sees
        // "did THIS call post anything" even though the decision is made
        // deep inside this function. A no-op when nothing is deferred, and
        // immediate (no presentation gap) when nothing was posted: see
        // `landDeferredDeviceDiff(token:afterChargerPost:)`.
        var chargerPostedContent = false
        defer { landDeferredDeviceDiff(token: deferredDeviceDiffToken, afterChargerPost: chargerPostedContent) }

        let current = WatcherHub.shared.powerWatcher.sources
        // Track chargers by canonicalJoinKey (HPM UUID when present, portKey
        // fallback) so add/remove detection keys on stable port identity.
        let currentLabels = chargerLabels(for: current)
        let addedPortKeys = Set(currentLabels.keys).subtracting(knownChargerLabels.keys)
        let removedPortKeys = knownChargerLabels.keys.filter { !currentLabels.keys.contains($0) }
        let previousLabels = knownChargerLabels
        knownChargerLabels = currentLabels

        Self.log.info("reconcileChargers: added=\(addedPortKeys.count, privacy: .public) removed=\(removedPortKeys.count, privacy: .public)")

        guard AppSettings.shared.notifyOnChanges else { return }

        // Every added port key already has a label in currentLabels (it was
        // built from the same set); this fallback only guards a mismatch
        // between the two that should never happen.
        var addedLabelsByPortKey = currentLabels
        for portKey in addedPortKeys where addedLabelsByPortKey[portKey] == nil {
            addedLabelsByPortKey[portKey] = String(localized: "PD source", bundle: _appLocalizedBundle)
        }
        let addedLabels = Self.sortedChargerLabels(for: addedPortKeys, labels: addedLabelsByPortKey)
        let removedLabels = Self.sortedChargerLabels(for: removedPortKeys, labels: previousLabels)
        let contents = Self.chargerNotificationContents(addedLabels: addedLabels, removedLabels: removedLabels)
        chargerPostedContent = !contents.isEmpty
        for content in contents {
            postNotification(category: .charger, title: content.title, body: content.body)
        }
    }

    /// The current negotiated-wattage label per charger port, used both to
    /// prime the baseline and to recall what a charger was delivering once it
    /// disconnects (its `PowerSource` is already gone by then).
    private func chargerLabels(for sources: [PowerSource]) -> [String: String] {
        let portKeys = Set(sources.map(\.canonicalJoinKey))
        return Dictionary(uniqueKeysWithValues: portKeys.map { portKey -> (String, String) in
            let portSources = sources.filter { $0.canonicalJoinKey == portKey }
            let preferred = PowerSource.preferredChargingSource(in: portSources) ?? portSources.first
            let label = preferred?.winning.map { String(localized: "\($0.wattsLabel) negotiated", bundle: _appLocalizedBundle) }
                ?? String(localized: "PD source", bundle: _appLocalizedBundle)
            return (portKey, label)
        })
    }

    /// Where a notification actually gets posted. Injected (default is the
    /// real `UNUserNotificationCenter` flow) so a test can drive
    /// `postNotification` itself, the real call site, rather than only the
    /// pure content-decision functions above it. Mirrors
    /// `UpdateChecker.notificationSink`: without a seam like this, a wiring
    /// test can only prove the pure rules agree with each other, never that
    /// the plumbing between them (e.g. `reconcileChargers`'s `defer`
    /// actually landing a parked device diff) is still wired up. That gap
    /// was proven concretely: deleting the `defer` line left every existing
    /// `NotificationManager` test green.
    var notificationSink: (NotificationCategory, NotificationContent) -> Void = { category, content in
        let mutableContent = UNMutableNotificationContent()
        mutableContent.title = content.title
        if !content.body.isEmpty { mutableContent.body = content.body }
        mutableContent.sound = nil

        let identifier = NotificationManager.notificationIdentifier(for: category)
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

    private func postNotification(category: NotificationCategory, title: String, body: String) {
        notificationSink(category, NotificationContent(title: title, body: body))
    }
}

