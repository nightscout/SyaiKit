//
//  SyaiFrameParser.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// Lifts a decrypted record into the raw channels `V0..V2`. Only V1.6 and V1.7 have
/// hardware-verified byte-windows; every other version throws so a plausible-but-wrong
/// glucose never reaches the loop.
public enum SyaiFrameParser {
    public enum ParseError: Error, CustomStringConvertible {
        /// This parse version's byte-windows aren't hardware-verified,
        /// so no reading is produced rather than guessing.
        case notVerified
        case shortRecord(Int)
        public var description: String {
            switch self {
            case .notVerified:
                return "glucose decode is gated: this parse version's byte-windows are not "
                    + "hardware-verified (only V1.6 and V1.7 are), so no reading "
                    + "is produced (safety gate, see SyaiFrameParser)."
            case let .shortRecord(n):
                return "frame record too short (\(n) bytes) for the parsed fields"
            }
        }
    }

    /// V1.8 and V2.0 firmware parse as V1.7: the vendor's own version profiles
    /// give both parse version V1.7 with 9-byte records.
    public static func parseVersion(forDeviceVersion version: String) -> String {
        if version.contains("V1.7") || version.contains("V1.8.") || version.contains("V2.0.") { return "V1.7" }
        if version.contains("V1.6") { return "V1.6" }
        return "V1.5"
    }

    /// Whether readings from this parse version can be decoded at all.
    public static func isVerified(parseVersion: String) -> Bool {
        parseVersion == "V1.7" || parseVersion == "V1.6"
    }

    public static func rawChannels(
        from frame: SyaiDecryptedFrame,
        using parser: SyaiFrameParsing
    ) throws -> SyaiGlucoseDecoder.RawChannels {
        try parser.rawChannels(fromFramedRecord: frame.plaintext, parseVersion: frame.parseVersion)
    }

    /// The per-record log line: everything needed to replay the decode offline.
    /// `seq`/`ver`/`raw` keep the `[RPNFIX]` shape the capture tooling parses.
    public static func captureLine(for frame: SyaiDecryptedFrame) -> String {
        let hex = frame.plaintext.map { String(format: "%02x", $0) }.joined()
        let source = frame.isHistorical ? "bf" : "rt"
        return "[RPNFIX] seq=\(frame.sequence) ver=\(frame.parseVersion) raw=\(hex) src=\(source)"
    }
}

public protocol SyaiFrameParsing: Sendable {
    func rawChannels(
        fromFramedRecord record: Data,
        parseVersion: String
    ) throws -> SyaiGlucoseDecoder.RawChannels
}

/// V1.7 framed record: `[00 00] ‖ index(2 LE) ‖ d(9)`. Windows over `d`:
///
///   - `V0 = current`     = `LE24(d[0:3]) & 0x3FFFF`
///   - `V2 = runSec`      = `LE24(d[4:7]) >> 2`
///   - `V1 = temperature` = `LE16(d[7:9]) / 100.0`
///
/// `d[3]` is carried but not interpreted.
///
/// Other parse versions delegate to `fallback`.
public struct SyaiV17FrameParsing: SyaiFrameParsing {
    private let fallback: SyaiFrameParsing
    public init(fallback: SyaiFrameParsing = SyaiUnverifiedFrameParsing()) {
        self.fallback = fallback
    }

    public func rawChannels(
        fromFramedRecord record: Data,
        parseVersion: String
    ) throws -> SyaiGlucoseDecoder.RawChannels {
        guard parseVersion == "V1.7" else {
            return try fallback.rawChannels(fromFramedRecord: record, parseVersion: parseVersion)
        }
        let d = record.dropFirst(4) // strip `[00 00] ‖ index(2 LE)`: the 9-byte record `d`
        guard d.count >= 9 else { throw SyaiFrameParser.ParseError.shortRecord(record.count) }
        let b = [UInt8](d.prefix(9))
        let current = (UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16) & 0x3FFFF
        let runSec = (UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16) >> 2
        let temp = UInt32(b[7]) | UInt32(b[8]) << 8
        return SyaiGlucoseDecoder.RawChannels(
            v0: Double(current), v1: Double(temp) / 100.0, v2: Double(runSec)
        )
    }
}

/// V1.6 framed record: `[00 00] ‖ index(2 LE) ‖ d(8)`. Windows over `d`:
///
///   - `V0 = current`     = `LE16(d[0:2])`
///   - `V2 = runSec`      = `LE32(d[4:8]) & 0x3FFFFF`
///   - `V1 = temperature` = `(LE32(d[4:8]) >> 22) / 10.0`
///
/// `LE16(d[2:4])` packs the sensor's own glucose copy and voltage but isn't consumed
/// here.
///
/// `runSec` is read straight from the frame, not derived from `index`: a 16-bit read
/// of the same field wraps every ~18.2 h and would silently produce a stale elapsed
/// time past that point.
///
/// Other parse versions delegate to `fallback`.
public struct SyaiV16FrameParsing: SyaiFrameParsing {
    private let fallback: SyaiFrameParsing
    public init(fallback: SyaiFrameParsing = SyaiUnverifiedFrameParsing()) {
        self.fallback = fallback
    }

    public func rawChannels(
        fromFramedRecord record: Data,
        parseVersion: String
    ) throws -> SyaiGlucoseDecoder.RawChannels {
        guard parseVersion == "V1.6" else {
            return try fallback.rawChannels(fromFramedRecord: record, parseVersion: parseVersion)
        }
        let d = record.dropFirst(4) // strip `[00 00] ‖ index(2 LE)`: the 8-byte record `d`
        guard d.count >= 8 else { throw SyaiFrameParser.ParseError.shortRecord(record.count) }
        let b = [UInt8](d.prefix(8))
        let current = UInt32(b[0]) | UInt32(b[1]) << 8
        // time+temp share one 32-bit field: time is the low 22 bits, temperature the
        // 10 bits above it (not two separate 16-bit windows).
        let timeAndTemp = UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24
        let runSec = timeAndTemp & 0x3FFFFF
        let temp = timeAndTemp >> 22
        return SyaiGlucoseDecoder.RawChannels(
            v0: Double(current), v1: Double(temp) / 10.0, v2: Double(runSec)
        )
    }
}

public struct SyaiUnverifiedFrameParsing: SyaiFrameParsing {
    public init() {}
    public func rawChannels(
        fromFramedRecord _: Data,
        parseVersion _: String
    ) throws -> SyaiGlucoseDecoder.RawChannels {
        throw SyaiFrameParser.ParseError.notVerified
    }
}
