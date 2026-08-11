import Foundation
import IOKit
import WhatCableCore

// `SMCPortPowerChannel` and `SMCSystemPowerInput` used to live here. They are
// plain values with no platform dependency, so they moved to
// `WhatCableCore/Power/SMCPortPowerChannel.swift`: the pure per-port merge in
// Core takes an SMC channel as input, and Core cannot import IOKit.

/// Reads the SMC per-port power channels via the AppleSMC user client.
///
/// This is the app's first SMC read. Every other watcher reads IOKit registry
/// *properties*; this opens a user client (`IOServiceOpen` on `AppleSMC`) and
/// calls a struct method, the long-standing public ABI used by powermetrics,
/// smcFanControl and libsmc. The main app is not sandboxed, so a hardened-
/// runtime Developer ID build is allowed to do this. If the open ever fails
/// (entitlements change, no AppleSMC), every method degrades to "no data"
/// rather than crashing, and the Power Monitor falls back to its no-per-port
/// state.
///
/// Read-only: it only ever reads keys, never writes.
public final class SMCPowerReader {
    private var connection: io_connect_t = 0

    public init() {
        // The kernel reads this struct at fixed C offsets and rejects any other
        // size. Catch a layout regression during development (assert is a
        // debug-build check). In release a bad layout would make the kernel
        // calls fail, and the reader already degrades to no data, so users get
        // the no-per-port fallback rather than a crash.
        assert(
            MemoryLayout<SMCParamStruct>.stride == 80,
            "SMCParamStruct must be 80 bytes to match the AppleSMC ABI, got \(MemoryLayout<SMCParamStruct>.stride)"
        )
    }

    deinit { close() }

    /// Opens the AppleSMC user client. Idempotent: a no-op once open. Returns
    /// false when AppleSMC is missing or the open is refused.
    @discardableResult
    public func open() -> Bool {
        if connection != 0 { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == KERN_SUCCESS else { return false }
        connection = conn
        return true
    }

    public func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    /// Reads channels `D1..D4`. Opens lazily. Returns `[]` when the SMC can't
    /// be opened or the keys aren't present (older silicon, Mac Pro). A channel
    /// is only returned when it has a usable `DxUI`, since without it the
    /// channel can't be tied to a port.
    public func readPortPowerChannels() -> [SMCPortPowerChannel] {
        guard open() else { return [] }
        var channels: [SMCPortPowerChannel] = []
        for index in 1...4 {
            guard let uuid = readUUID("D\(index)UI"), !uuid.isEmpty else { continue }
            let volts = readFloat("D\(index)JV") ?? 0
            let amps = readFloat("D\(index)JI") ?? 0
            let present = (readUInt8("D\(index)PR") ?? 0) >= 1
            channels.append(SMCPortPowerChannel(
                channel: index,
                present: present,
                volts: Double(volts),
                amps: Double(amps),
                uuid: uuid
            ))
        }
        return channels
    }

    /// Reads the Mac's DC-in power input (`VD0R` / `ID0R` / `PDTR`). Opens
    /// lazily. Returns `nil` when the SMC can't be opened or neither voltage nor
    /// current is present (so callers leave the input card blank rather than
    /// inventing a reading). Watts prefers the dedicated `PDTR` total and falls
    /// back to `volts * amps`.
    ///
    /// Unlike per-port metering, this works on every supported desktop including
    /// M1/M2 Mac minis (the DC-in keys don't depend on the per-port UUID map).
    public func readSystemPowerInput() -> SMCSystemPowerInput? {
        guard open() else { return nil }
        let volts = readFloat("VD0R")
        let amps = readFloat("ID0R")
        guard volts != nil || amps != nil else { return nil }
        let pdtr = readFloat("PDTR")
        let watts = pdtr ?? ((volts ?? 0) * (amps ?? 0))
        return SMCSystemPowerInput(
            volts: Double(volts ?? 0),
            amps: Double(amps ?? 0),
            watts: Double(watts),
            pdtrIsMeasured: pdtr != nil
        )
    }

    /// Reads the negotiated charging contract on channels `D1..D4`.
    ///
    /// Opens lazily. Returns `[]` when the SMC can't be opened or the keys are
    /// absent, which includes every desktop: `DxMP`/`DxMV`/`DxMI` are missing on
    /// all 83 desktops in the probe corpus while the power-out keys next door
    /// are present and working.
    ///
    /// A channel is only returned when it has a usable `DxUI` (without it
    /// nothing can be tied to a port) and a positive power figure.
    public func readPortContracts() -> [SMCPortContract] {
        guard open() else { return [] }
        var contracts: [SMCPortContract] = []
        for index in 1...4 {
            guard let uuid = readUUID("D\(index)UI"), !uuid.isEmpty else { continue }
            let powerMW = readBigEndianInt("D\(index)MP") ?? 0
            guard powerMW > 0 else { continue }
            contracts.append(SMCPortContract(
                channel: index,
                uuid: uuid,
                powerMW: powerMW,
                voltageMV: readBigEndianInt("D\(index)MV") ?? 0,
                currentMA: readBigEndianInt("D\(index)MI") ?? 0,
                label: readString("D\(index)DE") ?? ""
            ))
        }
        return contracts
    }

    /// Live battery discharge power in milliwatts, read from the SMC battery
    /// rail (`PPBR`). Opens lazily. Returns `nil` when the SMC can't be opened,
    /// the key is absent (a desktop has no battery rail), or the value is
    /// implausible.
    ///
    /// Why this exists: on Apple Silicon, `AppleSmartBattery`'s `BatteryPower` /
    /// `SystemLoad` do not update under load (the fuel gauge holds a value for
    /// tens of seconds), so a battery-discharge figure read from there sits
    /// stale. `PPBR` is the live battery rail (updates ~1 Hz, tracks load);
    /// confirmed on M5 Pro and present on every Apple Silicon laptop generation
    /// in the probe corpus. Callers prefer this on battery and fall back to the
    /// gauge when it returns `nil`.
    public func readBatteryPowerMW() -> Int? {
        guard open() else { return nil }
        guard let watts = readFloat("PPBR") else { return nil }
        // Guard against an absent/garbage key: real discharge is a few watts to
        // tens of watts (the highest Apple Silicon MacBook draws well under 100 W
        // sustained, so 200 W is a safe ceiling). Anything negative or above it
        // means the wrong key on this silicon; fall back to the gauge.
        guard watts >= 0, watts < 200 else { return nil }
        return Int((Double(watts) * 1000).rounded())
    }

    // MARK: - Key reads

    /// `flt` keys (`DxJV`, `DxJI`): a 4-byte IEEE float in native (little-
    /// endian) byte order on Apple Silicon, so the bytes load straight into a
    /// `Float` bit pattern.
    private func readFloat(_ key: String) -> Float? {
        guard let bytes = readKey(key) else { return nil }
        return Self.decodeFloat(bytes)
    }

    /// Decode an SMC `flt` payload. Returns nil for short payloads and for
    /// non-finite values (infinity, NaN). An uninitialised or garbage SMC
    /// channel can carry an inf/NaN bit pattern; letting it through would
    /// reach `Int(...)` unit conversions downstream, which trap on
    /// non-finite doubles. nil makes the callers' `?? 0` fallbacks handle
    /// it like any other absent reading. Internal (not private) so the
    /// decode is unit-testable without SMC hardware.
    static func decodeFloat(_ bytes: [UInt8]) -> Float? {
        guard bytes.count >= 4 else { return nil }
        let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let value = Float(bitPattern: bits)
        return value.isFinite ? value : nil
    }

    /// Integer keys (`DxMP` ui32, `DxMV` / `DxMI` ui16): BIG-endian, unlike the
    /// float keys in the same channel, which are native little-endian.
    ///
    /// Getting this backwards does not produce a subtly wrong number, it
    /// produces a preposterous one: the reporter's 20000 mV contract read
    /// little-endian is 553,648,128. Worth stating because the float decoder
    /// sits a few lines away and is the obvious thing to reach for.
    ///
    /// Internal (not private) so the decode is unit-testable without SMC
    /// hardware, against the reporter's own captured bytes.
    static func decodeBigEndianInt(_ bytes: [UInt8]) -> Int? {
        guard !bytes.isEmpty, bytes.count <= 8 else { return nil }
        return bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    private func readBigEndianInt(_ key: String) -> Int? {
        guard let bytes = readKey(key) else { return nil }
        return Self.decodeBigEndianInt(bytes)
    }

    /// `ch8*` keys (`DxDE`): a fixed-width NUL-padded label.
    private func readString(_ key: String) -> String? {
        guard let bytes = readKey(key) else { return nil }
        let trimmed = Array(bytes.prefix { $0 != 0 })
        guard !trimmed.isEmpty else { return "" }
        return String(decoding: trimmed, as: UTF8.self)
    }

    /// `ui8` keys (`DxPR`): a single byte.
    private func readUInt8(_ key: String) -> UInt8? {
        guard let bytes = readKey(key), let first = bytes.first else { return nil }
        return first
    }

    /// `hex_` keys (`DxUI`): 16 raw bytes, returned as 32 lowercase hex chars
    /// to match the dash-stripped `AppleHPMDeviceHALType3.UUID` string.
    private func readUUID(_ key: String) -> String? {
        guard let bytes = readKey(key), !bytes.isEmpty else { return nil }
        // A channel with no controller reads all-zero here; treat as absent.
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - SMC ABI

    /// Reads one SMC key's raw bytes: first ask for its size and type, then
    /// read the value (the same two-step the C probe uses).
    private func readKey(_ key: String) -> [UInt8]? {
        guard let fourCC = Self.fourCC(key) else { return nil }

        var info = SMCParamStruct()
        info.key = fourCC
        info.data8 = Self.cmdGetKeyInfo
        guard let infoOut = callDriver(&info) else { return nil }
        let size = infoOut.keyInfo.dataSize
        guard size > 0 else { return nil }

        var read = SMCParamStruct()
        read.key = fourCC
        read.keyInfo.dataSize = size
        read.keyInfo.dataType = infoOut.keyInfo.dataType
        read.data8 = Self.cmdReadKey
        guard let readOut = callDriver(&read) else { return nil }

        let count = Int(min(size, 32))
        var value = readOut.bytes
        return withUnsafeBytes(of: &value) { Array($0.prefix(count)) }
    }

    private func callDriver(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        guard connection != 0 else { return nil }
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(
            connection,
            Self.kernelIndex,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        return kr == KERN_SUCCESS ? output : nil
    }

    /// Packs a 4-character key into its FourCC `UInt32` (MSB first).
    static func fourCC(_ key: String) -> UInt32? {
        let scalars = Array(key.unicodeScalars)
        guard scalars.count == 4 else { return nil }
        var value: UInt32 = 0
        for scalar in scalars {
            guard scalar.value <= 0xFF else { return nil }
            value = (value << 8) | UInt32(scalar.value)
        }
        return value
    }

    private static let kernelIndex: UInt32 = 2
    private static let cmdReadKey: UInt8 = 5
    private static let cmdGetKeyInfo: UInt8 = 9
}

// MARK: - AppleSMC user-client ABI structs
//
// These mirror the C layout used by powermetrics / smcFanControl byte-for-byte.
// Field order and types must not change: the kernel reads this struct at fixed
// offsets. `MemoryLayout<SMCParamStruct>.stride` must be 80 bytes.

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

/// A 32-byte payload buffer as a homogeneous tuple (the C `char bytes[32]`).
private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimit = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    // C keeps `keyInfo`'s 3-byte trailing padding before `result`; Swift would
    // otherwise pack `result` into it and shrink the struct to 76 bytes, which
    // the kernel rejects. This explicit pad restores the C offsets so the total
    // is 80 (asserted in `init()`).
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}
