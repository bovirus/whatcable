import Foundation
import Combine
import UserNotifications
import os.log
import WhatCableCore
import WhatCableNotifications
import WhatCableDarwinBackend

/// Posts user notifications when USB-C cables / power sources connect or
/// disconnect, gated by the user's `AppSettings.notifyOnChanges` preference.
@MainActor
final class NotificationManager {
    // MARK: - Ordering mechanism, at a glance
    //
    // Two independent settle tasks debounce the two raw event streams before
    // anything gets posted: `deviceSettleTask` (`scheduleDeviceDiff`) and
    // `chargerSettleTask` (`diffSources`). Each waits for its own stream to
    // stop flapping, then runs its diff/reconcile once.
    //
    // A device diff that must not post ahead of a same-episode charger post
    // gets PARKED rather than posted immediately. The parking state is:
    //   - `deferredDeviceDiffDevices`: the one slot holding the parked diff.
    //   - `deferredDeviceDiffToken`: identifies which parked diff is live, so
    //     a stale landing attempt can tell it's been superseded and back out.
    //   - `deferredDeviceDiffPresentationGapGeneration`: same idea, scoped to
    //     just the current presentation-gap task, so a cancelled gap task
    //     can't mutate state even if it somehow still runs.
    //   - `isPresentationGapPending`: true only while a gap task is the
    //     scheduled lander, so a second reconcile landing mid-gap yields to
    //     it instead of racing it.
    //   - `deferredDeviceDiffPresentationGapTask` / `Window`: the deliberate
    //     delay that lets both banners actually present on screen.
    //   - `deferredDeviceDiffDeadlineTask` / `Window`: the absolute,
    //     non-resetting backstop that bounds the total wait no matter how
    //     many times the gap above gets re-scheduled.
    //   - `lastChargerPostTime`: when a charger post last actually went out,
    //     so a device diff that finds no charger settle CURRENTLY pending can
    //     still tell "a charger post just landed" from "nothing to wait for".
    //
    // A diff gets parked from exactly three entry points: `deferDeviceDiff`
    // (device settle found a charger settle pending), `parkAndDelayDevicePost`
    // (device settle found no charger settle pending, but a charger post went
    // out moments ago), and `runNowOrDelayForRecentChargerPost` (the router
    // that decides between an immediate post and the `parkAndDelayDevicePost`
    // path above).
    //
    // A parked diff LANDS through exactly one of three paths, all converging
    // on `landDeferredDeviceDiffNow`: the synchronous `.immediate` case
    // inside `landDeferredDeviceDiff` (the most common case: a reconcile that
    // posted no charger content of its own), the presentation-gap task
    // (`scheduleGapLanding`), or the absolute deadline task
    // (`scheduleAbsoluteDeadline`). A parked diff can also be DISCARDED
    // rather than landed, if a newer diff supersedes it before any of those
    // three fires (`deferDeviceDiff` / `supersedeAnyParkedDiff` invalidating
    // it in favour of the new one; the superseded diff's own devices are
    // simply dropped, never posted). `landDeferredDeviceDiff(token:
    // afterChargerPost:)`'s doc comment walks through every interleaving of
    // landing and discarding in detail; start there for the mechanics.
    //
    // Why TWO windows, not one: the settle windows (`chargerSettleWindow`,
    // `deviceSettleWindow`) exist to group several raw IOKit publishes from
    // one physical event into a single episode. The presentation gap
    // (`deferredDeviceDiffPresentationGapWindow`) is a different problem:
    // giving macOS enough real wall-clock time between two posts that both
    // banners actually render, not just reach Notification Centre's list.
    // The absolute deadline is derived from both, because the worst case has
    // to cover one full charger settle (in case the diff was parked before
    // the charger even started reconciling) plus one full presentation gap
    // (in case the charger reconciles right at the last moment).
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

    /// `NotificationCategory` and `notificationIdentifier(for:)` moved to
    /// `WhatCableNotifications` (pure, no `UNUserNotificationCenter`
    /// dependency). Typealiased here so every existing call site
    /// (`NotificationManager.NotificationCategory`, `.device`, `.charger`)
    /// keeps compiling unchanged.
    typealias NotificationCategory = WhatCableNotifications.NotificationCategory

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
    /// The ABSOLUTE, NON-RESETTING backstop for a parked diff. Started ONCE,
    /// at park time (`scheduleAbsoluteDeadline`, called from `deferDeviceDiff`
    /// and `parkAndDelayDevicePost`), and never touched again except by an
    /// actual landing or a NEWER parked diff superseding this one. See
    /// `deferredDeviceDiffDeadlineWindow`'s doc comment for why this has to
    /// be non-resetting.
    private var deferredDeviceDiffDeadlineTask: Task<Void, Never>?
    /// ONE task, scheduled at park time, that nothing resets. Gap
    /// re-schedules never touch it (`scheduleGapLanding` doesn't reference
    /// it at all); only an actual landing, a fresh `deferDeviceDiff` /
    /// `parkAndDelayDevicePost` call (a NEWER parked diff superseding this
    /// one, which cancels this deadline and starts its own), or
    /// `supersedeAnyParkedDiff` (the zero-delay `.runNow` path cancelling
    /// this one outright, with no replacement parked) can stop it.
    /// Worst case, a device banner waits `deferredDeviceDiffPresentationGapWindow`
    /// + `chargerSettleWindow` from the moment it was parked: one full
    /// charger debounce (in case the charger hadn't even reconciled yet when
    /// the diff was parked) plus one full presentation gap (in case the
    /// charger reconciles right at the last moment and needs the full gap to
    /// present). Derived from those two windows at `init()` time (3.5s at
    /// their defaults), not a fresh literal, so it moves automatically if
    /// either window changes. `var`, like the other windows, so a test can
    /// shrink it.
    ///
    /// Starvation fix (both reviewers, on an earlier design this replaces):
    /// that design cancelled the parked diff's backstop the moment a
    /// presentation gap took over landing, on the theory that the gap is
    /// then the sole scheduled lander. That left the gap phase with NO upper
    /// bound: every charger post while a diff sat parked re-scheduled a
    /// fresh `deferredDeviceDiffPresentationGapWindow`-long gap
    /// (`scheduleGapLanding`), and sustained PD flapping (real; see
    /// `chargerSettleWindow`'s own doc comment) could delay the device
    /// banner indefinitely.
    var deferredDeviceDiffDeadlineWindow: Duration
    /// Re-scheduled on every `scheduleGapLanding` call (unlike
    /// `deferredDeviceDiffDeadlineTask`, which is scheduled once at park
    /// time and never re-scheduled); both are cancelled on an actual
    /// landing, see `landDeferredDeviceDiffNow`.
    ///
    /// Presentation-gap fix (owner, live verification): when a parked device
    /// diff landed synchronously inside `reconcileChargers`'s `defer`, the
    /// charger post and the device post both reached
    /// `UNUserNotificationCenter` in the same millisecond. macOS presents
    /// only the LAST of two simultaneous banners, so "Charger disconnected"
    /// never showed on screen (it only reached Notification Centre's list):
    /// the fix that made ordering correct accidentally made the older of the
    /// two invisible. The old code's accidental ~300ms gap between the two
    /// posts is what used to let both banners present, so a deliberate delay
    /// restores that presentation gap on purpose.
    private var deferredDeviceDiffPresentationGapTask: Task<Void, Never>?
    /// True from the moment `landDeferredDeviceDiff` schedules a presentation
    /// gap until that gap actually lands the diff (or is cancelled by a
    /// fresh deferral). Guards a specific interleaving Codex review raised:
    /// a SECOND `reconcileChargers` call that lands while the gap from a
    /// FIRST is still pending, and posts no charger content of its own,
    /// would otherwise take the `.immediate` branch below and land the diff
    /// right there, defeating the gap the first call scheduled. This guard
    /// is load-bearing, not precautionary: at the current 2s gap (see
    /// `deferredDeviceDiffPresentationGapWindow`'s doc comment), 2s
    /// comfortably EXCEEDS the 1.5s charger debounce, so a second charger
    /// settle completing while the first's gap is still pending is a real
    /// production interleaving, not just a timing coincidence.
    ///
    /// Originally reasoned unreachable live at the 500ms gap
    /// (`reconcileChargers` is trailing-debounced to `chargerSettleWindow`,
    /// 1.5s, comfortably longer than a 500ms gap, so two reconciles for the
    /// same charger couldn't land inside one gap window) and kept only as
    /// belt-and-braces. That reasoning stopped holding once the gap was
    /// raised to 2s.
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
    /// `var`, mirroring `deferredDeviceDiffDeadlineWindow`, so a test can
    /// shrink it to a few tens of milliseconds. Production stays at 2s:
    /// 500ms was tried first and measured insufficient on macOS 26 in live
    /// testing (owner, scratch build) -- the device banner still visually
    /// covered the charger banner before it had time to present. 2s is the
    /// live-verified value, and it also matches the plug-in direction's own
    /// natural spacing between the two settle timers, so it doesn't read as
    /// an artificially long pause.
    var deferredDeviceDiffPresentationGapWindow: Duration = .milliseconds(2000)
    /// Recorded here, in `postNotification`, whenever a CHARGER post
    /// actually goes out, so the `.runNow` path (see
    /// `runNowOrDelayForRecentChargerPost`) can tell "a charger post just
    /// went out and hasn't had time to present yet" from "nothing charger-
    /// related happened recently". `nil` until the first charger post of the
    /// app's lifetime; `devicePostDelay` treats `nil` the same as "outside
    /// the window" (nothing to delay for).
    /// Not `private`: a wiring test resets this to `nil` before exercising
    /// `runNowOrDelayForRecentChargerPost`, since `NotificationManager.shared`
    /// is a process-wide singleton and an EARLIER test's `reconcileChargers()`
    /// call can otherwise leave a recent-enough timestamp here to make a
    /// later, unrelated test see a non-zero `devicePostDelay` it didn't ask
    /// for.
    ///
    /// Both-orders fix (owner, live verification): the gap fix above only
    /// covers the DEVICE-fires-first order (device settle finds
    /// `isChargerSettlePending` true, defers, and the charger reconcile lands
    /// it later). Logs showed the opposite order happens too: the CHARGER
    /// settle fires first and posts, and by the time the device settle fires
    /// a moment later, `isChargerSettlePending` already reads false, so
    /// `deviceDiffDisposition` says `.runNow` and the device post goes out
    /// ~1ms after the charger post, same-millisecond problem again, charger
    /// banner suppressed. This property is the fix that closes that gap.
    var lastChargerPostTime: ContinuousClock.Instant?
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
    ///
    /// Deliberately `private let`, not `var` like the other windows above:
    /// wiring tests drive around this window's real 1.5s length (waiting it
    /// out, or triggering `reconcileChargers()` directly instead of going
    /// through `diffSources`'s debounce) rather than needing to shrink it.
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
    /// `var`, not `let` (like `deferredDeviceDiffDeadlineWindow` and
    /// `deferredDeviceDiffPresentationGapWindow`), purely so a test can
    /// shrink it and exercise `scheduleDeviceDiff` itself, the actual
    /// production call site, rather than only the helpers it calls
    /// (`runNowOrDelayForRecentChargerPost` etc.) driven directly.
    var deviceSettleWindow: Duration = .milliseconds(1500)

    private init() {
        // Derived, not a fresh literal: see `deferredDeviceDiffDeadlineWindow`'s
        // doc comment for why the deadline is presentationGap + chargerSettleWindow.
        // Computed once here rather than as a property-declaration default so
        // it tracks whatever the other two windows' OWN defaults are (2s and
        // 1.5s today), instead of a hand-copied 3.5s literal going stale if
        // either one changes. Still a plain `var` afterward: a test can
        // overwrite it directly, same as it always could.
        deferredDeviceDiffDeadlineWindow = deferredDeviceDiffPresentationGapWindow + chargerSettleWindow
    }

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
    ///
    /// Not `private`: a wiring test calls this directly (with
    /// `deviceSettleWindow` shrunk) to drive the ACTUAL `.runNow` call site
    /// end to end, rather than only `runNowOrDelayForRecentChargerPost`
    /// itself. Codex review: a test that only drives the helper directly
    /// would stay green even if this call site regressed back to a bare
    /// `diffDevices(devices)` call, which is exactly the bug this exists to
    /// catch.
    func scheduleDeviceDiff() {
        deviceSettleTask?.cancel()
        deviceSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.deviceSettleWindow ?? .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            let devices = WatcherHub.shared.deviceWatcher.devices
            switch NotificationDecision.deviceDiffDisposition(chargerSettlePending: self.isChargerSettlePending) {
            case .runNow:
                // Both-orders fix: `isChargerSettlePending` being false here
                // only means no charger settle is CURRENTLY pending; it says
                // nothing about whether one just landed and posted a moment
                // ago. `runNowOrDelayForRecentChargerPost` is what actually
                // decides immediate vs delayed for this case.
                self.runNowOrDelayForRecentChargerPost(devices)
            case .deferUntilChargerReconcile:
                self.deferDeviceDiff(devices)
            }
        }
    }

    /// `DeviceDiffDisposition` and `deviceDiffDisposition(chargerSettlePending:)`
    /// (the stack-order fix's pure ordering rule) moved to
    /// `WhatCableNotifications.NotificationDecision`. See that type's doc
    /// comment for the full stack-order reasoning.
    typealias DeviceDiffDisposition = NotificationDecision.DeviceDiffDisposition

    /// Park a settled device diff until the pending charger reconcile lands
    /// it (see `reconcileChargers`'s `defer`) or `deferredDeviceDiffDeadlineTask`
    /// bounds the wait. Superseding an earlier still-waiting diff (rather
    /// than composing with it) mirrors `deviceSettleTask`/`chargerSettleTask`:
    /// only the latest settled state matters. Cancelling BOTH the deadline
    /// task and the presentation-gap task here (not just the deadline) is
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
    /// can delay that device notification by up to the full deadline window
    /// (`deferredDeviceDiffDeadlineWindow`, 3.5s in production), because
    /// `isChargerSettlePending` can't distinguish "the same physical episode"
    /// from "an unrelated charger event that happens to overlap". That delay
    /// is bounded by the deadline below and never drops the notification, so
    /// it's accepted for the sake of getting the ordering right on the
    /// common case (the same episode) this fix targets.
    func deferDeviceDiff(_ devices: [USBDevice]) {
        deferredDeviceDiffToken += 1
        let token = deferredDeviceDiffToken
        deferredDeviceDiffDevices = devices

        deferredDeviceDiffPresentationGapTask?.cancel()
        deferredDeviceDiffPresentationGapGeneration += 1
        isPresentationGapPending = false
        scheduleAbsoluteDeadline(token: token)
    }

    /// Schedules the ABSOLUTE, NON-RESETTING deadline for the CURRENTLY
    /// parked diff (`token`). Called ONCE, at park time, by both parking
    /// entry points (`deferDeviceDiff` and `parkAndDelayDevicePost`).
    /// Nothing after this point re-schedules it: not a gap re-schedule (an
    /// unrelated or repeated charger reconcile scheduling a fresh
    /// presentation gap via `scheduleGapLanding`), only an actual landing
    /// (which cancels it, see `landDeferredDeviceDiffNow`) or a NEWER parked
    /// diff superseding this one (which cancels this deadline here, via the
    /// `?.cancel()` below, before scheduling its own). See
    /// `deferredDeviceDiffDeadlineWindow`'s doc comment for the starvation
    /// bug this design fixes and the reasoning behind the duration.
    private func scheduleAbsoluteDeadline(token: Int) {
        deferredDeviceDiffDeadlineTask?.cancel()
        deferredDeviceDiffDeadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.deferredDeviceDiffDeadlineWindow ?? .milliseconds(3500))
            guard !Task.isCancelled, let self else { return }
            self.landDeferredDeviceDiffNow(token: token)
        }
    }

    /// `DeferredDiffLanding` and `deferredDiffLanding(reconcilePostedChargerContent:)`
    /// moved to `WhatCableNotifications.NotificationDecision`. See that
    /// type's doc comment for the presentation-gap reasoning.
    typealias DeferredDiffLanding = NotificationDecision.DeferredDiffLanding

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
    ///    cancels the (now finished) deadline task. One landing.
    /// 2. **The absolute deadline fires while a gap is ALSO pending** (the
    ///    deadline's `deferredDeviceDiffPresentationGapWindow` +
    ///    `chargerSettleWindow` window elapsed before the currently-pending
    ///    gap's own, shorter window did -- possible when a charger reconcile
    ///    took a while to arrive after park time, or when the gap has been
    ///    re-scheduled enough times by repeated reconciles that its own
    ///    countdown, restarted from the LATEST reconcile, is still running
    ///    past the deadline's absolute cutoff). The deadline task calls
    ///    `landDeferredDeviceDiffNow` directly with its own captured token,
    ///    which still matches (nothing has landed yet): it lands, increments
    ///    the token, and cancels the still-pending gap task. When the gap
    ///    task's sleep later completes, its `Task.isCancelled` check is true
    ///    and it never reaches `landDeferredDeviceDiffNow` at all; even if it
    ///    somehow did, `shouldLandDeferredDiff` would see the now-stale token
    ///    and back out. One landing either way. This is the mechanism that
    ///    bounds the WORST case: an earlier design cancelled this deadline
    ///    the moment a gap took over, which meant sustained charger flapping
    ///    (real; see `chargerSettleWindow`'s own doc comment) could re-extend
    ///    the gap indefinitely and starve the device banner. `scheduleGapLanding`
    ///    now never touches the deadline task at all, in either direction:
    ///    not to cancel it, not to re-schedule it. See
    ///    `deferredDeviceDiffDeadlineWindow`'s doc comment for the full
    ///    starvation-fix reasoning.
    /// 3. **A new device diff is deferred during the gap** (a fresh device
    ///    settle episode starts before the gap finishes). `deferDeviceDiff`
    ///    increments the token and cancels both the old deadline task AND
    ///    this old gap task (via `scheduleAbsoluteDeadline`'s own
    ///    cancel-before-schedule and this function's cancel-before-schedule
    ///    respectively). The old gap task never lands the superseded diff;
    ///    the NEW diff gets its own deadline/gap treatment from here on.
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
    ///    `.immediate` yields to it instead of landing early. Was reasoned
    ///    belt-and-braces only at the 500ms gap (`reconcileChargers`'s 1.5s
    ///    trailing debounce meant a second reconcile that close to the first
    ///    couldn't happen live); at the current 2s gap (see
    ///    `deferredDeviceDiffPresentationGapWindow`'s doc comment) 2s exceeds
    ///    the 1.5s debounce, so this interleaving is now reachable in
    ///    production too, same reasoning as `isPresentationGapPending`'s own
    ///    doc comment. This guard earns its keep now; it was never just
    ///    theoretical hygiene.
    func landDeferredDeviceDiff(token: Int, afterChargerPost: Bool) {
        guard deferredDeviceDiffDevices != nil else { return }
        switch NotificationDecision.deferredDiffLanding(reconcilePostedChargerContent: afterChargerPost) {
        case .immediate:
            guard !isPresentationGapPending else { return }
            landDeferredDeviceDiffNow(token: token)
        case .afterPresentationGap:
            scheduleGapLanding(token: token, delay: deferredDeviceDiffPresentationGapWindow)
        }
    }

    /// Schedules a presentation-gap-guarded landing for the CURRENTLY parked
    /// diff (`deferredDeviceDiffDevices`, identified by `token`), waiting
    /// `delay` before running it. Cancels any outgoing GAP task before
    /// scheduling a new one (not just overwriting the property), and gives
    /// this one its own generation so it can tell later whether it's still
    /// the live gap; both guards are checked together after the sleep, not
    /// just the token, so a stale/superseded task can never touch
    /// `isPresentationGapPending` or land (see
    /// `deferredDeviceDiffPresentationGapGeneration`'s doc comment).
    ///
    /// Deliberately does NOT touch `deferredDeviceDiffDeadlineTask` in either
    /// direction: doesn't cancel it, doesn't re-schedule it. This function
    /// can run repeatedly for the SAME parked diff (a charger that keeps
    /// posting content re-extends the gap every time), and the deadline's
    /// entire job is to bound the total wait regardless of how many times
    /// that happens; a design that used to cancel the deadline here left the
    /// gap phase with no upper bound (see `deferredDeviceDiffDeadlineWindow`'s
    /// doc comment for the starvation bug that caused).
    ///
    /// Shared by two callers, which differ only in what `delay` they pass:
    /// `landDeferredDeviceDiff`'s `.afterPresentationGap` case (the full
    /// `deferredDeviceDiffPresentationGapWindow`, for a device diff that was
    /// deferred waiting on a charger reconcile) and
    /// `parkAndDelayDevicePost` (a REMAINDER, for a device diff that was
    /// never deferred at all but happens to be settling shortly after an
    /// unrelated charger post already went out). This is also the function
    /// that implements interleaving 4 (a second reconcile scheduling its own
    /// gap task while an earlier one is still pending): the cancel-then-
    /// generation-bump below is what lets only the newest gap task win.
    private func scheduleGapLanding(token: Int, delay: Duration) {
        deferredDeviceDiffPresentationGapTask?.cancel()
        deferredDeviceDiffPresentationGapGeneration += 1
        let gapGeneration = deferredDeviceDiffPresentationGapGeneration
        isPresentationGapPending = true
        deferredDeviceDiffPresentationGapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self,
                  gapGeneration == self.deferredDeviceDiffPresentationGapGeneration
            else { return }
            self.isPresentationGapPending = false
            self.landDeferredDeviceDiffNow(token: token)
        }
    }

    /// `devicePostDelay(elapsedSinceLastChargerPost:presentationGap:)` (the
    /// both-orders fix's pure arithmetic) moved to
    /// `WhatCableNotifications.NotificationDecision`. See that type's doc
    /// comment for the reasoning.

    /// Wall-clock time since `lastChargerPostTime`, or `nil` if no charger
    /// post has gone out yet this app launch. Kept separate from
    /// `devicePostDelay` so the pure arithmetic above needs no clock at all.
    private func elapsedSinceLastChargerPost() -> Duration? {
        lastChargerPostTime?.duration(to: ContinuousClock.now)
    }

    /// Entry point for `scheduleDeviceDiff`'s `.runNow` disposition: a device
    /// settle that found no charger settle CURRENTLY pending. That alone
    /// doesn't mean nothing charger-related happened recently (Codex-style
    /// finding from live logs: the charger settle can fire FIRST, post, and
    /// finish reconciling entirely before the device settle's own window
    /// elapses a moment later), so this consults `devicePostDelay` before
    /// deciding. Zero delay: post now, exactly as before this fix. Non-zero:
    /// park the diff and land it after the REMAINDER, reusing the identical
    /// cancel/token/generation-guarded machinery `deferDeviceDiff` /
    /// `scheduleGapLanding` already use, so this path's exactly-once and
    /// supersession guarantees are the SAME code, not a parallel copy.
    ///
    /// Interleaving worth walking through because it's new here: a device
    /// diff already parked by THIS function (waiting out a remainder) is
    /// still parked when ANOTHER device settle fires (e.g. a second device
    /// plugged in moments later). That new settle re-enters this same
    /// function with fresh `devices`. Whichever branch it takes,
    /// `supersedeAnyParkedDiff` (delay == 0) or `parkAndDelayDevicePost`
    /// (delay > 0, via `scheduleAbsoluteDeadline`'s and `scheduleGapLanding`'s
    /// own cancel-before-schedule) invalidates the FIRST parked diff before
    /// doing anything else, so the stale, now-superseded device list can
    /// never land later under a devices-episode's-mismatched token, and
    /// "only the latest settled device state matters" holds regardless of
    /// which path a device diff arrives through. Without this, a `.runNow`
    /// diff arriving with `delay == 0` while an OLDER diff was still parked
    /// from a PREVIOUS settle would post the fresh data immediately while
    /// leaving the old parked one to land later against an already-mutated
    /// `knownDevices` baseline, producing a wrong diff for it.
    func runNowOrDelayForRecentChargerPost(_ devices: [USBDevice]) {
        let delay = NotificationDecision.devicePostDelay(
            elapsedSinceLastChargerPost: elapsedSinceLastChargerPost(),
            presentationGap: deferredDeviceDiffPresentationGapWindow
        )
        if delay > .zero {
            parkAndDelayDevicePost(devices, delay: delay)
        } else {
            supersedeAnyParkedDiff()
            diffDevices(devices)
        }
    }

    /// Parks `devices` as a fresh episode (its own token), starts its
    /// absolute deadline (`scheduleAbsoluteDeadline`, same as
    /// `deferDeviceDiff`: this path is just as susceptible to sustained
    /// charger flapping re-extending its gap indefinitely, since
    /// `landDeferredDeviceDiff` doesn't care HOW a diff got parked before
    /// re-scheduling its gap), then schedules the gap-guarded landing after
    /// `delay`.
    private func parkAndDelayDevicePost(_ devices: [USBDevice], delay: Duration) {
        deferredDeviceDiffToken += 1
        let token = deferredDeviceDiffToken
        deferredDeviceDiffDevices = devices
        scheduleAbsoluteDeadline(token: token)
        scheduleGapLanding(token: token, delay: delay)
    }

    /// Invalidates any diff currently parked, from either path (the
    /// charger-pending deadline path or the presentation-gap path): cancels
    /// both scheduled tasks, bumps both the token and the gap generation so
    /// any of their still-in-flight continuations see a stale value and back
    /// out, and clears the pending-gap flag. Called before running a device
    /// diff immediately whenever an OLDER one might still be parked; see the
    /// interleaving walk-through on `runNowOrDelayForRecentChargerPost`. Same
    /// cancel-before-superseding shape as interleaving 3 on
    /// `landDeferredDeviceDiff(token:afterChargerPost:)` (a new parked diff
    /// invalidating an outgoing one), just reached from the `.runNow` router
    /// instead of `deferDeviceDiff`.
    private func supersedeAnyParkedDiff() {
        deferredDeviceDiffToken += 1
        deferredDeviceDiffDevices = nil
        deferredDeviceDiffDeadlineTask?.cancel()
        deferredDeviceDiffPresentationGapTask?.cancel()
        deferredDeviceDiffPresentationGapGeneration += 1
        isPresentationGapPending = false
    }

    /// The single place a deferred device diff actually runs, reached from
    /// three places: directly from `landDeferredDeviceDiff(token:afterChargerPost:)`'s
    /// `.immediate` case, after the presentation gap it schedules
    /// (interleaving 1), or after the absolute deadline
    /// (`scheduleAbsoluteDeadline`, interleaving 2). `shouldLandDeferredDiff`
    /// is the guard that keeps only the first of those to actually arrive
    /// from doing anything; see the interleaving walk-through above.
    private func landDeferredDeviceDiffNow(token: Int) {
        guard let devices = deferredDeviceDiffDevices,
              NotificationDecision.shouldLandDeferredDiff(token: token, liveToken: deferredDeviceDiffToken)
        else { return }
        deferredDeviceDiffToken += 1
        deferredDeviceDiffDevices = nil
        deferredDeviceDiffDeadlineTask?.cancel()
        deferredDeviceDiffPresentationGapTask?.cancel()
        deferredDeviceDiffPresentationGapGeneration += 1
        // Defensive, not load-bearing on the deadline/immediate paths (which
        // never set this true): once ANY path actually lands the diff, no
        // gap should be treated as still pending for it.
        isPresentationGapPending = false
        diffDevices(devices)
    }

    /// `shouldLandDeferredDiff(token:liveToken:)` (the pure "lands exactly
    /// once" guard) moved to `WhatCableNotifications.NotificationDecision`.
    /// See that type's doc comment for the exactly-once reasoning.

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
            && NotificationDecision.isReconnectPair(removed: removedGroups[0], added: addedGroups[0])
        Self.log.info("diffDevices: addedGroups=\(addedGroups.count, privacy: .public) removedGroups=\(removedGroups.count, privacy: .public) addedRoots=\(addedGroups.map(\.rootName).joined(separator: ", "), privacy: .public) removedRoots=\(removedGroups.map(\.rootName).joined(separator: ", "), privacy: .public) reconnectGateFired=\(reconnectGateFired, privacy: .public)")

        // Recover the full USBDevice for the speed/vendor body of a
        // single-member group by identity (rootID), not by name: two hubs of
        // the same model report the same product name, so name matching
        // could pick the wrong one.
        let currentByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let contents = NotificationDecision.deviceNotificationContents(removedGroups: removedGroups, addedGroups: addedGroups) { rootID in
            currentByID[rootID].map { "\($0.speedLabel)\($0.vendorName.map { " · \($0)" } ?? "")" }
        }
        for content in contents {
            postNotification(category: .device, title: content.title, body: content.body)
        }
    }

    /// `deviceNotificationContents`, `isReconnectPair`,
    /// `reconnectedNotificationContent`, `addedNotificationContents`, and
    /// `removedNotificationContents` (the pure device-content decisions, plus
    /// the reconnect gate) moved to
    /// `WhatCableNotifications.NotificationDecision`. See that type's doc
    /// comments for the full reconnect-gate and merge reasoning (issues #556,
    /// #567).
    ///
    /// `NotificationContent` itself moved to `WhatCableNotifications` as a
    /// top-level type; typealiased here so every existing call site
    /// (`NotificationManager.NotificationContent`) keeps compiling unchanged.
    typealias NotificationContent = WhatCableNotifications.NotificationContent

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

    /// `chargerNotificationContents(addedLabels:removedLabels:)` and
    /// `sortedChargerLabels(for:labels:)` moved to
    /// `WhatCableNotifications.NotificationDecision`. See that type's doc
    /// comments for the merge and ordering reasoning (issue #567).

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
        let addedLabels = NotificationDecision.sortedChargerLabels(for: addedPortKeys, labels: addedLabelsByPortKey)
        let removedLabels = NotificationDecision.sortedChargerLabels(for: removedPortKeys, labels: previousLabels)
        let contents = NotificationDecision.chargerNotificationContents(addedLabels: addedLabels, removedLabels: removedLabels)
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

    private func postNotification(category: NotificationCategory, title: String, body: String) {
        // Recorded here, not in reconcileChargers, so it reflects when a
        // charger post ACTUALLY went out through the sink, matching the
        // "posts go out through the sink" framing `devicePostDelay` reasons
        // about. Both-orders fix: see `lastChargerPostTime`'s doc comment.
        if category == .charger {
            lastChargerPostTime = ContinuousClock.now
        }
        notificationSink(category, NotificationContent(title: title, body: body))
    }
}

