import SwiftUI
import AppKit
import Combine

@MainActor
public final class PluginRegistry {
    public static let shared = PluginRegistry()
    private init() {}

    public private(set) var launchHooks: [() async -> Void] = []
    public func register(launchHook: @escaping () async -> Void) {
        launchHooks.append(launchHook)
    }

    public private(set) var menuItems: [MenuPlacement: [PluginMenuItem]] = [:]
    public func register(menuItem: PluginMenuItem, at placement: MenuPlacement) {
        menuItems[placement, default: []].append(menuItem)
    }

    public private(set) var nsMenuItemBuilders: [MenuPlacement: [() -> NSMenuItem]] = [:]
    public func register(nsMenuItemBuilder: @escaping () -> NSMenuItem, at placement: MenuPlacement) {
        nsMenuItemBuilders[placement, default: []].append(nsMenuItemBuilder)
    }

    public private(set) var headerButtonBuilders: [() -> AnyView] = []
    public func register(headerButton: @escaping () -> AnyView) {
        headerButtonBuilders.append(headerButton)
    }

    public private(set) var footerButtonBuilders: [() -> AnyView] = []
    public func register(footerButton: @escaping () -> AnyView) {
        footerButtonBuilders.append(footerButton)
    }

    public private(set) var portCardTrailingBuilders: [(PortCardContext) -> AnyView?] = []
    public func register(portCardTrailing: @escaping (PortCardContext) -> AnyView?) {
        portCardTrailingBuilders.append(portCardTrailing)
    }

    public private(set) var widgetDataContributors: [any WidgetDataContributor] = []
    public func register(widgetDataContributor: any WidgetDataContributor) {
        widgetDataContributors.append(widgetDataContributor)
    }

    public private(set) var cliCommands: [CLICommand] = []
    public func register(cliCommand: CLICommand) {
        cliCommands.append(cliCommand)
    }

    /// Contributors that append a footer line to one-shot CLI text output.
    /// Each returns nil when it has nothing to say (e.g. when the user has
    /// already unlocked Pro). The CLI calls these only for plain text mode,
    /// not for --json / --watch / --report, where extra lines would break
    /// scripts or re-render every tick.
    public private(set) var cliOutputFooterContributors: [() -> String?] = []
    public func register(cliOutputFooter: @escaping () -> String?) {
        cliOutputFooterContributors.append(cliOutputFooter)
    }

    /// Snapshot providers for the "cableID -> saved name" map of CURRENTLY
    /// attached, uniquely-attributed saved cables. `DeviceDiffSequencer`
    /// (via the app-side shim) reads this once per settle to decide whether
    /// a labelled cable connecting or disconnecting should be named in a
    /// notification title. Mirrors `cliOutputFooterContributors`: a plain
    /// snapshot-returning closure, no async, called fresh at read time (no
    /// caching here). At most one Pro provider registers; the public-mirror
    /// stub registers none, so the shim's fold over an empty array yields
    /// `nil` there (feature unavailable), same as the free build with Pro
    /// locked.
    ///
    /// `[String: String]?`, not `[String: String]`: `nil` means "the feature
    /// is unavailable right now" (Pro locked, or nothing registered), `[:]`
    /// means "available, zero labelled cables currently attached". Collapsing
    /// those two into one empty-dictionary value (Codex review) is what let a
    /// licence transition mid-session (activating or deactivating Pro while a
    /// labelled cable was attached) read as the cable itself appearing or
    /// disappearing: the sequencer's diff would see the map jump between
    /// `["id": "name"]` and `[:]` and attach a fabricated or leaked label to
    /// whatever batch happened to settle next, unrelated to the licence
    /// change.
    public private(set) var notificationCableLabelProviders: [() -> [String: String]?] = []
    public func register(notificationCableLabelProvider: @escaping () -> [String: String]?) {
        notificationCableLabelProviders.append(notificationCableLabelProvider)
    }

    public private(set) var settingsProSectionBuilders: [() -> AnyView] = []
    public func register(settingsProSection: @escaping () -> AnyView) {
        settingsProSectionBuilders.append(settingsProSection)
    }

    /// Full-surface Pro screens, keyed by id. Rendered in place of the
    /// main content (a drill-down, like Settings), not in a separate
    /// window. The optional `PortCardContext` is supplied for screens
    /// scoped to one port (Cable Diagnostics); global screens ignore it.
    public typealias ProScreenBuilder = (PortCardContext?) -> AnyView
    public private(set) var proScreenBuilders: [String: ProScreenBuilder] = [:]
    public func register(proScreen id: String, builder: @escaping ProScreenBuilder) {
        if proScreenBuilders[id] != nil {
            assertionFailure("PluginRegistry: pro screen '\(id)' is already registered")
        }
        proScreenBuilders[id] = builder
    }
    public func proScreen(id: String, portCard: PortCardContext?) -> AnyView? {
        proScreenBuilders[id].map { $0(portCard) }
    }
}
