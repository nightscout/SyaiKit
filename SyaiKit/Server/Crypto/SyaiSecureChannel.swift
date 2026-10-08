//
//  SyaiSecureChannel.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import CryptoKit
import Foundation

/// The AES-256-GCM envelope wrapping every `api.syai.com` call.
///
/// Session-key split:
///   - GCM key = HKDF[0:32]
///   - HMAC key = HKDF[32:64] (request signature; a missing/wrong one is rejected server-side)
///
/// Stateless static funcs; `seq` and the live session live in `SyaiEnvelopedClient`.
public enum SyaiSecureChannel {
    public static let gcmNonceLength = 12
    public static let aesKeyLength = 32
    public static let exchangePath = "/security/exchangeKey"

    public enum ChannelError: Error, CustomStringConvertible {
        case badServerKey
        case missingField(String)
        case cryptoFailure(String)
        public var description: String {
            switch self {
            case .badServerKey: return "secure channel: server public key wasn't a valid P-256 point"
            case let .missingField(f): return "secure channel: handshake response missing '\(f)'"
            case let .cryptoFailure(m): return "secure channel: \(m)"
            }
        }
    }

    /// Negotiated session: `gcmKey` = HKDF[0:32], `hmacKey` = HKDF[32:64].
    public struct Session: Sendable {
        public let secretId: String
        public let deviceId: String
        public let gcmKey: SymmetricKey
        public let hmacKey: SymmetricKey
        public let expireTime: Int // ms since epoch

        /// AAD = utf8("{deviceId}|{secretId}").
        public var aad: Data { Data("\(deviceId)|\(secretId)".utf8) }
        public var isExpired: Bool { expireTime <= SyaiSecureChannel.nowMillis() }
    }

    /// Pre-envelope cipher fields. The `paramStyle` prefix (`cipherParam*` vs `cipherBody*`) is
    /// chosen by the HTTP layer; metadata headers ride either way.
    public struct Envelope {
        public let text: String // b64(ciphertext)
        public let mac: String // b64(tag)
        public let nonce: String // b64(nonce)
        public let signature: String // b64(HMAC-SHA256)
        public let secretId: String
        public let seq: Int
        public let nonceId: String
        public let timeNow: Int
        public let userId: String
    }

    /// `/security/exchangeKey` request. Generates an ephemeral P-256 keypair; returns the
    /// private key (needed for `deriveSession`) and the plaintext POST body.
    public static func makeExchangeRequest(deviceId: String)
        -> (privateKey: P256.KeyAgreement.PrivateKey, body: [String: Any])
    {
        let priv = P256.KeyAgreement.PrivateKey()
        let raw = priv.publicKey.rawRepresentation // 64 B = X(32) || Y(32)
        let b64x = raw.prefix(32).base64EncodedString()
        let b64y = raw.suffix(32).base64EncodedString()
        let ts = nowMillis()
        // clientSignature = sha256_hex(deviceId + b64X + b64Y + timestamp)
        let preimage = deviceId + b64x + b64y + String(ts)
        let signature = SHA256.hash(data: Data(preimage.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let body: [String: Any] = [
            "clientPubKeyX": b64x,
            "clientPubKeyY": b64y,
            "clientTimestamp": ts,
            "clientSignature": signature
        ]
        return (priv, body)
    }

    /// Derive the session from the `/security/exchangeKey` response
    /// (`serverPubKeyX`/`serverPubKeyY` base64, `secretId`, `expireTime`).
    public static func deriveSession(
        privateKey: P256.KeyAgreement.PrivateKey,
        response: [String: Any],
        deviceId: String
    ) throws -> Session {
        guard let b64x = response["serverPubKeyX"] as? String,
              let b64y = response["serverPubKeyY"] as? String,
              let xData = Data(base64Encoded: b64x), let yData = Data(base64Encoded: b64y)
        else {
            throw ChannelError.missingField("serverPubKeyX/Y")
        }
        guard let secretId = (response["secretId"] as? String) ?? (response["cipherSecretId"] as? String) else {
            throw ChannelError.missingField("secretId")
        }
        let expireTime = intValue(response["expireTime"]) ?? intValue(response["expiresAt"]) ?? 0

        let serverPub: P256.KeyAgreement.PublicKey
        do {
            serverPub = try P256.KeyAgreement.PublicKey(rawRepresentation: xData + yData)
        } catch { throw ChannelError.badServerKey }

        let shared = try privateKey.sharedSecretFromKeyAgreement(with: serverPub)
        let ikm = shared.withUnsafeBytes { Data($0) } // P-256 shared X, 32 B = IKM
        let (gcm, hmac) = deriveKeys(ikm: ikm, secretId: secretId, deviceId: deviceId, expireTime: expireTime)
        return Session(secretId: secretId, deviceId: deviceId, gcmKey: gcm, hmacKey: hmac, expireTime: expireTime)
    }

    /// HKDF-SHA256, 64 B out, split into (GCM key `[0:32]`, HMAC key `[32:64]`).
    /// salt = utf8(secretId); info = utf8("{deviceId}#{expireTime}#{secretId}").
    static func deriveKeys(ikm: Data, secretId: String, deviceId: String, expireTime: Int)
        -> (gcm: SymmetricKey, hmac: SymmetricKey)
    {
        let salt = Data(secretId.utf8)
        let info = Data("\(deviceId)#\(expireTime)#\(secretId)".utf8)
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: 2 * aesKeyLength
        )
        let bytes = okm.withUnsafeBytes { Data($0) }
        return (
            SymmetricKey(data: bytes.prefix(aesKeyLength)),
            SymmetricKey(data: bytes.suffix(aesKeyLength))
        )
    }

    /// Encrypt a JSON body under the session. `seq` is supplied by the caller.
    public static func encryptRequest(session: Session, seq: Int, bodyJSON: Data) throws -> Envelope {
        let nonce = AES.GCM.Nonce() // random 12 B
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(bodyJSON, using: session.gcmKey, nonce: nonce, authenticating: session.aad)
        } catch { throw ChannelError.cryptoFailure("GCM seal failed: \(error)") }

        let text = sealed.ciphertext.base64EncodedString()
        let nonceId = generateNonceId()
        let timeNow = nowMillis()
        // cipherParamSignature = b64(HMAC-SHA256(hmacKey, nonceId+seq+timeNow+text)); server-enforced.
        let sigMsg = Data("\(nonceId)\(seq)\(timeNow)\(text)".utf8)
        let sig = HMAC<SHA256>.authenticationCode(for: sigMsg, using: session.hmacKey)
        return Envelope(
            text: text,
            mac: sealed.tag.base64EncodedString(),
            nonce: Data(nonce).base64EncodedString(),
            signature: Data(sig).base64EncodedString(),
            secretId: session.secretId,
            seq: seq,
            nonceId: nonceId,
            timeNow: timeNow,
            userId: session.deviceId
        )
    }

    /// Decrypt a response envelope (`cipherText`/`cipherMac`/`cipherNonce`).
    public static func decryptResponse(
        session: Session,
        textB64: String,
        macB64: String,
        nonceB64: String
    ) throws -> Data {
        guard let ct = Data(base64Encoded: textB64),
              let tag = Data(base64Encoded: macB64),
              let nonceData = Data(base64Encoded: nonceB64)
        else {
            throw ChannelError.cryptoFailure("response cipher fields not valid base64")
        }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData), ciphertext: ct, tag: tag)
            return try AES.GCM.open(box, using: session.gcmKey, authenticating: session.aad)
        } catch { throw ChannelError.cryptoFailure("GCM open failed: \(error)") }
    }

    private static func nowMillis() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    /// Unique nonce id; GCM security does not depend on it (the real nonce is `cipherParamNonce`).
    private static func generateNonceId() -> String {
        String((nowMillis() << 12) | Int.random(in: 0 ..< 0x1000))
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
