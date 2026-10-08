//
//  SyaiServerCalibrationProvider.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// The server side of activating a factory sensor, the one genuine online
/// dependency of the BYOA model, over the user's JWT session:
///
/// 1. `validateDeviceByMacV3` confirms the sensor may be started.
/// 2. `cgmAuth/verify` answers the sensor's BLE auth challenge server-side and
///    returns the activation frames, already encrypted for that connection.
///
/// The sensor's own coefficients and BLE key group only come back once it is
/// bound (`SyaiServerDeviceBinder.bind`), parsed by `provisioning(fromDeviceBody:)`.
public struct SyaiServerCalibrationProvider: CalibrationProvider {
    private let backend: SyaiBackend
    private let client: SyaiEnvelopedClient
    /// Auth-failure retry + token-rotation persistence, shared with
    /// `SyaiDeviceBinder`. `recoverSession` is invoked only on auth-shaped
    /// failures (`TransportError.isAuthFailure`) for one silent re-login retry.
    private let sessionRetrying: SyaiSessionRetrying
    private static let logger = SyaiLogger(category: "CalibrationProvider")

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
            case .noSecretKey: return "Missing glucoseSecretKey (needed to decipher coefficients). Log in again."
            case let .business(c): return Self.describeBusiness(code: c)
            case let .decode(m): return "Couldn't decode the server's sensor record: \(m)."
            }
        }

        public var errorDescription: String? { description }

        static func describeBusiness(code: String) -> String {
            switch code {
            case "AppDevice_AlreadyUsed":
                return "This sensor was already activated (by any account), so it can't be paired again. Use a fresh, never-activated sensor."
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

    public func validate(mac: String) async throws -> SyaiSensorValidation {
        guard backend.isConfigured else { throw ServerError.notConfigured }
        return try await sessionRetrying.run(client: client, backend: backend) { client, backend in
            let data = try await client.validateMac(mac)
            return try Self.parseValidation(data, mac: mac, glucoseSecretKey: backend.glucoseSecretKey)
        }
    }

    public func authorizeActivation(mac: String, authDev: Data, authFlag: Data) async throws -> SyaiRemoteActivation {
        guard backend.isConfigured else { throw ServerError.notConfigured }
        return try await sessionRetrying.run(client: client, backend: backend) { client, _ in
            let data = try await client.verifyCgmAuth(mac: mac, authDev: authDev, authFlag: authFlag)
            return try Self.parseRemoteActivation(data, mac: mac)
        }
    }

    /// Parse a `validateDeviceByMacV3` response. Only the code and the firmware
    /// version (which the bind needs) are required. Coefficients are kept when
    /// the server includes them, purely as a cross-check for the post-bind set.
    static func parseValidation(_ data: Data, mac: String, glucoseSecretKey: String?) throws -> SyaiSensorValidation {
        let body = try okDataObject(data)
        logger.info("validate: fields present \(body.keys.sorted())")
        let respMac = (body["mac"] as? String) ?? mac
        var coefficients: [Double]?
        if let coeffB64 = body["coefficient"] as? String, !coeffB64.isEmpty,
           let coeffUpdateTime = (body["coeffUpdateTime"] as? NSNumber)?.int64Value,
           let gsk = glucoseSecretKey, !gsk.isEmpty
        {
            do {
                coefficients = try SyaiCoefficientDecipher.decipher(
                    base64Coefficient: coeffB64, coeffUpdateTime: coeffUpdateTime,
                    mac: respMac, glucoseSecretKey: gsk
                )
            } catch {
                logger.warning("validate: coefficient present but did not decipher: \(error)")
            }
        }
        return SyaiSensorValidation(
            mac: respMac,
            deviceVersion: body["deviceVersion"] as? String ?? "",
            coefficients: coefficients
        )
    }

    /// Parse a `cgmAuth/verify` response: `{mac, auth, shaInfo, c, d, cf, kb}`,
    /// all hex. `auth`/`shaInfo` complete the handshake on `authHost`/`authFlag`;
    /// `cf`, `d` and `c` are the coefficient, duration and activate frames.
    /// `kb` has no consumer in the official app's activation path and is ignored.
    static func parseRemoteActivation(_ data: Data, mac: String) throws -> SyaiRemoteActivation {
        let body = try okDataObject(data)
        // Field presence only: these are live auth material for an open link.
        logger.info("cgmAuth/verify: fields present \(body.keys.sorted())")
        if let respMac = body["mac"] as? String, !respMac.isEmpty,
           respMac.uppercased() != mac.uppercased()
        {
            throw ServerError.decode("cgmAuth/verify answered for a different sensor")
        }
        func hex(_ key: String) throws -> Data? {
            guard let s = body[key] as? String, !s.isEmpty else { return nil }
            guard let d = Self.data(fromHex: s) else { throw ServerError.decode("'\(key)' is not hex") }
            return d
        }
        guard let authHost = try hex("auth") else { throw ServerError.decode("no 'auth' in cgmAuth/verify") }
        guard let authFlag = try hex("shaInfo") else { throw ServerError.decode("no 'shaInfo' in cgmAuth/verify") }
        return SyaiRemoteActivation(
            authHost: authHost,
            authFlag: authFlag,
            coefficientFrame: try hex("cf"),
            durationFrame: try hex("d"),
            activateFrame: try hex("c")
        )
    }

    /// Parse a bound sensor's device record (the bind response's
    /// `cgmDeviceRespVO`) into its own coefficients and key group. Every field
    /// the decode depends on is required: no default fallback (dosing gate).
    static func provisioning(fromDeviceBody body: [String: Any], mac: String, glucoseSecretKey: String?) throws
        -> SyaiProvisioning
    {
        guard let gsk = glucoseSecretKey, !gsk.isEmpty else { throw ServerError.noSecretKey }
        let respMac = (body["mac"] as? String) ?? mac
        guard respMac.uppercased() == mac.uppercased() else {
            throw ServerError.decode("record is for a different sensor")
        }
        guard let coeffB64 = body["coefficient"] as? String, !coeffB64.isEmpty else {
            throw ServerError.decode("no 'coefficient' field")
        }
        guard let coeffUpdateTime = (body["coeffUpdateTime"] as? NSNumber)?.int64Value else {
            throw ServerError.decode("no 'coeffUpdateTime'")
        }
        let coefficients: [Double]
        do {
            coefficients = try SyaiCoefficientDecipher.decipher(
                base64Coefficient: coeffB64, coeffUpdateTime: coeffUpdateTime,
                mac: respMac, glucoseSecretKey: gsk
            )
        } catch { throw ServerError.decode("coefficient decipher: \(error)") }

        let produceTimeRaw = (body["produceTime"] as? NSNumber)?.int64Value
        let produceTime = produceTimeRaw
            .map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date(timeIntervalSince1970: 0)
        // `activeExpireTime` is the wear duration in ms (varies by unit), not an
        // absolute timestamp; `preheatPeriodTime` (ms) is the warm-up.
        guard let activeExpireTimeMs = (body["activeExpireTime"] as? NSNumber)?.doubleValue else {
            throw ServerError.decode("no 'activeExpireTime'")
        }
        guard let preheatPeriodTimeMs = (body["preheatPeriodTime"] as? NSNumber)?.doubleValue else {
            throw ServerError.decode("no 'preheatPeriodTime'")
        }

        let deviceInfo = DeviceInfo(
            mac: respMac,
            serialNo: body["serialNo"] as? String ?? "",
            batchNo: body["batchNo"] as? String ?? "",
            deviceType: body["deviceType"] as? String ?? "",
            deviceVersion: body["deviceVersion"] as? String ?? "",
            coefficients: coefficients,
            // K/B only ever fed the old phone-built activation write; the decoder doesn't read them.
            k: (body["calibrationValueK"] as? NSNumber)?.doubleValue ?? 1,
            b: (body["calibrationValueB"] as? NSNumber)?.doubleValue ?? 0,
            produceTime: produceTime,
            expireTime: nil,
            activeDuration: activeExpireTimeMs / 1000,
            preheatDuration: preheatPeriodTimeMs / 1000
        )
        let keyGroup = try parseKeyGroup(
            body: body, respMac: respMac, produceTimeRaw: produceTimeRaw, glucoseSecretKey: gsk
        )
        return SyaiProvisioning(deviceInfo: deviceInfo, keyGroup: keyGroup)
    }

    /// The `data` object of an `OK` response; a non-OK code surfaces as `.business`.
    private static func okDataObject(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServerError.decode("not a JSON object")
        }
        let code = (root["code"] as? String) ?? "OK"
        guard code == "OK" else { throw ServerError.business(code: code) }
        guard let body = root["data"] as? [String: Any] else {
            throw ServerError.decode("no 'data' object")
        }
        return body
    }

    static func data(fromHex hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        data.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
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
    /// POST `device/validateDeviceByMacV3`, enveloped body `{mac, signature}`,
    /// with the access-token `Authorization` + `customerId` headers and
    /// `productModel`. Same body and signature as the retired V2 GET.
    func validateMac(_ mac: String) async throws -> Data {
        guard backend.isConfigured else { throw TransportError.notConfigured }
        // Pairing has no offline fallback; always try fresh.
        try await ensureAccessToken(bypassKnownLockout: true)
        let ts = SyaiBackend.timestampMillis()
        let signature = backend.signValidateMac(mac: mac, timestamp: ts)
        return try await envelopedPOST(
            path: "device/validateDeviceByMacV3",
            body: ["mac": mac, "signature": signature],
            extraHeaders: ["timestamp": ts],
            includeProductModel: true
        )
    }

    /// POST `cgmAuth/verify`: hands the sensor's auth challenge (`authDev` and
    /// `authFlag` as read, uppercase hex) to the server, which answers it for
    /// this connection. Body `{mac, paramStr, shaInfo, sign}`, signed over the
    /// millisecond `timestamp` header.
    func verifyCgmAuth(mac: String, authDev: Data, authFlag: Data) async throws -> Data {
        guard backend.isConfigured else { throw TransportError.notConfigured }
        try await ensureAccessToken(bypassKnownLockout: true)
        let ts = SyaiBackend.timestampMillis()
        let paramStr = Self.upperHex(authDev)
        let shaInfo = Self.upperHex(authFlag)
        let sign = backend.signCgmAuthVerify(mac: mac, authDevHex: paramStr, authFlagHex: shaInfo, timestamp: ts)
        return try await envelopedPOST(
            path: "cgmAuth/verify",
            body: ["mac": mac, "paramStr": paramStr, "shaInfo": shaInfo, "sign": sign],
            extraHeaders: ["timestamp": ts],
            includeProductModel: true
        )
    }

    static func upperHex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}
