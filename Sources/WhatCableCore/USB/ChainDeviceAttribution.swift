import Foundation

/// Works out which Thunderbolt chain device each USB device sits inside.
///
/// The problem it solves: on a daisy chain (Mac -> display -> dock) macOS
/// publishes the USB devices as one flat forest per host controller with no
/// record of which downstream Thunderbolt device each one is physically plugged
/// into. The Thunderbolt fabric knows the chain exactly, and the USB tree knows
/// the hub cascade exactly, but nothing joins the two. Without a join, a dock's
/// Ethernet adapter renders five hub levels deep under the display the dock is
/// chained behind, which is where "12 rows, and you cannot tell what is plugged
/// into what" comes from.
///
/// No published technique exists for this on macOS, and `system_profiler
/// SPUSBDataType` returns nothing at all on the reference machine, so there is
/// no ground truth to copy. What follows is inference, and every step of it is
/// built to fail closed: **when the evidence does not single out one chain
/// device, the device stays unattributed and renders exactly where it does
/// today.** A wrong parent is worse than a flat list.
///
/// Three signals, in order of strength:
///
/// 1. **The name match.** A Thunderbolt device usually exposes its own USB
///    identity endpoint, and its `USB Product Name` is the same string the
///    fabric reports as `Device Model Name`. `TBT5 Docking Station 10-in-1`
///    appears in both. Two strengths of match, and the difference matters:
///    - **exact** (normalised equality): this device IS the chain device, so it
///      is absorbed into the chain row rather than rendered twice.
///    - **affiliate** (one name's words are a contiguous run inside the
///      other's): this device is PART OF the chain device. `TS5 USB 3 Hub` and
///      `CalDigit TS5 Audio - Rear` against a chain device modelled `TS5`;
///      `Apple Thunderbolt Display` against `Thunderbolt Display`. It marks its
///      hub but is never absorbed, because deleting a dock's audio endpoint
///      from the tree would be a bug, not a de-duplication.
///    Either way, the hub the device hangs off is that chain device's own
///    upstream hub, so everything under that hub is inside it.
/// 2. **Inheritance (structural).** Walking down the USB forest, a device takes
///    its nearest marked ancestor's owner. This is what separates a chained
///    dock's subtree from the display's while it sits nested inside it.
/// 3. **Vendor continuity (weakest, and heavily gated).** A device whose vendor
///    appears in exactly one chain device's marked region probably belongs to
///    that chain device. Applied top-down as a region mark, not per device, for
///    two reasons: it keeps a hub and its children together, and it makes the
///    collapsed and expanded views agree about where a device sits. An earlier
///    draft resolved it per endpoint in the collapsed view only, which put the
///    reference machine's Ethernet adapter under the dock by default and
///    somewhere else entirely once the user clicked "Show hubs".
///
/// Pure logic, no IOKit. `ConnectedDeviceTree` is the only caller.
public struct ChainDeviceAttribution: Equatable {
    /// USB device id -> chain switch id: every device the three signals could
    /// place, hubs included. Both view modes read this, so they cannot disagree
    /// about which chain device something is inside.
    public let regionOwner: [UInt64: Int64]

    /// The marked nodes: USB device id -> the chain switch id whose region
    /// starts there. The expanded view renders one nested subtree per entry.
    public let regionRoots: [UInt64: Int64]

    /// Devices that ARE a chain device (their own USB identity endpoint).
    /// Rendering both them and the chain row would duplicate the device, which
    /// is a good part of why the tree reads as a tangle today.
    public let absorbed: Set<UInt64>

    /// True when every chain device was anchored. Gates vendor continuity: see
    /// the `resolve` implementation for why a partial anchor set makes vendor
    /// evidence meaningless rather than merely weak.
    public let allAnchored: Bool

    public static let none = ChainDeviceAttribution(
        regionOwner: [:], regionRoots: [:], absorbed: [], allAnchored: false
    )

    /// Nothing was attributed and nothing absorbed, so the caller can render
    /// its existing layout unchanged.
    public var isEmpty: Bool { regionOwner.isEmpty && absorbed.isEmpty }

    // MARK: - Resolution

    /// - Parameters:
    ///   - chain: the downstream Thunderbolt tree for ONE port, as
    ///     `ThunderboltTopology.tree(from:in:)` returns it.
    ///   - forest: the USB device forest for the same port, as
    ///     `USBDeviceNode.buildTree(from:)` returns it.
    ///   - usbTunnelSwitchUIDs: the switch UIDs of the USB-carrying tunnels
    ///     THIS port's fabric actually reports (`ThunderboltTopology
    ///     .tunnels(from:in:).filter { $0.kind == .usb }
    ///     .compactMap(\.terminalSwitchUID)`). The structural tunnel join
    ///     below only ever considers switches in this set: an empty set
    ///     (no hop-table data, or the caller didn't compute it) means the
    ///     structural pass places nothing, which is the correct fail-closed
    ///     default, not a silent behaviour change.
    ///   - expectedTunnelRootName: this port's own `apciecN` root name (from
    ///     its host root switch's `acioRootName`, converted by
    ///     `ThunderboltTopology.apciecRootName(fromAcioRootName:)`), used to
    ///     refuse a tunnelled device whose `tunnelRootName` names a
    ///     DIFFERENT port. `nil` when the caller could not derive it (older
    ///     capture, or the acio walk's bound was exceeded); the structural
    ///     pass still runs then, but falls back to an internal-consistency
    ///     check (see below).
    public static func resolve(
        chain: [IOThunderboltSwitchNode],
        forest: [USBDeviceNode],
        usbTunnelSwitchUIDs: Set<Int64> = [],
        expectedTunnelRootName: String? = nil
    ) -> ChainDeviceAttribution {
        let chainNodes = ThunderboltTopology.flatten(chain)
        let allNodes = USBDeviceNode.flatten(forest)
        guard !chainNodes.isEmpty, !allNodes.isEmpty else { return .none }

        var nodeByID: [UInt64: USBDeviceNode] = [:]
        var parentOf: [UInt64: UInt64] = [:]
        for node in allNodes { nodeByID[node.device.id] = node }
        for node in allNodes {
            for child in node.children { parentOf[child.device.id] = node.device.id }
        }

        // Numeric identity (#493/PR 500): a chain device's Thunderbolt DROM
        // carries a NUMERIC vendor/model pair (`Device Vendor ID`, `Device
        // Model ID`) alongside its name, and a native USB endpoint's own
        // `idVendor`/`idProduct` match those numbers EXACTLY for a
        // single-function accessory. Hoisted up here (it used to live
        // further down, inside the name-matching section) because the
        // structural tunnel join below needs it too, for the same
        // precedence-safety reason the name match does: a device whose OWN
        // numeric identity disagrees with its structurally-derived switch is
        // not safe to place structurally either.
        //
        // Two defensive rules, both found by review (#493 round 5):
        //
        // 1. Zero is refused explicitly, even though `IOThunderboltSwitch`
        //    already normalises a non-positive/out-of-range DROM value to
        //    `nil` at parse time (see `IOThunderboltLink.swift`). Belt and
        //    suspenders: `USBDevice.vendorID`/`productID` default to 0 on a
        //    failed descriptor read (`USBWatcher.swift`), and a fixture or a
        //    future caller could still construct an `IOThunderboltSwitch`
        //    with `dromVendorID`/`dromModelID` of 0 directly, bypassing that
        //    normalisation. Without this guard, two unrelated devices that
        //    BOTH failed their descriptor read would "exactly match" each
        //    other on 0/0, and reproducing that promoted an unrelated hub.
        //
        // 2. The match set is checked for AMBIGUITY, not just existence,
        //    mirroring the file's existing duplicate-name rule ("two chain
        //    devices with the same model name match neither", `exact[...]`
        //    below). Two chain devices sharing an identical DROM VID+PID
        //    pair (two identical daisy-chained docks, the same product
        //    twice) both match, and picking "whichever comes first" silently
        //    cross-attributes one region into the other. More than one match
        //    is refused outright, exactly like the name-based case: no
        //    numeric identity is safer than a wrong one.
        func numericIdentity(of device: USBDevice) -> IOThunderboltSwitchNode? {
            guard device.vendorID != 0, device.productID != 0 else { return nil }
            let matches = chainNodes.filter {
                guard let dvid = $0.sw.dromVendorID, dvid != 0,
                      let dmid = $0.sw.dromModelID, dmid != 0
                else { return false }
                return dvid == Int(device.vendorID) && dmid == Int(device.productID)
            }
            return matches.count == 1 ? matches.first : nil
        }

        // 1. Anchors: a USB product name that matches a chain device's model
        // name. Matched against `modelName`, NOT
        // `ThunderboltLabels.deviceName(for:)`: that prepends the DROM vendor
        // ("Ugreen Group Limited TBT5 Docking Station 10-in-1") and would never
        // match the USB side. Names are whitespace-collapsed and case-folded
        // because the fabric reports "Studio Display " with a trailing space.
        var switchIDsByName: [String: Set<Int64>] = [:]
        for node in chainNodes {
            let key = normalized(node.sw.modelName)
            // Two characters is not a name, it is a chance collision.
            guard key.count >= 3 else { continue }
            switchIDsByName[key, default: []].insert(node.sw.id)
        }

        var exact: [UInt64: Int64] = [:]
        var affiliates: [UInt64: Int64] = [:]
        for node in allNodes {
            guard let product = node.device.productName else { continue }
            let key = normalized(product)
            guard key.count >= 3 else { continue }
            if let ids = switchIDsByName[key] {
                // Two chain devices with the same model name (two identical
                // daisy-chained displays: "UltraFine 4K" twice in the corpus)
                // cannot be told apart by name, so neither is matched.
                if ids.count == 1, let id = ids.first { exact[node.device.id] = id }
                continue
            }
            // Word-run containment, either direction, which is what catches the
            // families exact equality misses: CalDigit's entire TS line reports
            // `TS5` in the DROM and never once as a bare USB product name, so
            // without this it can never be recognised at all. Matching on whole
            // words rather than raw substrings keeps `TS5` out of an unrelated
            // `ATS5000`.
            let soft = chainNodes.filter {
                let model = normalized($0.sw.modelName)
                return model.count >= 3 && affiliated(product: product, model: $0.sw.modelName)
            }
            if soft.count == 1, let id = soft.first?.sw.id { affiliates[node.device.id] = id }
        }

        // 1b. Structural tunnel join, ahead of every OTHER name-based signal
        // below (the affiliate pass, vendor continuity) but SUBORDINATE to a
        // device's own exact-name or numeric identity (checked just below):
        // two strong, independent signals disagreeing means one of them is
        // wrong and this function cannot tell which, so the device fails
        // closed to whichever of the two is the WEAKER inference to trust
        // blindly, which is the structural one (see the precedence-safety
        // note below).
        //
        // A tunnelled USB device (`isThunderboltTunnelled`) carries
        // `tunnelBridgeDepth`: the count of PCIe bridge hops between its
        // `AppleUSBXHCITR` controller and the port's `apciecN` root. On Apple
        // Silicon that count is always twice the TB DROM `Depth` of the
        // switch whose own USB tunnel the device rides
        // (`research/usb-chain-attribution-identifiers.md`, confirmed on the
        // #493 reporter's own two captures and re-checked across ~40 further
        // corpus folders during the follow-up investigation: a LaCie 1big at
        // DROM depth 2 sits 4 bridge hops from its port's `apciec2` root, a
        // Studio Display chained behind it at depth 3 sits 6 hops from the
        // SAME root). Dividing by two turns the raw count into a `sw.depth`
        // to look up directly against this port's chain, no name required:
        // this catches devices a name match cannot, like a Studio Display's
        // internal "USB2 Hub" and "USB3 Gen2 Hub" personas, which carry no
        // name hinting at the display at all.
        //
        // THREE gates, all of which must pass, in order:
        //
        // 1. **Only switches this port's fabric confirms carry a USB
        //    tunnel** (`usbTunnelSwitchUIDs`, derived by the caller from
        //    `ThunderboltTopology.tunnels(...).filter { $0.kind == .usb }`).
        //    Gated per DEPTH within that set, not per whole chain: a target
        //    depth only resolves when exactly one CONFIRMED-tunnelled switch
        //    sits there. This is deliberately narrower than "the whole chain
        //    is linear" would be, and the difference is real, not
        //    theoretical: the #493 reporter's own ground-truth machine has
        //    the CalDigit dock fan out to TWO depth-2 siblings, an OWC
        //    Express 1M2 (PCIe tunnel only, no USB tunnel of its own) and the
        //    LaCie 1big (tunnel bridge depth 4). A whole-chain gate, or a
        //    gate that counted every switch at a depth rather than only
        //    confirmed USB-tunnel ones, would refuse the LaCie's structural
        //    join purely because the OWC happens to share its depth, even
        //    though the OWC contributes zero conflicting bridge-depth
        //    evidence: nothing ever computes a target depth of 2 from the
        //    OWC, because it has no `AppleUSBXHCITR` controller to walk.
        //    Restricting to `usbTunnelSwitchUIDs` resolves LaCie's devices
        //    (and the Studio Display's, depth 3, chained behind it) while OWC
        //    is excluded from `depthCounts` entirely, which is the correct
        //    "cannot own anything" outcome for a device with no USB tunnel.
        //    Two GENUINELY USB-tunnelled switches sharing one depth is the
        //    actually-unproven case (zero corpus examples: 10 ports have
        //    more than one tunnelled controller, all 10 at distinct depths),
        //    and per-depth gating refuses exactly that, and only that.
        // 2. **The device's `tunnelRootName` belongs to THIS port.** When
        //    `expectedTunnelRootName` is known, an exact string match is
        //    required: a mismatch means this device's tunnel controller sits
        //    under a DIFFERENT physical port's `apciecN` root, a cross-port
        //    mixup, and it is refused outright regardless of how well the
        //    depth arithmetic lines up. When `expectedTunnelRootName` is
        //    `nil` (the caller could not derive it), this function falls
        //    back to an INTERNAL consistency check across every candidate in
        //    THIS resolve() call: if they disagree on `tunnelRootName`
        //    amongst themselves, that is itself evidence of a cross-port
        //    mixup upstream (devices from two different ports ended up in
        //    the same `forest`), and every one of them is refused; if they
        //    agree (or none report a root at all, e.g. replaying probe data
        //    that only captured up to the old terminator), the pass
        //    proceeds as before.
        // 3. **Precedence safety.** A device whose own exact-name match
        //    (`exact[id]`) or numeric identity (`numericIdentity(of:)`)
        //    resolves to a DIFFERENT chain device than the structural depth
        //    lookup is left OUT of the structural pass entirely: the
        //    name/numeric placement is kept (unaffected; it flows through
        //    `exact` into the marks/claimTarget pipeline below exactly as it
        //    always has), but this device is also recorded in
        //    `structurallyConflicted` so it is EXCLUDED from `absorbed` at
        //    the end, even though it still has a normal exact-name match: a
        //    device that is simultaneously tunnelled at a depth pointing one
        //    way and named toward another has produced two signals that
        //    cannot both be right, and confidently hiding it as "IS the
        //    chain device" would be presumptuous evidence-reading. It still
        //    renders as its own row, nested at wherever the name/numeric
        //    match placed it.
        var depthCounts: [Int: [Int64]] = [:]
        for node in chainNodes where usbTunnelSwitchUIDs.contains(node.sw.id) {
            depthCounts[node.sw.depth, default: []].append(node.sw.id)
        }
        var switchIDByDepth: [Int: Int64] = [:]
        for (depth, ids) in depthCounts where ids.count == 1 { switchIDByDepth[depth] = ids[0] }

        // Raw candidates: every tunnelled device whose bridge depth resolves
        // to an unambiguous switch, BEFORE the root-name and
        // precedence-safety gates. Built first (rather than folded into one
        // loop) because the root-name internal-consistency fallback needs to
        // see every candidate's `tunnelRootName` before deciding whether ANY
        // of them can be trusted.
        struct StructuralCandidate { let id: UInt64; let switchID: Int64; let rootName: String? }
        var rawCandidates: [StructuralCandidate] = []
        for node in allNodes {
            guard node.device.isThunderboltTunnelled else { continue }
            // Carrier-gated: each structural path requires the carrier that
            // proves its arithmetic applies. A nil (unknown) carrier joins
            // nothing structurally: old fixtures and replays of captures that
            // never recorded the terminator keep exactly the name-pass +
            // fallback behaviour they had before carriers existed.
            switch node.device.tunnelCarrier {
            case .usbTunnel:
                // The corpus-verified USB-tunnel depth relation
                // (bridgeDepth == 2 x DROM depth).
                guard let bridgeDepth = node.device.tunnelBridgeDepth,
                      bridgeDepth >= 2, bridgeDepth.isMultiple(of: 2),
                      let switchID = switchIDByDepth[bridgeDepth / 2]
                else { continue }
                rawCandidates.append(StructuralCandidate(id: node.device.id, switchID: switchID, rootName: node.device.tunnelRootName))
            case .pcieTunnel:
                // Stage A single-switch shortcut (plan v5): a device on a
                // dock-supplied PCIe xHCI (LG UltraFine, TS3+ class) whose
                // rootName scopes it to this port attributes to the chain's
                // sole downstream switch, with NO depth arithmetic: the
                // depth relation is unverified for dock controllers (no
                // capture records their bridge chain yet), so any daisy
                // chain (2+ downstream switches) leaves the device at port
                // level until Stage B verifies it. The rootName requirement
                // is what makes this a structural claim rather than a guess:
                // a no-root device (walk never reached apciecN) stays in the
                // fallback.
                guard chainNodes.count == 1,
                      node.device.tunnelRootName != nil
                else { continue }
                rawCandidates.append(StructuralCandidate(id: node.device.id, switchID: chainNodes[0].sw.id, rootName: node.device.tunnelRootName))
            case nil:
                continue
            }
        }

        let rootIsTrusted: (String?) -> Bool
        if let expectedTunnelRootName {
            rootIsTrusted = { $0 == expectedTunnelRootName }
        } else {
            let distinctRoots = Set(rawCandidates.compactMap(\.rootName))
            rootIsTrusted = distinctRoots.count > 1 ? { _ in false } : { _ in true }
        }

        var structuralOwner: [UInt64: Int64] = [:]
        var structuralRoots: [UInt64: Int64] = [:]
        var structurallyConflicted: Set<UInt64> = []
        // `rawCandidates` preserves `allNodes`'s pre-order (`USBDeviceNode
        // .flatten`), so a device's parent is always processed before it,
        // which lets the region-root check below read
        // `structuralOwner[parentID]` immediately rather than needing a
        // second pass.
        for candidate in rawCandidates {
            guard rootIsTrusted(candidate.rootName) else { continue }
            guard let node = nodeByID[candidate.id] else { continue }
            if let namedSwitch = exact[candidate.id], namedSwitch != candidate.switchID {
                structurallyConflicted.insert(candidate.id)
                continue
            }
            if let numericSwitch = numericIdentity(of: node.device)?.sw.id, numericSwitch != candidate.switchID {
                structurallyConflicted.insert(candidate.id)
                continue
            }
            structuralOwner[candidate.id] = candidate.switchID
            // Region root only at the boundary of the structural group: if
            // the nearest USB-tree parent already carries the SAME owner,
            // inheritance already covers this device and marking it again
            // would render its subtree twice (the same redundant-mark
            // hazard step 5 below guards against for the name-based passes).
            let parentSharesOwner = parentOf[candidate.id].flatMap { structuralOwner[$0] } == candidate.switchID
            if !parentSharesOwner {
                structuralRoots[candidate.id] = candidate.switchID
            }
        }

        // 2. Region roots, in two passes: exact matches settle ownership, then
        // affiliate matches may only fill the gaps left over.
        //
        // The order is the point, and it is a correctness fix rather than tidying.
        // An affiliate match is a partial-name match, so a chain device whose
        // model name is a single generic word ("Hub", which clears the
        // three-character floor) matches the internal hub chips of completely
        // unrelated devices, because "USB3.0 Hub" contains the whole word "hub"
        // and so does nearly every hub descriptor ever written. Running both
        // strengths together let such a match re-parent a device that an exact
        // match had already placed inside a different chain device, moving its
        // whole subtree under an unrelated dock. Exact evidence going first, and
        // affiliate matches being refused wherever they would contradict it,
        // closes that without needing a list of words to distrust.
        //
        // A hub claimed by two DIFFERENT chain devices is claimed by neither.
        // Corpus counterexample: on `m4_macos26.5.2_x` an Echo 13 dock and the
        // Envoy Ultra chained behind it expose their identity endpoints on the
        // SAME hub, which means the hub is upstream of both. Letting either one
        // claim it (say, the deeper device) moved five of that machine's
        // endpoints inside a bare SSD.
        //
        // That guard only fires when TWO chain devices claim the same hub. It
        // does nothing when only one does, and promoting a lone claim onto the
        // parent hub is right in the common case: the hub genuinely is the
        // claiming device's own hub. Blocking needs POSITIVE evidence the hub
        // belongs to someone else.
        //
        // Numeric identity first, strings only as a last resort:
        // `numericIdentity(of:)`, defined above (hoisted so the structural
        // tunnel join further down can use it too), looks up the chain device
        // (if any) whose DROM (Device Vendor ID, Device Model ID) exactly
        // equals a USB device's own (idVendor, idProduct). A number pair is a
        // far stronger join than a product-name string, which can coincide by
        // accident or by a generic word ("Hub"). Strings are still needed for
        // two reasons: some devices carry no exact numeric match at all (a
        // hub chip's PID is its own, not the dock's), and one corpus quirk
        // means a VID MISMATCH does not prove a different vendor (see
        // `numericIdentity`'s doc comment above), so numeric evidence is
        // trusted only when it POSITIVELY matches, never as a negative signal
        // on its own.
        //
        // Set of chain devices whose DROM vendor id equals `vid`, applying
        // the same zero-guard as `numericIdentity`. Used by tier (c) below,
        // kept separate so its own ambiguity rule (see there) reads clearly.
        func chainDevicesWithDROMVendorID(_ vid: Int) -> [IOThunderboltSwitchNode] {
            guard vid != 0 else { return [] }
            return chainNodes.filter { $0.sw.dromVendorID == vid }
        }

        // Same normalise-then-length-floor discipline the name-matching pass
        // above uses (`key.count >= 3`, "two characters is not a name, it is
        // a chance collision"): a hub vendor string, or the string it is being
        // compared against, has to actually look like a name before it counts
        // as evidence either way. String-only fallback, tier (d) below.
        func vendorNamesMatch(_ a: String, _ b: String) -> Bool {
            guard normalized(a).count >= 3, normalized(b).count >= 3 else { return false }
            return affiliated(product: a, model: b)
        }

        var chainVendorByID: [Int64: String] = [:]
        for node in chainNodes { chainVendorByID[node.sw.id] = node.sw.vendorName }

        // `claimTarget` returns BOTH the redirection (leaf or parent hub) and
        // the switch id the claim is now recorded against. The two used to be
        // the same by construction (the caller always passed the NAME match's
        // switch id straight through), but numeric identity can override it:
        // if the claiming endpoint's own idVendor/idProduct exactly identifies
        // it as a DIFFERENT chain device than the name match proposed, the
        // number pair wins (see tier order below), and every subsequent
        // decision, this call's and the caller's grouping, has to use that
        // corrected switch id, not the name match's.
        func claimTarget(_ deviceID: UInt64, claimedBy switchID: Int64) -> (target: UInt64, switchID: Int64)? {
            guard let node = nodeByID[deviceID] else { return nil }

            // Computed FIRST, before any early return, and used in every
            // return path below including the hub-claimant and
            // no-hub-parent ones. An earlier version computed this only on
            // the "has a hub parent" path, so a device that IS itself a hub,
            // or has no hub parent at all, kept the NAME match's switch id
            // even when its own numeric identity said otherwise: the
            // promised numeric correction silently never applied there.
            // Found in review (#493 round 5); tests cover both paths.
            let endpointIdentity = numericIdentity(of: node.device)
            let effectiveSwitchID = endpointIdentity?.sw.id ?? switchID

            if node.device.isHub { return (deviceID, effectiveSwitchID) }
            guard let parentID = parentOf[deviceID], let parent = nodeByID[parentID],
                  parent.device.isHub
            else { return (deviceID, effectiveSwitchID) }

            // Tier (a)/(b): the hub's OWN idVendor/idProduct, checked first.
            // When the hub itself numerically identifies as a chain device,
            // that is decisive and no string is ever consulted: identifies as
            // the claimer -> promote, identifies as someone else -> leaf.
            if let hubIdentity = numericIdentity(of: parent.device) {
                return hubIdentity.sw.id == effectiveSwitchID
                    ? (parentID, effectiveSwitchID)
                    : (deviceID, effectiveSwitchID)
            }

            // Tier (c): the endpoint IS numerically identified but the hub
            // itself is not (its own idVendor/idProduct match no chain
            // device's DROM exactly). Fall back to VID-only: a multi-chip
            // dock's internal hub chips routinely share the dock's chassis
            // VID while carrying their OWN model id, so a VID-only match to
            // the claiming chain device is still real, if weaker, evidence.
            //
            // Same set-based discipline as `numericIdentity`: the SET of
            // chain devices whose DROM VID equals the hub's VID decides, not
            // "the first one found". Promotes only when that set is EXACTLY
            // the claiming chain device (one match, and it is the claimer);
            // any different switch in the set refuses, even if the claimer
            // is ALSO in it (ambiguous, so it fails closed); an empty set
            // falls through to the string tier.
            //
            // Residual, accepted: a VID-only match is a coincidence risk in
            // principle (the Thunderbolt-SIG-assigned Device Vendor ID and
            // the USB-IF-assigned idVendor are different registries, so an
            // unrelated company could in theory hold matching numbers in
            // both), which this tier cannot rule out. It fails SAFE either
            // way: a wrong promotion would misattribute a device, a wrong
            // refusal only leaves it unattributed (the file's documented
            // "stays unattributed" default), so a coincidence here costs a
            // missed attribution, never a wrong one. Zero such collisions
            // have been observed corpus-wide (22 exact VID+PID matches, 51
            // VID-only matches, 2026-08-06 sweep); that is evidence for this
            // tier being safe in practice, not a guarantee, and is not
            // treated as one anywhere in this function.
            //
            // #493 walk-through: the OWC Express 1M2 endpoint is
            // 0x174c/0x2465, an exact match to the OWC switch's own DROM, so
            // `effectiveSwitchID` is the OWC (tier a/b never fires: the
            // CalDigit hub's own idVendor/idProduct, 0x2188/0x5803, is not an
            // exact match to ANY chain device; the CalDigit DOCK's own DROM
            // model id is 0x5988, not 0x5803, because the hub is one of the
            // dock's internal chips, not the dock's own identity endpoint).
            // Here in tier (c): the hub's VID (0x2188) equals the CalDigit
            // DOCK's DROM vendor id, a DIFFERENT chain device from the OWC
            // (0x174c), so this tier returns leaf. No vendor-name string is
            // ever read for this case.
            if let endpointIdentity {
                let hubVID = Int(parent.device.vendorID)
                let matchingChainDevices = chainDevicesWithDROMVendorID(hubVID)
                if matchingChainDevices.contains(where: { $0.sw.id != endpointIdentity.sw.id }) {
                    return (deviceID, effectiveSwitchID)
                }
                if matchingChainDevices.count == 1 {
                    // The only match, and (per the check above) it must be
                    // the claiming chain device itself.
                    return (parentID, effectiveSwitchID)
                }
                // Empty set: VID-only was inconclusive too (hub VID matches
                // nothing on this fabric). Fall through to the string tier
                // below. This is also where the corpus quirk lives: some OWC
                // units report Thunderbolt vendor id 0x1e91 while their USB
                // idVendor stays 0x174c. That VID "mismatch" is NOT treated
                // as evidence of a different vendor above (only a POSITIVE
                // match to someone else refuses, never a negative non-match
                // to the claimer), so a 0x1e91 hub falls through here rather
                // than being wrongly blocked, and the string tier decides
                // instead.
            }

            // Tier (d): no numeric evidence at all, or tier (c) fell through
            // inconclusive. The string rule here is deliberately the ORIGINAL
            // (round 2) one, not the same-brand-refusing rewrite that
            // replaced it as the file's only rule (round 3): a hub vendor
            // NAME match to the claimer, its own vendor or its chain device's
            // DROM vendor, wins over a match to a different chain device.
            // Numeric identity is now the primary signal and handles the
            // same-brand ambiguity round 3 fixed (a same-brand endpoint on a
            // same-brand hub typically also carries a numeric identity, which
            // resolves it in tier a/b/c before a string is ever read); once
            // evidence has fallen all the way through to a bare name-string
            // coincidence, over-blocking on it costs more correct
            // attributions than the residual ambiguity it protects against.
            guard let hubVendor = parent.device.vendorName else { return (parentID, effectiveSwitchID) }
            let matchesClaimingDevice = node.device.vendorName.map { vendorNamesMatch(hubVendor, $0) } ?? false
            let matchesClaimingChain = chainVendorByID[effectiveSwitchID].map { vendorNamesMatch(hubVendor, $0) } ?? false
            if matchesClaimingDevice || matchesClaimingChain { return (parentID, effectiveSwitchID) }
            let namesADifferentChainDevice = chainNodes.contains { other in
                other.sw.id != effectiveSwitchID && vendorNamesMatch(hubVendor, other.sw.vendorName)
            }
            return namesADifferentChainDevice ? (deviceID, effectiveSwitchID) : (parentID, effectiveSwitchID)
        }
        // `contested` is the other half of the shared-hub guard, and it is not
        // optional bookkeeping. Refusing to MARK a disputed hub leaves it
        // unowned, and unowned is exactly what vendor continuity looks for, so
        // without this the hub the guard just protected gets handed to whichever
        // chain device happens to share its vendor. Recording where the
        // ambiguity was seen keeps that evidence available to the later pass.
        //
        // It gates vendor evidence only, deliberately. A disputed hub nested
        // inside another chain device's region still INHERITS that region, which
        // is a true statement and not a guess: a region root is the hub a chain
        // device's identity endpoint hangs off, so everything below it reaches the
        // Mac through that device. What that leaves is a row reading slightly more
        // definite than its evidence, not a wrong parent; both the reasoning and
        // the residual are set out in
        // `contestedSubtreeStillInheritsItsEnclosingRegion`.
        //
        // Slightly over-collects, harmlessly: a target contested in the affiliate
        // pass is recorded even when the exact pass resolved it cleanly. Anything
        // already owned never reaches the vendor branch, so the extra entry has no
        // effect.
        var contested: Set<UInt64> = []
        func marks(from matches: [UInt64: Int64]) -> [UInt64: Int64] {
            var claims: [UInt64: Set<Int64>] = [:]
            for (deviceID, switchID) in matches {
                guard let (target, effectiveSwitchID) = claimTarget(deviceID, claimedBy: switchID) else { continue }
                claims[target, default: []].insert(effectiveSwitchID)
            }
            for (target, switchIDs) in claims where switchIDs.count > 1 {
                contested.insert(target)
            }
            return claims.compactMapValues { $0.count == 1 ? $0.first : nil }
        }

        var regionRoots = marks(from: exact)

        // Structural marks win outright over name matching (step 0's
        // precedence rule): merged in here, before the first inheritance
        // pass, so `regionOwner` reflects them immediately and the affiliate
        // pass below (which only fills gaps `regionOwner` leaves open) can
        // never contradict one.
        regionRoots.merge(structuralRoots) { _, structural in structural }

        // 3. Inherit down the forest. A deeper mark overrides a shallower one,
        // which is exactly how a chained dock's subtree separates from the
        // display's while nested inside it.
        var regionOwner: [UInt64: Int64] = [:]
        func descend(_ node: USBDeviceNode, _ inherited: Int64?) {
            let owner = regionRoots[node.device.id] ?? inherited
            if let owner { regionOwner[node.device.id] = owner }
            for child in node.children { descend(child, owner) }
        }
        for root in forest { descend(root, nil) }

        // Affiliate marks now, keeping only those that do not contradict what
        // the exact pass established. Note this compares against the OWNER of
        // the hub being claimed, so an affiliate match is still free to open a
        // region inside an unowned part of the tree.
        let affiliateMarks = marks(from: affiliates).filter { target, switchID in
            guard let established = regionOwner[target] else { return true }
            return established == switchID
        }
        if !affiliateMarks.isEmpty {
            regionRoots.merge(affiliateMarks) { existing, _ in existing }
            regionOwner = [:]
            for root in forest { descend(root, nil) }
        }

        // 4. Vendor continuity, for what the structural pass could not place.
        //
        // Gated on every chain device having actually RESOLVED a region, which is
        // a correctness requirement and not caution. Vendor sets are built only
        // from resolved regions, so a chain device without one contributes no
        // vendors at all: a device physically inside dock B whose parents are VIA
        // Labs hubs would then be handed to dock A purely because dock A is the
        // only candidate with a vendor set, not because the vendor discriminates.
        // VIA Labs, Genesys Logic, Terminus and Fresco Logic hubs are inside
        // nearly every dock, so that failure mode is the common case, not an edge
        // one. With every chain device holding a region, "the vendor is in
        // exactly one set" is a real comparison between real candidates.
        //
        // This keys on regions and not on name matches, and the difference is a
        // hole that was open until an adversarial review found it: on a chain of
        // three where two devices name endpoints on one shared hub and the third
        // is cleanly matched, every device HAS a name match, yet only the third
        // holds a region. Keying on matches made the gate pass, and vendor
        // continuity then handed the disputed hub, plus everything inside the
        // first two devices, to the third. That is the exact wrong-parent
        // failure the shared-hub guard exists to prevent, reached by the other
        // path.
        let allAnchored = Set(regionRoots.values).count == chainNodes.count

        var vendorsBySwitch: [Int64: Set<UInt16>] = [:]
        for (deviceID, switchID) in regionOwner {
            guard let device = nodeByID[deviceID]?.device else { continue }
            vendorsBySwitch[switchID, default: []].insert(device.vendorID)
        }

        // Top-down, and the vendor sets are frozen from step 3: a device placed
        // here never widens a set and so never seeds a further inference.
        if allAnchored, !vendorsBySwitch.isEmpty {
            // `blocked` carries the contested finding down the subtree. A hub two
            // chain devices both named is upstream of both, so every device under
            // it is inside one of them and nothing here can say which: a vendor
            // mark on the hub OR on anything below it is a guess. Direct evidence
            // still wins inside that subtree, because `regionRoots` is consulted
            // first and a structural mark there was never in dispute.
            //
            // Found by a re-verification pass after the first attempt at this
            // guard, which only required every chain device to hold a region
            // somewhere. That is necessary but not sufficient: when the two
            // devices sharing a disputed hub each hold a second region elsewhere,
            // the gate opens legitimately and the disputed hub, still unowned, was
            // handed to an unrelated third device along with everything inside it.
            func vendorDescend(_ node: USBDeviceNode, _ inherited: Int64?, _ blocked: Bool) {
                let blockedHere = blocked || contested.contains(node.device.id)
                var owner = regionRoots[node.device.id] ?? inherited
                if owner == nil, !blockedHere {
                    let matches = vendorsBySwitch.filter { $0.value.contains(node.device.vendorID) }
                    // Exactly one candidate, or none: a vendor in two sets
                    // discriminates nothing, so the device stays put.
                    if matches.count == 1, let switchID = matches.keys.first {
                        owner = switchID
                        regionRoots[node.device.id] = switchID
                    }
                }
                if let owner { regionOwner[node.device.id] = owner }
                for child in node.children { vendorDescend(child, owner, blockedHere) }
            }
            for root in forest { vendorDescend(root, nil, false) }
        }

        // 5. Drop redundant marks: a region root whose nearest marked ancestor
        // has the same owner adds nothing, because inheritance already covers
        // its subtree. Left in, it would render that subtree TWICE in the
        // expanded view, once inside its ancestor and once as a region of its
        // own.
        //
        // Reachable, not theoretical: a CalDigit dock publishes both
        // `TS5 USB 3 Hub` (a hub, which marks itself) and
        // `CalDigit TS5 Audio - Rear` (an endpoint one level further in, which
        // marks the hub it hangs off). Two matches, same chain device, nested.
        // Decided against the marks as they stood, not against a set being
        // mutated underneath the loop: with a three-deep nest, each level has to
        // be judged against its real nearest ancestor rather than one that a
        // previous iteration has already removed.
        let marked = regionRoots
        for (id, owner) in marked {
            // `seen` is what makes this walk provably terminate: each pass either
            // stops or adds a new id to a finite set. `parentOf` is keyed by IOKit
            // entry ID rather than locationID, and while the forest itself cannot
            // contain a cycle (`parentLocationID` clears a nibble, so the path
            // strictly shortens), two devices arriving with the SAME entry ID
            // would collide in this map and could form one. A hang in the menu
            // bar app's render path is the worst outcome available here, so it is
            // ruled out structurally rather than assumed away.
            var seen: Set<UInt64> = [id]
            var cursor = parentOf[id]
            while let ancestor = cursor, !seen.contains(ancestor) {
                seen.insert(ancestor)
                if let ancestorOwner = marked[ancestor] {
                    if ancestorOwner == owner { regionRoots[id] = nil }
                    break
                }
                cursor = parentOf[ancestor]
            }
        }

        // 6. Absorbed: the final identity decision for each exact-name
        // match, not the raw `exact` dictionary. Two differences from a bare
        // `Set(exact.keys)`:
        //
        // - `claimTarget` is re-run here (its numeric-identity correction is
        //   already baked into `regionOwner`/`regionRoots` via `marks(from:
        //   exact)` above; re-deriving it is what makes this the FINAL
        //   decision rather than the raw name match, even though today it
        //   always succeeds when `nodeByID[deviceID]` exists, which it does
        //   for every key in `exact` by construction).
        // - A device flagged `structurallyConflicted` above (its own
        //   structural depth evidence disagreed with this SAME exact match)
        //   is explicitly excluded: its name/numeric placement is kept
        //   (unaffected, it was never removed from `exact` or from
        //   `marks(from: exact)`), but it is not collapsed into the chain
        //   row as though there were no doubt about its identity. See the
        //   precedence-safety note on the structural pass above.
        var absorbed: Set<UInt64> = []
        for (deviceID, switchID) in exact {
            guard !structurallyConflicted.contains(deviceID),
                  claimTarget(deviceID, claimedBy: switchID) != nil
            else { continue }
            absorbed.insert(deviceID)
        }

        return ChainDeviceAttribution(
            regionOwner: regionOwner,
            regionRoots: regionRoots,
            absorbed: absorbed,
            allAnchored: allAnchored
        )
    }

    /// Whether a USB product name and a fabric model name name the same product
    /// family: one's words appear as a contiguous run inside the other's.
    ///
    /// Word-level, not substring, in both directions. `TS5` matches
    /// `TS5 USB 3 Hub` (the DROM carries the short name, the USB descriptors the
    /// long one) and `Thunderbolt Display` matches `Apple Thunderbolt Display`
    /// (the other way round), while `TS5` correctly fails against `ATS5000`.
    static func affiliated(product: String, model: String) -> Bool {
        let p = matchWords(product)
        let m = matchWords(model)
        guard !p.isEmpty, !m.isEmpty else { return false }
        return contains(p, m) || contains(m, p)
    }

    /// Whole words, punctuation dropped, so `Thunderbolt(TM) 4 Dock` and
    /// `Thunderbolt (TM) 4 Dock` compare equal and `USB2.0` splits the same way
    /// on both sides.
    private static func matchWords(_ name: String) -> [String] {
        name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }

    /// Whitespace-collapsed, case-folded name for matching a USB product name
    /// against a fabric model name. Internal punctuation is kept: it is part of
    /// the name ("10-in-1") and dropping it would let unrelated names collide.
    static func normalized(_ name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }
}
