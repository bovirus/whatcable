import Foundation

/// Pure helpers that turn `IOThunderboltSwitch` / `IOThunderboltPort` model
/// values into user-facing labels. Convention: per-lane Gb/s × lane count,
/// matching Apple's `system_profiler SPThunderboltDataType` output so the
/// labels line up with what users see in About This Mac → System Information.
///
/// TB5 was confirmed against a real M5 Pro + UGreen JHL9580 dock sample on
/// issue #52, so the renderer now emits a confirmed TB5 label for raw speed
/// code `0x2`. See planning/thunderbolt-fabric.md for the reasoning.
public enum ThunderboltLabels {
    /// Compact human label for an active TB link.
    /// Returns nil if the port has no active link.
    /// Examples:
    /// - `"Up to 20 Gb/s × 2"` (USB4 / TB4 dual-lane)
    /// - `"Up to 10 Gb/s × 1"` (TB3 single-lane)
    /// - `"Up to 40 Gb/s × 2"` (TB5 / USB4 v2 dual-lane)
    /// - `"Up to 40 Gb/s (3 TX / 1 RX)"` (TB5 asymmetric)
    public static func linkLabel(for port: IOThunderboltPort) -> String? {
        guard port.hasActiveLink,
              let gen = port.currentSpeed,
              let width = port.currentWidth else {
            return nil
        }

        switch gen {
        case .tb3, .usb4Tb4, .tb5:
            guard let perLane = gen.perLaneGbps else { return nil }
            let lanes = describeLanes(width)
            return String(localized: "Up to \(perLane) Gb/s \(lanes)", bundle: _coreLocalizedBundle)
        case .unknown(let raw):
            let hex = String(raw, radix: 16)
            return String(localized: "Unknown generation (raw speed code 0x\(hex))", bundle: _coreLocalizedBundle)
        }
    }

    /// Lane-count suffix. Symmetric links read `× N`; asymmetric links
    /// (TB5 3+1 configurations) read `(N TX / M RX)`.
    private static func describeLanes(_ width: LinkWidth) -> String {
        if width.asymmetricTx || width.asymmetricRx {
            return "(\(width.txLanes) TX / \(width.rxLanes) RX)"
        }
        // Symmetric: just lane count.
        let lanes = max(width.txLanes, 1)
        return "× \(lanes)"
    }

    /// Human-readable name for a downstream switch ("ASUS PA32QCV",
    /// "CalDigit, Inc. TS3 Plus"). Falls back to "Unknown device" if the
    /// DROM didn't decode (rare but possible).
    public static func deviceName(for sw: IOThunderboltSwitch) -> String {
        let vendor = sw.vendorName.trimmingCharacters(in: .whitespaces)
        let model = sw.modelName.trimmingCharacters(in: .whitespaces)
        switch (vendor.isEmpty, model.isEmpty) {
        case (false, false):
            // Some DROMs repeat the brand in the model string, e.g.
            // vendor "Ugreen" + model "Ugreen Storage Device". Concatenating
            // then reads "Ugreen Ugreen Storage Device" (issue #392). If the
            // model already starts with the vendor name, it is the full
            // name on its own. Match the whole word (equal, or vendor + space)
            // so a vendor that happens to prefix an unrelated model word
            // ("Cal" vs "Calibre X") is not collapsed.
            let vLower = vendor.lowercased()
            let mLower = model.lowercased()
            if mLower == vLower || mLower.hasPrefix(vLower + " ") {
                return model
            }
            return "\(vendor) \(model)"
        case (false, true): return vendor
        case (true, false): return model
        case (true, true): return String(localized: "Unknown device", bundle: _coreLocalizedBundle)
        }
    }
}

/// Topology helpers: walk the switch graph to find the chain rooted at a
/// host port. Pure logic; no IOKit. Used by `PortSummary` and the GUI.
public enum ThunderboltTopology {
    /// Find the host root switch whose lane port has `Socket ID == "N"`,
    /// where N is parsed from a USB-C port's serviceName suffix
    /// (e.g. `Port-USB-C@1` → `1`).
    public static func hostRoot(
        forSocketID socketID: String,
        in switches: [IOThunderboltSwitch]
    ) -> IOThunderboltSwitch? {
        switches.first { sw in
            sw.isHostRoot && sw.ports.contains {
                $0.adapterType.isLane && $0.socketID == socketID
            }
        }
    }

    /// Parse the trailing `@N` suffix from a port serviceName, or nil if
    /// it doesn't have one. `Port-USB-C@1` → `"1"`. Pure parser, kept
    /// public for parser-level unit tests; **production callers must use
    /// `socketID(for:)` instead** so the data-capability gate runs.
    public static func socketID(fromServiceName name: String) -> String? {
        guard let at = name.lastIndex(of: "@") else { return nil }
        let suffix = name[name.index(after: at)...]
        return suffix.isEmpty ? nil : String(suffix)
    }

    /// The TB host-root socket ID for this port, or `nil` when this port
    /// can't host a data link. Power-only ports (MagSafe) share an `@N`
    /// suffix with the first USB-C port on the same HPM controller
    /// (issue #195), so attempting a topology lookup on them leaks the
    /// neighbouring USB-C port's lane state. Gating on `carriesData`
    /// keeps every TB-graph consumer honest at the entry point.
    public static func socketID(for port: AppleHPMInterface) -> String? {
        guard port.carriesData else { return nil }
        return socketID(fromServiceName: port.serviceName)
    }

    /// Convert a host-root switch's `acioN` Thunderbolt HAL root name (e.g.
    /// `"acio2"`) to the sibling `apciecN` PCIe tunnel root name a tunnelled
    /// USB device reports as its own `tunnelRootName` (e.g. `"apciec2"`):
    /// same index, different prefix. `nil` when `acioName` isn't a strict
    /// `"acio" + digits` name.
    ///
    /// This is the apciec<->acio port-scoping join
    /// (`research/usb-chain-attribution-identifiers.md`): Apple Silicon
    /// exposes each Thunderbolt port as two sibling registry roots sharing
    /// one index N. `ChainDeviceAttribution` uses this to validate that a
    /// tunnelled device's `tunnelRootName` actually belongs to the port
    /// being resolved, not a different port's root that slipped in.
    public static func apciecRootName(fromAcioRootName acioName: String) -> String? {
        let prefix = "acio"
        guard acioName.hasPrefix(prefix) else { return nil }
        let digits = acioName.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return "apciec\(digits)"
    }

    /// The switch UIDs of the USB-carrying tunnels THIS host root's fabric
    /// confirms: the input `ChainDeviceAttribution.resolve`'s structural
    /// tunnel join wants as `usbTunnelSwitchUIDs`, and the ONE shared place
    /// that derivation lives (both `TunnelledDeviceGrouping` and
    /// `ConnectedDeviceTree` call this rather than each filtering
    /// `tunnels(...)` themselves, which had drifted into two different, both
    /// too-loose, derivations).
    ///
    /// `TunnelPath.kind == .usb` alone is NOT enough (review finding): kind is
    /// classified from ANY classifiable adapter in the path's UUID group
    /// (deliberately, so a real cross-cable tunnel is still recognised when
    /// the host root's own adapter is a bare lane; see `TunnelPath.swift`'s
    /// file header), while `terminalSwitchUID` is independently "the deepest
    /// switch carrying this UUID". Those two facts can point at different
    /// adapters: a `.usb` classified path whose DEEPEST member happens to be
    /// a lane-only pass-through would report a `terminalSwitchUID` that never
    /// itself carries a USB adapter, and DROM depth is exactly the value the
    /// structural join divides `tunnelBridgeDepth` by two to match, so a
    /// wrong terminal switch here is a wrong depth match downstream.
    ///
    /// Three requirements, matching the project's own tunnel-attribution
    /// research (`research/thunderbolt-fabric.md`, "Cross-cable = kind known
    /// + terminal depth > 0 + path UUID spans >= 2 distinct switches"):
    ///
    /// 1. `distinctSwitchCount >= 2`: a UUID recurring on only ONE switch's
    ///    own ports is that device's internal routing, never a tunnel
    ///    (documented corpus counterexample in `TunnelPath.swift`'s header).
    /// 2. The terminal switch is DOWNSTREAM (its `depth > 0`, i.e. not the
    ///    host root itself): a tunnel terminates at a device, never at the
    ///    Mac's own controller.
    /// 3. The terminal switch's OWN adapter carrying this UUID is actually a
    ///    USB adapter type (`.usb3Down`/`.usb3Up`/`.usbGenTDown`/
    ///    `.usbGenTUp`), read straight from `terminalAdapterType`, not
    ///    re-derived from `kind`. This is the fix for the lane-only-terminal
    ///    case above: `kind` can say `.usb` from a shallower member while the
    ///    terminal itself is something else entirely.
    public static func usbTunnelTerminalSwitchUIDs(
        from hostRoot: IOThunderboltSwitch,
        in switches: [IOThunderboltSwitch]
    ) -> Set<Int64> {
        var depthByID: [Int64: Int] = [:]
        for sw in switches { depthByID[sw.id] = sw.depth }
        let usbAdapterTypes: Set<AdapterType> = [.usb3Down, .usb3Up, .usbGenTDown, .usbGenTUp]

        return Set(
            tunnels(from: hostRoot, in: switches).compactMap { tunnel -> Int64? in
                guard tunnel.distinctSwitchCount >= 2,
                      let terminalType = tunnel.terminalAdapterType,
                      usbAdapterTypes.contains(terminalType),
                      let uid = tunnel.terminalSwitchUID,
                      let depth = depthByID[uid], depth > 0
                else { return nil }
                return uid
            }
        )
    }

    /// Return the chain of downstream switches reachable from a host root,
    /// in depth order (root → device). Walks the `parentSwitchUID` graph.
    /// Returns just the root if there's nothing downstream.
    public static func chain(
        from root: IOThunderboltSwitch,
        in switches: [IOThunderboltSwitch]
    ) -> [IOThunderboltSwitch] {
        var byParent: [Int64: [IOThunderboltSwitch]] = [:]
        for sw in switches {
            guard let parentUID = sw.parentSwitchUID else { continue }
            byParent[parentUID, default: []].append(sw)
        }

        var chain: [IOThunderboltSwitch] = [root]
        var current = root
        var seen: Set<Int64> = [root.id]
        // Follow first-child only. Daisy-chains are linear in the common
        // case; if the user has a true tree (dock with two TB devices),
        // the chain follows the first downstream branch and the GUI tree
        // can render the full topology separately.
        while let children = byParent[current.id], let next = children.first {
            guard !seen.contains(next.id) else { break }
            seen.insert(next.id)
            chain.append(next)
            current = next
        }
        return chain
    }

    /// Return the full downstream tree rooted at a host root, following
    /// *every* branch. A dock with two Thunderbolt devices yields two child
    /// subtrees. Depth 0 is the root's direct children (the first downstream
    /// devices), matching how `chain`'s `dropFirst()` is consumed. Returns an
    /// empty array when nothing is downstream.
    ///
    /// This is the branch-aware counterpart to `chain(from:in:)`, which only
    /// follows the first child. Use this for rendering the whole fabric;
    /// `chain` is still the right tool for "deepest single path" questions
    /// like step-down detection.
    public static func tree(
        from root: IOThunderboltSwitch,
        in switches: [IOThunderboltSwitch]
    ) -> [IOThunderboltSwitchNode] {
        var byParent: [Int64: [IOThunderboltSwitch]] = [:]
        for sw in switches {
            guard let parentUID = sw.parentSwitchUID else { continue }
            byParent[parentUID, default: []].append(sw)
        }

        // Cycle guard, mirroring `chain(from:in:)`'s `seen` set. Every
        // branch of the recursive walk shares this one set, so a switch
        // is visited at most once across the whole tree, however many
        // parentSwitchUID edges point at it. Without it, a malformed
        // parentSwitchUID graph with a 2+ node cycle would recurse
        // forever: `chain` has this guard already, `tree` didn't.
        var seen: Set<Int64> = [root.id]

        func build(_ sw: IOThunderboltSwitch, depth: Int) -> IOThunderboltSwitchNode {
            let kids = (byParent[sw.id] ?? [])
                .filter { !seen.contains($0.id) }
                .sorted { $0.id < $1.id }
                .map { child -> IOThunderboltSwitchNode in
                    seen.insert(child.id)
                    return build(child, depth: depth + 1)
                }
            return IOThunderboltSwitchNode(sw: sw, depth: depth, children: kids)
        }

        return (byParent[root.id] ?? [])
            .filter { !seen.contains($0.id) }
            .sorted { $0.id < $1.id }
            .map { child -> IOThunderboltSwitchNode in
                seen.insert(child.id)
                return build(child, depth: 0)
            }
    }

    /// Flatten a tree into depth-first order (parent, then its subtree),
    /// preserving each node's `depth`. Mirrors `USBDeviceNode.flatten` so the
    /// CLI and GUI render the Thunderbolt fabric the same way they render the
    /// USB device tree.
    public static func flatten(_ nodes: [IOThunderboltSwitchNode]) -> [IOThunderboltSwitchNode] {
        var result: [IOThunderboltSwitchNode] = []
        for node in nodes {
            result.append(node)
            result.append(contentsOf: flatten(node.children))
        }
        return result
    }

    /// The lane port whose link label best represents *how this switch is
    /// connected* (its arriving / active link). For a leaf device this is its
    /// only active lane; for an inline switch every active lane carries the
    /// same per-lane speed, so the first one is representative. Returns nil if
    /// no lane is active.
    public static func connectionLanePort(_ sw: IOThunderboltSwitch) -> IOThunderboltPort? {
        sw.ports.first { $0.adapterType.isLane && $0.hasActiveLink }
    }

    /// Find the active downstream lane port on a switch (the one going
    /// toward the next-hop device, not the upstream link to the host).
    /// Useful for picking which port's link state describes the next leg.
    public static func activeDownstreamLanePort(_ sw: IOThunderboltSwitch) -> IOThunderboltPort? {
        // Host root: any active lane port is downstream by definition.
        // Downstream switch: skip the lane port matching upstreamPortNumber,
        // pick the first active one of the rest.
        let candidates = sw.ports.filter { $0.adapterType.isLane && $0.hasActiveLink }
        if sw.isHostRoot {
            return candidates.first
        }
        return candidates.first { $0.portNumber != sw.upstreamPortNumber }
    }
}

// MARK: - Fabric tree

/// A node in the Thunderbolt fabric tree: one switch plus its depth from the
/// host root and its downstream children. Mirrors `USBDeviceNode` so the CLI
/// and GUI can render the fabric the same way they render the USB device tree.
/// Built from the flat switch list by `ThunderboltTopology.tree(from:in:)`,
/// which walks `parentSwitchUID`.
public struct IOThunderboltSwitchNode: Identifiable {
    public let sw: IOThunderboltSwitch
    public let depth: Int
    public let children: [IOThunderboltSwitchNode]

    public var id: Int64 { sw.id }

    public init(sw: IOThunderboltSwitch, depth: Int, children: [IOThunderboltSwitchNode]) {
        self.sw = sw
        self.depth = depth
        self.children = children
    }
}
