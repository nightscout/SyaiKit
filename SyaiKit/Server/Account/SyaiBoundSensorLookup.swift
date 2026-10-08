//
//  SyaiBoundSensorLookup.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// A sensor already bound to the account, typically activated by the official
/// app, that SyaiKit can take over without activating it again.
public struct SyaiBoundSensor: Equatable, Sendable {
    public let deviceInfo: DeviceInfo
    public let keyGroup: SyaiKeyGroup
    /// From the server's `activeTime`; nil if it isn't reported, in which case
    /// ingest derives it from the sensor's own elapsed-seconds field.
    public let activatedAt: Date?

    public var mac: String { deviceInfo.mac }

    /// Whether the wear window has already run out by the server's account.
    public var isPastWear: Bool {
        guard let activatedAt else { return false }
        return activatedAt.addingTimeInterval(deviceInfo.activeDuration) <= Date()
    }
}

/// Finds the sensor bound to the logged-in account, the way the official app
/// restores it: `GET deviceBind/getBindDevice` for which sensor is bound (and
/// when it started), then `device/authInfo` for that MAC for the BLE key group
/// and durations.
///
/// `getBindDevice`'s `data` parses into the app's `CgmBindDeviceModel`, the
/// same model as the calibration fetch, and for a started sensor it still
/// carries `coefficient`/`coeffUpdateTime` (`authInfo` doesn't). Those are
/// required: a sensor without its own coefficients is not taken over.
public struct SyaiBoundSensorLookup: Sendable {
    public enum LookupError: Error, CustomStringConvertible, LocalizedError {
        case notConfigured
        case noSecretKey
        case business(code: String)
        case noCalibration
        case decode(String)

        public var description: String {
            switch self {
            case .notConfigured: return "Log in to Syai first."
            case .noSecretKey: return "Missing glucoseSecretKey; log in again."
            case let .business(code): return "Syai server returned '\(code)' when looking up your sensor."
            case .noCalibration:
                return "Syai didn't provide this sensor's calibration, so \(Bundle.main.syaiHostAppName) can't use it. Pair a new sensor instead."
            case let .decode(message): return "Couldn't read your bound sensor: \(message)."
            }
        }

        public var errorDescription: String? { description }
    }

    private let backend: SyaiBackend
    private let client: SyaiEnvelopedClient
    private let sessionRetrying: SyaiSessionRetrying
    private let logger = SyaiLogger(category: "BoundSensorLookup")

    public init(
        backend: SyaiBackend,
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

    /// The bound sensor, or nil when the account has none.
    public func boundSensor() async throws -> SyaiBoundSensor? {
        guard backend.isConfigured else { throw LookupError.notConfigured }
        return try await sessionRetrying.run(client: client, backend: backend) { client, backend in
            let bindData = try await client.getBindDevice()
            logger.info("getBindDevice response: \(String(data: bindData, encoding: .utf8) ?? "<\(bindData.count) bytes>")")
            guard var body = try Self.boundDeviceBody(bindData),
                  let mac = body["mac"] as? String else { return nil }

            // authInfo is the call the official app gets the BLE keys from, so
            // its values win; getBindDevice fills in the rest (start time,
            // firmware). If authInfo fails, the bound record alone is enough
            // when it happens to carry the keys.
            do {
                let authInfo = try await client.authInfo(mac: mac)
                logger.info("authInfo response: \(String(data: authInfo.raw, encoding: .utf8) ?? "<\(authInfo.raw.count) bytes>")")
                body = Self.merged(bound: body, authInfo: authInfo.raw)
            } catch {
                logger.warning("authInfo failed for the bound sensor: \(String(describing: error))")
                if Self.missingForAdoption(body) { throw error }
            }
            return try Self.parse(body: body, glucoseSecretKey: backend.glucoseSecretKey)
        }
    }

    /// The bound device object, or nil when the response says nothing is
    /// bound. A non-OK code is an error, not "no sensor".
    static func boundDeviceBody(_ data: Data) throws -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LookupError.decode("not a JSON object")
        }
        let code = (root["code"] as? String) ?? "OK"
        guard code == "OK" else { throw LookupError.business(code: code) }
        guard let body = root["data"] as? [String: Any],
              let mac = body["mac"] as? String, !mac.isEmpty
        else { return nil }
        return body
    }

    /// `authInfo`'s values win over the bound record's; an explicit null in
    /// `authInfo` never erases a value the bound record has.
    static func merged(bound: [String: Any], authInfo: Data) -> [String: Any] {
        guard let auth = (try? JSONSerialization.jsonObject(with: authInfo) as? [String: Any])?["data"]
            as? [String: Any] else { return bound }
        return bound.merging(auth.filter { !($0.value is NSNull) }) { _, fromAuthInfo in fromAuthInfo }
    }

    static func missingForAdoption(_ body: [String: Any]) -> Bool {
        ["keyA", "produceTime", "activeExpireTime", "preheatPeriodTime"].contains { body[$0] == nil }
    }

    static func parse(body: [String: Any], glucoseSecretKey: String?) throws -> SyaiBoundSensor {
        guard let mac = body["mac"] as? String, !mac.isEmpty else { throw LookupError.decode("no 'mac'") }
        guard let gsk = glucoseSecretKey, !gsk.isEmpty else { throw LookupError.noSecretKey }

        let keyGroup: SyaiKeyGroup
        do {
            keyGroup = try SyaiServerCalibrationProvider.parseKeyGroup(
                body: body, respMac: mac,
                produceTimeRaw: (body["produceTime"] as? NSNumber)?.int64Value,
                glucoseSecretKey: gsk
            )
        } catch { throw LookupError.decode("\(error)") }

        guard let activeExpireTimeMs = (body["activeExpireTime"] as? NSNumber)?.doubleValue else {
            throw LookupError.decode("no 'activeExpireTime'")
        }
        guard let preheatPeriodTimeMs = (body["preheatPeriodTime"] as? NSNumber)?.doubleValue else {
            throw LookupError.decode("no 'preheatPeriodTime'")
        }

        // No default fallback: decoding a sensor on anything but its own
        // coefficients would put plausible-but-wrong glucose into the loop.
        guard let coeffB64 = body["coefficient"] as? String, !coeffB64.isEmpty,
              let coeffUpdateTime = (body["coeffUpdateTime"] as? NSNumber)?.int64Value
        else { throw LookupError.noCalibration }
        let coefficients: [Double]
        do {
            coefficients = try SyaiCoefficientDecipher.decipher(
                base64Coefficient: coeffB64, coeffUpdateTime: coeffUpdateTime,
                mac: mac, glucoseSecretKey: gsk
            )
        } catch { throw LookupError.decode("coefficient decipher: \(error)") }

        let produceTime = ((body["produceTime"] as? NSNumber)?.doubleValue)
            .map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date(timeIntervalSince1970: 0)
        let activatedAt = ((body["activeTime"] as? NSNumber)?.doubleValue)
            .flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }

        let deviceInfo = DeviceInfo(
            mac: mac,
            serialNo: body["serialNo"] as? String ?? "",
            batchNo: body["batchNo"] as? String ?? "",
            deviceType: body["deviceType"] as? String ?? "",
            deviceVersion: body["deviceVersion"] as? String ?? "",
            coefficients: coefficients,
            // K/B only feed the activation write, which this path never does.
            k: (body["calibrationValueK"] as? NSNumber)?.doubleValue ?? 1,
            b: (body["calibrationValueB"] as? NSNumber)?.doubleValue ?? 1,
            produceTime: produceTime,
            activeDuration: activeExpireTimeMs / 1000,
            preheatDuration: preheatPeriodTimeMs / 1000
        )
        return SyaiBoundSensor(
            deviceInfo: deviceInfo,
            keyGroup: keyGroup,
            activatedAt: activatedAt
        )
    }
}

public extension SyaiEnvelopedClient {
    /// GET `deviceBind/getBindDevice`: empty param map, access token required.
    func getBindDevice() async throws -> Data {
        guard backend.isConfigured else { throw TransportError.notConfigured }
        try await ensureAccessToken()
        return try await envelopedGET(path: "deviceBind/getBindDevice", body: [:])
    }
}
