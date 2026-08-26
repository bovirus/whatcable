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

    /// Whether a Thunderbolt device was involved in this settled batch: a
    /// downstream Thunderbolt fabric switch (depth > 0, so not one of the
    /// Mac's own host-root switches, which are always present) appeared or
    /// disappeared alongside the USB diff. A non-empty symmetric difference
    /// between the baseline and current sets of switch IDs covers both
    /// directions (appear, disappear) and also the case where one appeared
    /// AND a different one disappeared within the same settle window: any
    /// change to the downstream set counts, not just a net change in count.
    /// Pure and separate from `DeviceDiffSequencer` so the rule is
    /// unit-testable without `WatcherHub` or a real Thunderbolt device.
    public static func thunderboltInvolved(previous: Set<Int64>, current: Set<Int64>) -> Bool {
        previous != current
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

    /// The saved-cable label to attach to a settled device notification
    /// (issue #570 part B): when the settle window's attached-labelled-cable
    /// set changed by EXACTLY ONE cable (added or removed), that cable's
    /// name; otherwise nil (zero changes, or two-or-more changes, both read
    /// as ambiguous, same shape as `thunderboltInvolved`'s symmetric-
    /// difference rule above).
    ///
    /// Comparing the KEY SETS (cable IDs), not the dictionaries themselves,
    /// is deliberate: a saved cable renamed while it stays connected changes
    /// the VALUE for an unchanged KEY, which must NOT read as a label
    /// change, since nothing about the connection itself changed.
    ///
    /// Edge case, deliberately accepted (spec #570 part B): one saved
    /// record, two identical physical cables. Attribution matches by
    /// e-marker fingerprint against the saved record, not by physical
    /// cable, so unplugging the first and plugging in the second reports
    /// the SAME cableID both times: the id is present in both `previous`
    /// and `current` throughout the swap, so the key set never changes and
    /// the second plug-in produces no label. Two genuinely different
    /// labelled cables changing in the same window (two distinct ids)
    /// also yields nil, the ambiguous case.
    public static func cableLabelChange(
        previous: [String: String],
        current: [String: String]
    ) -> (name: String, wasAdded: Bool)? {
        let changedIDs = Set(previous.keys).symmetricDifference(current.keys)
        guard changedIDs.count == 1, let id = changedIDs.first else { return nil }
        if let name = current[id] { return (name, true) }
        if let name = previous[id] { return (name, false) }
        return nil
    }

    /// Appends the saved-cable label suffix via ONE shared localised
    /// composition key, rather than duplicating every title key with the
    /// label baked in. `nil` returns `title` unchanged, so every existing
    /// call site (none of which pass a label) produces byte-identical
    /// output to before this feature.
    private static func applyCableLabel(_ title: String, _ cableLabel: String?) -> String {
        guard let cableLabel else { return title }
        return String(localized: "\(title) (\(cableLabel))", bundle: _notificationsLocalizedBundle)
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
    /// - Parameters:
    ///   - addedCableLabel / removedCableLabel: the saved-cable name
    ///     (`cableLabelChange`'s result) to append, direction-aware: only
    ///     the side that matches which way the labelled cable changed ever
    ///     gets a non-nil label, so at most one of the two is ever set.
    ///     Threaded into the reconnect content too (the ADDED side, since a
    ///     reconnect's wording describes the device's current, just-added
    ///     state) rather than being suppressed there like `thunderboltInvolved`
    ///     is: a labelled cable reconnecting is the strongest case for
    ///     showing the label, not one to hide.
    public static func deviceNotificationContents(
        removedGroups: [USBDeviceChangeGrouper.ChangeGroup],
        addedGroups: [USBDeviceChangeGrouper.ChangeGroup],
        thunderboltInvolved: Bool = false,
        addedCableLabel: String? = nil,
        removedCableLabel: String? = nil,
        singleDeviceBody: (UInt64) -> String?
    ) -> [NotificationContent] {
        if let removed = removedGroups.first, removedGroups.count == 1,
           let added = addedGroups.first, addedGroups.count == 1,
           isReconnectPair(removed: removed, added: added) {
            return [reconnectedNotificationContent(for: added, cableLabel: addedCableLabel, singleDeviceBody: singleDeviceBody)]
        }
        return removedNotificationContents(groups: removedGroups, thunderboltInvolved: thunderboltInvolved, cableLabel: removedCableLabel)
            + addedNotificationContents(groups: addedGroups, thunderboltInvolved: thunderboltInvolved, cableLabel: addedCableLabel, singleDeviceBody: singleDeviceBody)
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
        cableLabel: String? = nil,
        singleDeviceBody: (UInt64) -> String?
    ) -> NotificationContent {
        let title = applyCableLabel(
            String(localized: "Reconnected: \(added.rootName)", bundle: _notificationsLocalizedBundle),
            cableLabel
        )
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
    ///
    /// - Parameter thunderboltInvolved: when true and there's more than one
    ///   group (so this is the MERGED title, never the single-group
    ///   "Connected: <name>" title), the title reads "Thunderbolt devices
    ///   connected" instead of "USB devices connected". Set by the caller
    ///   from `NotificationDecision.thunderboltInvolved(previous:current:)`
    ///   when a downstream Thunderbolt fabric switch appeared or disappeared
    ///   in the same settle window. Defaults to false so existing call sites
    ///   keep compiling and today's wording is byte-identical when it isn't
    ///   passed.
    public static func addedNotificationContents(
        groups: [USBDeviceChangeGrouper.ChangeGroup],
        thunderboltInvolved: Bool = false,
        cableLabel: String? = nil,
        singleDeviceBody: (UInt64) -> String?
    ) -> [NotificationContent] {
        if groups.count == 1, let group = groups.first {
            let title = applyCableLabel(
                String(localized: "Connected: \(group.rootName)", bundle: _notificationsLocalizedBundle),
                cableLabel
            )
            let body = group.memberNames.isEmpty
                ? (singleDeviceBody(group.rootID) ?? "")
                : group.memberNames.joined(separator: "\n")
            return [NotificationContent(title: title, body: body)]
        } else if groups.count > 1 {
            let allNames = groups.flatMap { [$0.rootName] + $0.memberNames }
            let baseTitle = thunderboltInvolved
                ? String(localized: "Thunderbolt devices connected", bundle: _notificationsLocalizedBundle)
                : String(localized: "USB devices connected", bundle: _notificationsLocalizedBundle)
            return [NotificationContent(title: applyCableLabel(baseTitle, cableLabel), body: allNames.joined(separator: "\n"))]
        }
        return []
    }

    /// Decides what to post for one settled batch of removed groups. Mirrors
    /// `addedNotificationContents`'s merge (>1 group becomes ONE "USB
    /// devices disconnected" notification), extracted so
    /// `deviceNotificationContents` can compose it with the reconnect gate.
    /// See issue #556.
    ///
    /// - Parameter thunderboltInvolved: same swap as
    ///   `addedNotificationContents`'s own parameter, "Thunderbolt devices
    ///   disconnected" in place of "USB devices disconnected", only for the
    ///   merged (>1 group) title.
    public static func removedNotificationContents(
        groups: [USBDeviceChangeGrouper.ChangeGroup],
        thunderboltInvolved: Bool = false,
        cableLabel: String? = nil
    ) -> [NotificationContent] {
        if groups.count == 1, let group = groups.first {
            let title = applyCableLabel(
                String(localized: "Disconnected: \(group.rootName)", bundle: _notificationsLocalizedBundle),
                cableLabel
            )
            return [NotificationContent(title: title, body: group.memberNames.joined(separator: "\n"))]
        } else if groups.count > 1 {
            let allNames = groups.flatMap { [$0.rootName] + $0.memberNames }
            let baseTitle = thunderboltInvolved
                ? String(localized: "Thunderbolt devices disconnected", bundle: _notificationsLocalizedBundle)
                : String(localized: "USB devices disconnected", bundle: _notificationsLocalizedBundle)
            return [NotificationContent(title: applyCableLabel(baseTitle, cableLabel), body: allNames.joined(separator: "\n"))]
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
