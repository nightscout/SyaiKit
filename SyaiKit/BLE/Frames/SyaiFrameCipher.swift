//
//  SyaiFrameCipher.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

public enum SyaiFrameCipher {
    public enum CipherError: Error, CustomStringConvertible {
        case emptyFrame
        case notBlockAligned(Int)
        case shortOrg(Int)
        public var description: String {
            switch self {
            case .emptyFrame: return "frame: empty notify value"
            case let .notBlockAligned(n): return "frame: \(n) bytes has no whole AES block"
            case let .shortOrg(n): return "frame: org value \(n) bytes < 8-byte header"
            }
        }
    }

    public static let headerWidth = 8

    public struct Record: Equatable {
        public let index: UInt16
        public let framed: Data
    }

    public struct PacketInfo: Equatable, Sendable {
        public let crc: UInt16
        public let errorCode: UInt16
        public let startIndex: UInt16

        /// `-1`: non-paged (live push / connect burst). `N >= 1`: a paged history
        /// packet with `N` more still coming. `0`: the final packet of a paged batch.
        public let surplusPackage: Int16
        public var isBatchComplete: Bool { surplusPackage <= 0 }
    }

    public static func packetInfo(org: Data) throws -> PacketInfo {
        guard org.count >= headerWidth else { throw CipherError.shortOrg(org.count) }
        let crc = UInt16(org[0]) | (UInt16(org[1]) << 8)
        let errorCode = UInt16(org[2]) | (UInt16(org[3]) << 8)
        let startIndex = UInt16(org[4]) | (UInt16(org[5]) << 8)
        let surplusRaw = UInt16(org[6]) | (UInt16(org[7]) << 8)
        return PacketInfo(
            crc: crc,
            errorCode: errorCode,
            startIndex: startIndex,
            surplusPackage: Int16(bitPattern: surplusRaw)
        )
    }

    /// `recLen` for a parse version: 9 for V1.7, else the default 8.
    public static func recordLength(parseVersion: String) -> Int {
        parseVersion == "V1.7" ? 9 : 8
    }

    public static func decryptOrg(
        notify: Data,
        sessionKey: Data,
        aes: AESECB = AESECB()
    ) throws -> Data {
        guard !notify.isEmpty else { throw CipherError.emptyFrame }
        let aligned = notify.count - (notify.count % 16)
        guard aligned >= 16 else { throw CipherError.notBlockAligned(notify.count) }
        let blocks = notify.prefix(aligned)
        return try aes.decryptECB(Data(blocks), key: sessionKey, padding: false)
    }

    public static func split(org: Data, recLen: Int) throws -> [Record] {
        guard org.count >= headerWidth else { throw CipherError.shortOrg(org.count) }
        let base = UInt16(org[4]) | (UInt16(org[5]) << 8) // baseIndex LE16
        let body = org.dropFirst(headerWidth)
        var records: [Record] = []
        var n = 0
        var i = body.startIndex
        while i + recLen <= body.endIndex {
            let data = body[i ..< i + recLen]
            let index = base &+ UInt16(n)
            n += 1
            i += recLen
            if data.allSatisfy({ $0 == 0 }) { continue } // zero padding slot
            var framed = Data([0x00, 0x00])
            framed.append(UInt8(index & 0xFF))
            framed.append(UInt8((index >> 8) & 0xFF))
            framed.append(contentsOf: data)
            records.append(Record(index: index, framed: framed))
        }
        return records
    }
}
