//
//  SyaiServerCalibrationProvider.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// Fetches per-sensor calibration from Syai's server, the one genuine online
/// dependency of the BYOA model. Calls `validateDeviceByMacV2(mac)` over the
/// user's JWT session, returning the per-sensor coefficients `C0..C13` and the
/// BLE key group.
public struct SyaiServerCalibrationProvider: CalibrationProvider {
    private let backend: SyaiBackend
    private let client: SyaiEnvelopedClient
    /// Auth-failure retry + token-rotation persistence, shared with
    /// `SyaiDeviceBinder`. `recoverSession` is invoked only on auth-shaped
    /// failures (`TransportError.isAuthFailure`) for one silent re-login retry.
    private let sessionRetrying: SyaiSessionRetrying

    public init(
        backend: SyaiBackend = .syaiTemplate,
        session: URLSession = .shared,
        onSessionRotated: (@Sendable(SyaiCredentials, String?) -> Void)? = nil,
        recoverSession: (@Sendable() async -> SyaiBackend?)? = nil,
        onAccountLockoutChanged: (@Sendable(Bool) -> Void)? = nil
    ) {
        self.backend = backend
        client = SyaiEnvelopedClient(backend: backend, urlSession: session)
        sessionRetrying = SyaiSessionRetrying(
            session: session, onSessionRotated: onSessionRotated, recoverSession: recoverSession,
            onAccountLockoutChanged: onAccountLockoutChanged
        )
    }

    public enum ServerError: Error, CustomStringConvertible, LocalizedError {
        case notConfigured
        case noSecretKey
        case business(code: String)
        case decode(String)
        public var description: String {
            switch self {
            case .notConfigured: return "Syai backend credentials not configured (log in first)."
            case .noSecretKey: return "Missing glucoseSecretKey (needed to decipher coefficients). Set it from a login/refresh, or embed it."
            case let .business(c): return Self.describeBusiness(code: c)
            case let .decode(m): return "Couldn't decode the calibration response: \(m)."
            }
        }

        public var errorDescription: String? { description }

        static func describeBusiness(code: String) -> String {
            switch code {
            case "AppDevice_AlreadyUsed":
                return "This sensor was already activated (by any account). Its calibration can never be re-fetched, so it can't be paired again. Use a fresh, never-activated sensor."
            case "AppDevice_EndUsing":
                return "This sensor's session has ended (wear window elapsed or ended in the official app). It can't be paired. Use a fresh sensor."
            case "AppDevice_NotExist":
                return "The server doesn't know this sensor's MAC. Check you scanned the right sensor."
            case "AppDevice_TypeError":
                return "This device type isn't a supported Syai sensor."
            case "AppDevice_UserNuBind":
                return "This sensor isn't bound to your account yet on the server side."
            case "AppDevice_OutOfProduceTime":
                return "This sensor is past its shelf life and can't be activated."
            default:
                return "Syai server returned '\(code)' for this sensor."
            }
        }
    }

    /// Enveloped GET `/device/validateDeviceByMacV2`. One call yields both the
    /// coefficients and the BLE key group. Dead-JWT retry + token-rotation
    /// persistence via `sessionRetrying`.
    public func provision(forMAC mac: String) async throws -> SyaiProvisioning {
        guard backend.isConfigured else { throw ServerError.notConfigured }
        return try await sessionRetrying.run(client: client, backend: backend) { client, backend in
            let data = try await client.validateMac(mac)
            return try Self.parse(data, mac: mac, glucoseSecretKey: backend.glucoseSecretKey)
        }
    }

    /// Parse a `validateDeviceByMacV2` response into `DeviceInfo`.
    ///
    /// `coefficient` deciphers to `C0..C13` via `SyaiCoefficientDecipher`
    /// (needs `glucoseSecretKey`); `K`/`B` are the plain adjust values, used
    /// verbatim. Non-`OK` codes surface as `.business`.
    static func parse(_ data: Data, mac: String, glucoseSecretKey: String?) throws -> SyaiProvisioning {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServerError.decode("not a JSON object")
        }
        let code = (root["code"] as? String) ?? "OK"
        guard code == "OK" else { throw ServerError.business(code: code) }
        guard let body = root["data"] as? [String: Any] else {
            throw ServerError.decode("no 'data' object")
        }
        guard let gsk = glucoseSecretKey, !gsk.isEmpty else { throw ServerError.noSecretKey }
        guard let coeffB64 = body["coefficient"] as? String else {
            throw ServerError.decode("no 'coefficient' field")
        }
        guard let coeffUpdateTime = (body["coeffUpdateTime"] as? NSNumber)?.int64Value else {
            throw ServerError.decode("no 'coeffUpdateTime'")
        }
        let respMac = (body["mac"] as? String) ?? mac

        let coefficients: [Double]
        do {
            coefficients = try SyaiCoefficientDecipher.decipher(
                base64Coefficient: coeffB64, coeffUpdateTime: coeffUpdateTime,
                mac: respMac, glucoseSecretKey: gsk
            )
        } catch { throw ServerError.decode("coefficient decipher: \(error)") }

        // K/B are used verbatim as the server returns them. No default fallback
        // (dosing gate): installing 1.0/0.0 in place of a missing value would
        // silently scale/shift every decoded reading.
        guard let k = (body["calibrationValueK"] as? NSNumber)?.doubleValue else {
            throw ServerError.decode("no 'calibrationValueK'")
        }
        guard let b = (body["calibrationValueB"] as? NSNumber)?.doubleValue else {
            throw ServerError.decode("no 'calibrationValueB'")
        }

        let produceTimeRaw = (body["produceTime"] as? NSNumber)?.int64Value
        let produceTime = produceTimeRaw
            .map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date(timeIntervalSince1970: 0)
        // `activeExpireTime` is the wear duration in ms (varies by unit), not
        // an absolute timestamp. A real response always carries this alongside
        // the coefficients; no default fallback.
        guard let activeExpireTimeMs = (body["activeExpireTime"] as? NSNumber)?.doubleValue else {
            throw ServerError.decode("no 'activeExpireTime'")
        }
        let activeDuration = activeExpireTimeMs / 1000
        // `preheatPeriodTime` (ms) is the warm-up. The activation write is
        // (activeExpireTime + preheatPeriodTime)/1000.
        guard let preheatPeriodTimeMs = (body["preheatPeriodTime"] as? NSNumber)?.doubleValue else {
            throw ServerError.decode("no 'preheatPeriodTime'")
        }
        let preheatDuration = preheatPeriodTimeMs / 1000
        let deviceInfo = DeviceInfo(
            mac: respMac,
            serialNo: body["serialNo"] as? String ?? "",
            batchNo: body["batchNo"] as? String ?? "",
            deviceType: body["deviceType"] as? String ?? "",
            deviceVersion: body["deviceVersion"] as? String ?? "",
            coefficients: coefficients,
            k: k, b: b,
            produceTime: produceTime,
            expireTime: nil,
            activeDuration: activeDuration,
            preheatDuration: preheatDuration
        )

        let keyGroup = try Self.parseKeyGroup(
            body: body, respMac: respMac, produceTimeRaw: produceTimeRaw,
            glucoseSecretKey: gsk
        )
        return SyaiProvisioning(deviceInfo: deviceInfo, keyGroup: keyGroup)
    }

    private static func data(fromHex hex: String) -> Data? {
        var data = Data()
        data.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// Decipher `keyA` into a `SyaiKeyGroup` (6 x 16 bytes). Reuses the
    /// coefficient KDF with `produceTime` in place of `coeffUpdateTime`, then
    /// AES-256-ECB/PKCS7-decrypts. The decrypted plaintext is the 96 key bytes
    /// as a 192-char ASCII hex string; raw-96 is accepted as a fallback.
    static func parseKeyGroup(
        body: [String: Any],
        respMac: String,
        produceTimeRaw: Int64?,
        glucoseSecretKey: String
    ) throws -> SyaiKeyGroup {
        guard let keyAB64 = body["keyA"] as? String, !keyAB64.isEmpty else {
            throw ServerError.decode("no 'keyA' (BLE key group) in response")
        }
        guard let produceTimeRaw else { throw ServerError.decode("no 'produceTime' for keyA KDF") }
        guard let ct = Data(base64Encoded: keyAB64) else { throw ServerError.decode("keyA not base64") }
        // Same 32-byte key shape as the coefficient blob: gsk(16) ‖ last10(produceTime) ‖ last6(mac).
        let key = SyaiCoefficientDecipher.deriveKey(
            glucoseSecretKey: glucoseSecretKey, coeffUpdateTime: produceTimeRaw, mac: respMac
        )
        let plain: Data
        do { plain = try AESECB().decryptECB_PKCS7(ct, keyUTF8: key) }
        catch { throw ServerError.decode("keyA decrypt: \(error)") }
        // Plaintext is a 192-char ASCII hex string of the 96 key bytes, not raw bytes.
        if plain.count == 96 { return SyaiKeyGroup(raw: plain) }
        if plain.count == 192, let hex = String(data: plain, encoding: .utf8),
           let raw = Self.data(fromHex: hex), raw.count == 96
        {
            return SyaiKeyGroup(raw: raw)
        }
        throw ServerError.decode("keyA plaintext \(plain.count)B, expected 96 raw or 192 hex")
    }
}

public extension SyaiEnvelopedClient {
    /// GET `device/validateDeviceByMacV2`, enveloped body `{mac, signature}`,
    /// with the access-token `Authorization` + `customerId` headers. This is the
    /// one call the app sends `includeProductModel` on.
    func validateMac(_ mac: String) async throws -> Data {
        guard backend.isConfigured else { throw TransportError.notConfigured }
        // Pairing has no offline fallback; always try fresh.
        try await ensureAccessToken(bypassKnownLockout: true)
        let ts = SyaiBackend.timestampMillis()
        let signature = backend.signValidateMac(mac: mac, timestamp: ts)
        return try await envelopedGET(
            path: "device/validateDeviceByMacV2",
            body: ["mac": mac, "signature": signature],
            extraHeaders: ["timestamp": ts],
            includeProductModel: true
        )
    }
}
