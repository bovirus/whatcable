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

    private var knownDevices: [UInt64: USBDeviceChangeGrouper.Snapshot] = [:]
    private var knownChargerLabels: [String: String] = [:]
    private var didPrimeBaseline = false

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
            self.diffDevices(WatcherHub.shared.deviceWatcher.devices)
        }
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
        chargerSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.chargerSettleWindow ?? .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
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
    private func reconcileChargers() {
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

    private func postNotification(category: NotificationCategory, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        content.sound = nil

        let identifier = Self.notificationIdentifier(for: category)
        let bodyLineCount = body.isEmpty ? 0 : body.split(separator: "\n").count
        Self.log.info("postNotification: identifier=\(identifier, privacy: .public) title=\(title, privacy: .public) bodyLines=\(bodyLineCount, privacy: .public)")

        // Diagnostic only: surface whether the system would even show this,
        // so a "posted but never seen" report can be told apart from
        // "never posted". Doesn't gate or change the post below.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Self.log.info("postNotification: authorizationStatus=\(settings.authorizationStatus.rawValue, privacy: .public) alertSetting=\(settings.alertSetting.rawValue, privacy: .public)")
        }

        // Same identifier per category replaces the previous notification
        // in place rather than stacking a new one (issue #567): a second
        // device event leaves ONE entry in Notification Centre, not two.
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.log.error("Post failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

