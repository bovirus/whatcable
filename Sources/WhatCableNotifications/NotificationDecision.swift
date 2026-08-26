import Foundation
import WhatCableCore

/// Namespace for the pure notification-decision rules moved out of
/// `NotificationManager` (the app-side sequencer that owns the timing
/// machinery: settle tasks, parked-diff state, gap/deadline scheduling).
/// Everything on here is `nonisolated` and side-effect free, so it's testable
/// without `Task`, `UNUserNotificationCenter`, or `WatcherHub`.
public enum NotificationDecision {
    /// Pure identifier lookup, kept separate from posting so the
    /// "same category -> same identifier, different category -> different
    /// identifier" rule is unit-testable without `UNUserNotificationCenter`.
    public static func notificationIdentifier(for category: NotificationCategory) -> String {
        category.rawValue
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
    public enum DeviceDiffDisposition: Equatable {
        case runNow
        case deferUntilChargerReconcile
    }

    /// Pure ordering rule: given a charger settle task still pending in the
    /// same episode as a settling device diff, the device diff must wait for
    /// that charger reconcile to land it, not run immediately.
    public static func deviceDiffDisposition(chargerSettlePending: Bool) -> DeviceDiffDisposition {
        chargerSettlePending ? .deferUntilChargerReconcile : .runNow
    }

    /// Whether landing a parked device diff, on the reconcile-completion
    /// path specifically, should wait out a deliberate presentation gap
    /// first or run immediately. Pure rule extracted so the decision is
    /// unit-testable without `Task`. Only `landDeferredDeviceDiff(token:
    /// afterChargerPost:)` reads it; the timeout path in `deferDeviceDiff`
    /// never asks, because a diff that timed out waiting for a reconcile has,
    /// by definition, no charger post to clash with.
    public enum DeferredDiffLanding: Equatable {
        case immediate
        case afterPresentationGap
    }

    /// `reconcileChargers` actually posted charger content this time ->
    /// its post and the device post would otherwise land in the same
    /// millisecond and macOS would show only the later one. Nothing posted
    /// -> nothing on screen to clash with, so land immediately, unchanged
    /// from before this fix.
    public static func deferredDiffLanding(reconcilePostedChargerContent: Bool) -> DeferredDiffLanding {
        reconcilePostedChargerContent ? .afterPresentationGap : .immediate
    }

    /// Pure guard behind the "lands exactly once" property: a landing
    /// attempt may proceed only while its captured `token` still matches the
    /// live one. `landDeferredDeviceDiffNow` invalidates the live token (by
    /// incrementing it) as the very first thing it does after this check
    /// passes, before running the diff, so a second attempt with the same
    /// captured token always sees a stale value and backs out.
    public static func shouldLandDeferredDiff(token: Int, liveToken: Int) -> Bool {
        token == liveToken
    }

    /// Both-orders fix: how long a device post must wait, given how long ago
    /// the last CHARGER post actually went out. `nil` elapsed (no charger
    /// post yet this app launch) or an elapsed at or past `presentationGap`
    /// both mean nothing to delay for: zero. Otherwise the REMAINDER of the
    /// window (`presentationGap - elapsed`), not the full window again, so a
    /// device post that already waited some of the gap out (by settling a
    /// little later) doesn't wait the full window a second time. Pure and
    /// separate from `runNowOrDelayForRecentChargerPost` so the arithmetic is
    /// unit-testable without `Task` or a real clock.
    public static func devicePostDelay(
        elapsedSinceLastChargerPost: Duration?,
        presentationGap: Duration
    ) -> Duration {
        guard let elapsed = elapsedSinceLastChargerPost, elapsed < presentationGap else {
            return .zero
        }
        return presentationGap - elapsed
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
    public static func deviceNotificationContents(
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
    public static func isReconnectPair(
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
    public static func reconnectedNotificationContent(
        for added: USBDeviceChangeGrouper.ChangeGroup,
        singleDeviceBody: (UInt64) -> String?
    ) -> NotificationContent {
        let title = String(localized: "Reconnected: \(added.rootName)", bundle: _notificationsLocalizedBundle)
        let body = added.memberNames.isEmpty
            ? (singleDeviceBody(added.rootID) ?? "")
            : added.memberNames.joined(separator: "\n")
        return NotificationContent(title: title, body: body)
    }

    /// Decides what to post for one settled batch of added groups. A dock
    /// with several subtrees (main USB3 hub, USB2 companion hubs, PD device)
    /// arrives as multiple groups in a single settle window; posting one
    /// `UNUserNotificationCenter.add` per group produced 2-3 simultaneous
    /// banners with only the last one visible, so most of the devices never
    /// showed up as "connected" even though they were posted. Mirrors
    /// `removedNotificationContents`'s merge so >1 group becomes ONE
    /// notification, same as a disconnect. See issue #556.
    public static func addedNotificationContents(
        groups: [USBDeviceChangeGrouper.ChangeGroup],
        singleDeviceBody: (UInt64) -> String?
    ) -> [NotificationContent] {
        if groups.count == 1, let group = groups.first {
            let title = String(localized: "Connected: \(group.rootName)", bundle: _notificationsLocalizedBundle)
            let body = group.memberNames.isEmpty
                ? (singleDeviceBody(group.rootID) ?? "")
                : group.memberNames.joined(separator: "\n")
            return [NotificationContent(title: title, body: body)]
        } else if groups.count > 1 {
            let allNames = groups.flatMap { [$0.rootName] + $0.memberNames }
            return [NotificationContent(
                title: String(localized: "USB devices connected", bundle: _notificationsLocalizedBundle),
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
    public static func removedNotificationContents(
        groups: [USBDeviceChangeGrouper.ChangeGroup]
    ) -> [NotificationContent] {
        if groups.count == 1, let group = groups.first {
            let title = String(localized: "Disconnected: \(group.rootName)", bundle: _notificationsLocalizedBundle)
            return [NotificationContent(title: title, body: group.memberNames.joined(separator: "\n"))]
        } else if groups.count > 1 {
            let allNames = groups.flatMap { [$0.rootName] + $0.memberNames }
            return [NotificationContent(
                title: String(localized: "USB devices disconnected", bundle: _notificationsLocalizedBundle),
                body: allNames.joined(separator: "\n")
            )]
        }
        return []
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
    public static func chargerNotificationContents(
        addedLabels: [String],
        removedLabels: [String]
    ) -> [NotificationContent] {
        var contents: [NotificationContent] = []
        if !removedLabels.isEmpty {
            contents.append(NotificationContent(
                title: String(localized: "Charger disconnected", bundle: _notificationsLocalizedBundle),
                body: removedLabels.joined(separator: "\n")
            ))
        }
        if !addedLabels.isEmpty {
            contents.append(NotificationContent(
                title: String(localized: "Charger connected", bundle: _notificationsLocalizedBundle),
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
    public static func sortedChargerLabels(for portKeys: some Sequence<String>, labels: [String: String]) -> [String] {
        portKeys.sorted().compactMap { labels[$0] }
    }
}
