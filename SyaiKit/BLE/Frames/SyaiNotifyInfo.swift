//
//  SyaiNotifyInfo.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

public enum SyaiNotifyInfo {
    public struct Event: Equatable, Sendable {
        public let tick: UInt32
        public let reason: UInt32
        public let lastStatus: UInt32?
        public var tickSeconds: Double { Double(tick) / 4.0 }
    }

    public enum Content: Equatable, Sendable {
        /// `0x7704` "disconnect_info".
        case disconnectLog([Event])
        /// `0x7705` "reboot_info".
        case rebootLog([Event])
        /// `0x7707` "delay"/"interval"/"timeout" (BLE transmission timing config).
        case intervalInfo(interval: UInt16?, delay: UInt16?, timeout: UInt16?)
        /// `0x7708` "coefficient_info": the sensor echoing back a coefficient block.
        /// `crc` is the trailing CRC16-Modbus when one is present, and `crcOK` whether
        /// it verifies over the float bytes. See the `0x7708` note on `decode`.
        case coefficients([Float], crc: UInt16?, crcOK: Bool)
        /// `0x7709` "state_info": a UTF-8 status string.
        case stateText(String)
        /// `0x7706`, and any unrecognised header (`transContentCommon`): one integer.
        case value(UInt64)
        /// `0x770A`: raw hex passthrough by design (the app does the same).
        case rawHex(String)
        /// A body that didn't fit its header's expected shape. Distinct from
        /// `.rawHex` so the log says "we failed to parse this" rather than implying
        /// the frame is meant to be opaque.
        case malformed(header: UInt16, hex: String)
    }

    public struct Frame: Equatable, Sendable {
        public let header: UInt16
        public let content: Content
        /// The whole frame verbatim, mirroring the app's `orgHex`. Always kept so a
        /// misparse can still be recovered from the log.
        public let orgHex: String
    }

    public static func reasonName(_ reason: UInt32) -> String {
        switch reason {
        case 0x1008: return "orderly" // healthy session ending, NOT an error
        case 0x1013: return "abnormal/early" // firmware watchdog kick; link never reached healthy streaming
        case 0x1016: return "central-side" // host dropped the link (tentative)
        default: return String(format: "0x%04x", reason)
        }
    }

    public static func decode(_ data: Data) -> Frame? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let header = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let body = Array(bytes.dropFirst(2))
        return Frame(header: header, content: content(header: header, body: body), orgHex: hex(bytes))
    }

    private static func content(header: UInt16, body: [UInt8]) -> Content {
        switch header {
        case 0x7704:
            guard !body.isEmpty, body.count % 8 == 0 else { return .malformed(header: header, hex: hex(body)) }
            return .disconnectLog(stride(from: 0, to: body.count, by: 8).map {
                Event(tick: le32(body, $0), reason: le32(body, $0 + 4), lastStatus: nil)
            })

        case 0x7705:
            guard !body.isEmpty, body.count % 12 == 0 else { return .malformed(header: header, hex: hex(body)) }
            return .rebootLog(stride(from: 0, to: body.count, by: 12).map {
                Event(tick: le32(body, $0), reason: le32(body, $0 + 4), lastStatus: le32(body, $0 + 8))
            })

        case 0x7707:
            // Long form is 6 bytes; the sensor also emits a 2-byte short form with
            // just the interval.
            switch body.count {
            case 6: return .intervalInfo(interval: le16(body, 0), delay: le16(body, 2), timeout: le16(body, 4))
            case 2: return .intervalInfo(interval: le16(body, 0), delay: nil, timeout: nil)
            default: return .malformed(header: header, hex: hex(body))
            }

        case 0x7708:
            // Float32 records, plus a 2-byte trailing CRC16-Modbus when the block was
            // echoed from a `writeCoefficientList` frame (the only case observed).
            let hasCRC = body.count % 4 == 2
            let floatBytes = hasCRC ? body.count - 2 : body.count
            guard floatBytes > 0, floatBytes % 4 == 0 else { return .malformed(header: header, hex: hex(body)) }
            let values = stride(from: 0, to: floatBytes, by: 4).map {
                Float(bitPattern: be32(body, $0))
            }
            var crc: UInt16?
            var crcOK = false
            if hasCRC {
                let observed = le16(body, floatBytes) // appended lo, hi
                crc = observed
                // The echoed CRC covers the ORIGINAL write frame, including the
                // opcode and count byte that the echo itself strips: the sensor is
                // replaying the CRC it was sent, not recomputing one. 0x09 is
                // `SyaiActivationFrame.opCoefficient`, inlined to keep this
                // diagnostics type free of write-path dependencies.
                let original = [0x09, UInt8(values.count)] + body[0 ..< floatBytes]
                crcOK = CRC16.modbus(original) == observed
            }
            return .coefficients(values, crc: crc, crcOK: crcOK)

        case 0x7709:
            return .stateText(String(decoding: body, as: UTF8.self))

        case 0x770A:
            return .rawHex(hex(body))

        default:
            // 0x7706 and `transContentCommon`: a single integer. Guarded so an
            // unexpectedly long body can't overflow; it falls back to hex.
            guard !body.isEmpty, body.count <= 8 else { return .malformed(header: header, hex: hex(body)) }
            var v: UInt64 = 0
            for (i, b) in body.enumerated() { v |= UInt64(b) << (8 * i) }
            return .value(v)
        }
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
    }

    private static func hex(_ b: [UInt8]) -> String {
        b.map { String(format: "%02x", $0) }.joined()
    }
}

public extension SyaiNotifyInfo.Frame {
    var logDescription: String {
        let head = String(format: "0x%04x", header)
        return "errorInfo \(head) \(content.logDescription)  [raw \(orgHex)]"
    }
}

public extension SyaiNotifyInfo.Content {
    var logDescription: String {
        switch self {
        case let .disconnectLog(events):
            let body = events.map {
                "tick=\($0.tick)(\(String(format: "%.1f", $0.tickSeconds))s) reason=\(SyaiNotifyInfo.reasonName($0.reason))"
            }.joined(separator: ", ")
            return "disconnect_info \(events.count) event(s): \(body)"

        case let .rebootLog(events):
            let body = events.map {
                "tick=\($0.tick) reason=\(SyaiNotifyInfo.reasonName($0.reason)) lastStatus=\($0.lastStatus.map(String.init) ?? "-")"
            }.joined(separator: ", ")
            return "reboot_info \(events.count) event(s): \(body)"

        case let .intervalInfo(interval, delay, timeout):
            let parts = [
                interval.map { "interval=\($0)" },
                delay.map { "delay=\($0)" },
                timeout.map { "timeout=\($0)" }
            ].compactMap { $0 }
            return "interval_info \(parts.joined(separator: " "))"

        case let .coefficients(values, crc, crcOK):
            let tail = crc.map { String(format: " crc=0x%04x %@", $0, crcOK ? "ok" : "MISMATCH") } ?? ""
            return "coefficient_info(BE) \(values.count) value(s): "
                + "\(values.map { String($0) }.joined(separator: ","))\(tail)"

        case let .stateText(text):
            return "state_info \"\(text)\""

        case let .value(v):
            return "value \(v) (0x\(String(v, radix: 16)))"

        case let .rawHex(h):
            return "raw \(h)"

        case let .malformed(header, h):
            return String(format: "MALFORMED body for header 0x%04x: ", header) + h
        }
    }
}
