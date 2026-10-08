//
//  SyaiBLEAuthV2.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import CryptoKit
import Foundation

public enum SyaiBLEAuthV2 {
    private static let logger = SyaiLogger(category: "BLEAuth")

    public enum AuthError: Error, CustomStringConvertible {
        case badKeyGroup(Int)
        case shortDeviceBlob(Int)
        case badDevicePubkey
        case badDeviceSignature
        public var description: String {
            switch self {
            case let .badKeyGroup(n): return "auth: key group is \(n) bytes, expected 96 (6x16)"
            case let .shortDeviceBlob(n): return "auth: device param blob too short (\(n) bytes)"
            case .badDevicePubkey: return "auth: device P-256 public key invalid"
            case .badDeviceSignature: return "auth: device sign mismatch, peer does not hold the key group"
            }
        }
    }

    public enum Layout {
        /// `authHost` (app->device, 68 B): `idx(2 LE) ‖ index(2 LE) ‖ pubX(32) ‖ pubY(32 FULL)`.
        public static let authHostBlobSize = 68

        /// `authHost` `idx` field width (LE u16). 2.
        public static let idxWidth = 2

        /// `authHost` `index` field width. 2.
        public static let indexWidth = 2

        /// `authDev` (device->app, 68 B): `idx(1) ‖ time(3) ‖ pubX(32) ‖ pubY(32)`,
        /// no header, no 2-byte index field, pubY not truncated.
        public static let authDevBlobSize = 68

        /// `authDev` `time` field width. 3.
        public static let timeWidth = 3

        /// P-256 public coordinate width. 32.
        public static let coordWidth = 32
    }

    /// AES-128 session key from the 32-byte ECDH shared secret X: the odd-indexed
    /// bytes `secretX[1::2]` = bytes {1,3,...,31}. No KDF.
    public static func sessionKey(fromSharedSecretX x: Data) -> Data {
        var out = Data(capacity: 16)
        var i = 1
        let bytes = [UInt8](x)
        while i < bytes.count { out.append(bytes[i])
            i += 2 }
        return out
    }

    public static func key(_ idx: Int, in keyGroup: SyaiKeyGroup) throws -> Data {
        let raw = keyGroup.raw
        guard raw.count == 96 else { throw AuthError.badKeyGroup(raw.count) }
        let start = raw.startIndex + (idx % 6) * 16
        return raw.subdata(in: start ..< start + 16)
    }

    public static func macBytes(_ mac: String) -> Data {
        var out = Data(capacity: 6)
        let chars = Array(mac)
        var i = 0
        while i + 1 < chars.count {
            if let b = UInt8(String(chars[i ... i + 1]), radix: 16) { out.append(b) }
            i += 2
        }
        return out
    }

    /// App-signature digest written to authFlag: `SHA256(cx ‖ MAC ‖ pubX ‖ pubY ‖ currentTimeRaw)`.
    /// `cx` first; `currentTimeRaw` is the full 3-byte currentTime read.
    public static func appSignature(
        cx: Data,
        mac: Data,
        pubX: Data,
        pubY: Data,
        currentTimeRaw: Data
    ) -> Data {
        var preimage = Data()
        preimage.append(cx)
        preimage.append(mac)
        preimage.append(pubX)
        preimage.append(pubY)
        preimage.append(currentTimeRaw)
        return Data(SHA256.hash(data: preimage))
    }

    /// The authFlag digest preimage's 3-byte encoding of the currentTime counter:
    /// `00 ‖ wire[0] ‖ wire[1]` of the 4-byte LE wire read, NOT the raw 4-byte value
    /// (feeding the raw 4-byte read gets the session kicked at the 60 s mark). A
    /// genuine 3-byte read passes through.
    static func currentTimeDigestEncoding(_ wireRead: Data) -> Data {
        let bytes = [UInt8](wireRead)
        if bytes.count == 3 { return Data(bytes) }
        return Data([0x00] + bytes.prefix(2))
    }

    /// App->device blob on authHost (68 B): `idx(2 LE) ‖ index(2 LE) ‖ pubX(32) ‖ pubY(32, FULL)`, no header, pubY not truncated.
    /// `index` is the currentTime counter value itself (`LE16(currentTimeWire[0:2])` as read from the device),
    /// not derived from the authDev time field.
    public static func appParamBlob(
        index: Int,
        idx: Int,
        pubX: Data,
        pubY: Data
    ) -> Data {
        var blob = Data()
        blob.append(intLE(UInt64(idx), width: Layout.idxWidth))
        blob.append(intLE(UInt64(index), width: Layout.indexWidth))
        blob.append(pubX)
        blob.append(pubY) // full 32 bytes, not truncated
        return blob
    }

    /// Parse the device param blob read from authDev (68 B): `idx(1) ‖ time(3) ‖ pubX(32) ‖ pubY(32)`.
    public static func parseDeviceParams(_ blob: Data) throws -> (idx: Int, time: Data, pubX: Data, pubY: Data) {
        let w = Layout.coordWidth
        guard blob.count >= Layout.authDevBlobSize else { throw AuthError.shortDeviceBlob(blob.count) }
        let idx = Int(blob[blob.startIndex]) % 6
        let time = blob[blob.startIndex + 1 ..< blob.startIndex + 1 + Layout.timeWidth]
        let pubX = blob[blob.startIndex + 4 ..< blob.startIndex + 4 + w]
        let pubY = blob[blob.startIndex + 4 + w ..< blob.startIndex + 4 + 2 * w]
        return (idx, Data(time), Data(pubX), Data(pubY))
    }

    private static func intLE(_ value: UInt64, width: Int) -> Data {
        var out = Data(capacity: width)
        for i in 0 ..< width { out.append(UInt8((value >> (8 * i)) & 0xFF)) }
        return out
    }

    /// Run the full V2 handshake against `transport` and return the 16-byte AES-128
    /// session key. Throws on transport failure, an invalid device key, or a device
    /// signature mismatch (the peer proving it does NOT hold the key group).
    public static func authenticate(
        transport: SyaiGATTTransport,
        mac: String,
        keyGroup: SyaiKeyGroup
    ) async throws -> Data {
        let macData = macBytes(mac)
        logger.debug(
            "auth start: mac=\(SyaiRedact.mac(mac)) keyGroup=\(keyGroup.raw.count) B "
                + "(presence/length only, key bytes are never logged)"
        )

        // 1. Device-to-app half: read device params + signature, verify (fatal on mismatch, mirroring `_verifyCGMSign`).
        let deviceBlob = try await transport.read(SyaiGATT.authDev)
        let deviceSign = try await transport.read(SyaiGATT.authFlag)
        let device = try parseDeviceParams(deviceBlob)
        try verifyDeviceSignature(deviceSign, params: device, mac: macData, keyGroup: keyGroup)
        logger.debug(
            "auth device half OK: idx=\(device.idx) time=\(SyaiDiagnostics.hex(device.time)) "
                + "pubX=\(SyaiDiagnostics.hex(device.pubX)) pubY=\(SyaiDiagnostics.hex(device.pubY)) "
                + "sign=\(SyaiDiagnostics.hex(deviceSign)) (verified)"
        )

        // 2. App-to-device half: read the counter (feeds the authFlag digest preimage
        //    AND the authHost `index` field, which is the counter value itself),
        //    build our ephemeral key + the authHost blob.
        let currentTimeRaw = try await transport.read(SyaiGATT.currentTime)

        let appPriv = P256.KeyAgreement.PrivateKey()
        let appPub = appPriv.publicKey.rawRepresentation // 64 B = X(32) ‖ Y(32)
        let pubX = appPub.prefix(32)
        let pubY = appPub.suffix(32)

        let idxApp = Int.random(in: 0 ..< 6)
        let cx = try key(idxApp, in: keyGroup)

        let ctBytes = [UInt8](currentTimeRaw)
        let index = ctBytes.count >= 2 ? Int(ctBytes[0]) | (Int(ctBytes[1]) << 8) : 0
        let blob1 = appParamBlob(
            index: index,
            idx: idxApp,
            pubX: Data(pubX),
            pubY: Data(pubY)
        )
        try await transport.write(blob1, to: SyaiGATT.authHost, withResponse: true)

        let sig = appSignature(
            cx: cx,
            mac: macData,
            pubX: Data(pubX),
            pubY: Data(pubY),
            currentTimeRaw: currentTimeDigestEncoding(currentTimeRaw)
        )
        try await transport.write(sig, to: SyaiGATT.authFlag, withResponse: true)
        logger.debug(
            "auth app half sent: idx=\(idxApp) index=\(index) "
                + "currentTime=\(SyaiDiagnostics.hex(currentTimeRaw)) "
                + "authHost=\(SyaiDiagnostics.hex(blob1)) appSign=\(SyaiDiagnostics.hex(sig))"
        )

        // 3. ECDH to AES-128 session key.
        let devicePub: P256.KeyAgreement.PublicKey
        do {
            devicePub = try P256.KeyAgreement.PublicKey(rawRepresentation: device.pubX + device.pubY)
        } catch { throw AuthError.badDevicePubkey }
        let shared = try appPriv.sharedSecretFromKeyAgreement(with: devicePub)
        let secretX = shared.withUnsafeBytes { Data($0) } // 32 B = shared-secret X
        let derivedKey = sessionKey(fromSharedSecretX: secretX)
        logger.debug("auth complete: session key derived (\(derivedKey.count) B, not logged)")
        return derivedKey
    }

    /// Verify the device proved possession of the key group:
    /// `sign == SHA256(keyGroup[idx] ‖ MAC ‖ pubX ‖ pubY ‖ time)` over the authDev blob fields
    static func verifyDeviceSignature(
        _ sign: Data,
        params: (idx: Int, time: Data, pubX: Data, pubY: Data),
        mac: Data,
        keyGroup: SyaiKeyGroup
    ) throws {
        let cx = try key(params.idx, in: keyGroup)
        var preimage = Data()
        preimage.append(cx)
        preimage.append(mac)
        preimage.append(params.pubX)
        preimage.append(params.pubY)
        preimage.append(params.time)
        guard Data(SHA256.hash(data: preimage)) == sign else { throw AuthError.badDeviceSignature }
    }
}
