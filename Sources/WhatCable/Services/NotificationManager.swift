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

        // A device can disconnect and re-enumerate under a new entryID
        // within one settle window (e.g. a hub power-cycling), so the same
        // settled diff can hold both a removal and an addition for what was
        // physically one event. Post the removal first: it happened first,
        // chronologically, and a "Connected" banner landing after
        // "Disconnected" reads as what actually occurred, not the reverse.
        postRemovedGroupNotifications(removedGroups)
        postAddedGroupNotifications(addedGroups, current: current)
    }

    private func postAddedGroupNotifications(_ groups: [USBDeviceChangeGrouper.ChangeGroup], current: [USBDevice]) {
        // Recover the full USBDevice for the speed/vendor body of a
        // single-member group by identity (rootID), not by name: two hubs of
        // the same model report the same product name, so name matching
        // could pick the wrong one.
        let currentByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for group in groups {
            let title = String(localized: "Connected: \(group.rootName)", bundle: _appLocalizedBundle)
            if group.memberNames.isEmpty {
                let rootDevice = currentByID[group.rootID]
                let body = rootDevice.map { "\($0.speedLabel)\($0.vendorName.map { " · \($0)" } ?? "")" } ?? ""
                postNotification(title: title, body: body)
            } else {
                postNotification(title: title, body: group.memberNames.joined(separator: "\n"))
            }
        }
    }

    private func postRemovedGroupNotifications(_ groups: [USBDeviceChangeGrouper.ChangeGroup]) {
        if groups.count == 1, let group = groups.first {
            let title = String(localized: "Disconnected: \(group.rootName)", bundle: _appLocalizedBundle)
            postNotification(title: title, body: group.memberNames.joined(separator: "\n"))
        } else if groups.count > 1 {
            let allNames = groups.flatMap { [$0.rootName] + $0.memberNames }
            postNotification(
                title: String(localized: "USB devices disconnected", bundle: _appLocalizedBundle),
                body: allNames.joined(separator: "\n")
            )
        }
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
        let removedLabels = knownChargerLabels.filter { !currentLabels.keys.contains($0.key) }.map(\.value)
        knownChargerLabels = currentLabels

        guard AppSettings.shared.notifyOnChanges else { return }

        for portKey in addedPortKeys {
            let body = currentLabels[portKey] ?? String(localized: "PD source", bundle: _appLocalizedBundle)
            postNotification(title: String(localized: "Charger connected", bundle: _appLocalizedBundle), body: body)
        }
        for label in removedLabels {
            postNotification(title: String(localized: "Charger disconnected", bundle: _appLocalizedBundle), body: label)
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

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
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

