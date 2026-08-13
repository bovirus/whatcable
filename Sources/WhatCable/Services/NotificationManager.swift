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

    private var knownDevices: [UInt64: String] = [:]
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

    private init() {}

    func start() {
        // Prime baseline on the next runloop tick so we don't fire a flurry
        // of "connected" notifications for things already plugged in at launch.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.knownDevices = Dictionary(
                WatcherHub.shared.deviceWatcher.devices.map { ($0.id, $0.productName ?? String(localized: "USB device", bundle: _appLocalizedBundle)) },
                uniquingKeysWith: { first, _ in first }
            )
            // Prime with canonicalJoinKey to match reconcileChargers, so the
            // baseline and the diff use the same key space (else every connected
            // charger would fire a spurious "connected" on the first poll).
            self.knownChargerLabels = self.chargerLabels(for: WatcherHub.shared.powerWatcher.sources)
            self.didPrimeBaseline = true
        }

        WatcherHub.shared.deviceWatcher.$devices
            .sink { [weak self] devices in self?.diffDevices(devices) }
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

    private func diffDevices(_ current: [USBDevice]) {
        guard didPrimeBaseline else { return }
        let currentIDs = Set(current.map(\.id))
        let added = current.filter { !knownDevices.keys.contains($0.id) }
        let removedNames = knownDevices.filter { !currentIDs.contains($0.key) }.map(\.value).sorted()
        knownDevices = Dictionary(
            current.map { ($0.id, $0.productName ?? String(localized: "USB device", bundle: _appLocalizedBundle)) },
            uniquingKeysWith: { first, _ in first }
        )

        guard AppSettings.shared.notifyOnChanges else { return }

        for device in added {
            let name = device.productName ?? String(localized: "USB device", bundle: _appLocalizedBundle)
            postNotification(
                title: String(localized: "Connected: \(name)", bundle: _appLocalizedBundle),
                body: "\(device.speedLabel)\(device.vendorName.map { " · \($0)" } ?? "")"
            )
        }
        if let name = removedNames.first, removedNames.count == 1 {
            postNotification(
                title: String(localized: "Disconnected: \(name)", bundle: _appLocalizedBundle),
                body: ""
            )
        } else if removedNames.count > 1 {
            postNotification(
                title: String(localized: "USB devices disconnected", bundle: _appLocalizedBundle),
                body: removedNames.joined(separator: ", ")
            )
        }
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

