//
//  SyaiDeviceBinder.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// Registers an activated sensor to the logged-in Syai account via
/// `deviceBind/composite/bindV3`, creating the server-side ownership record.
/// The bind response is also where the sensor's own coefficients and BLE key
/// group are handed out (see `provisioning(from:mac:)`).
public struct SyaiServerDeviceBinder: Sendable {
    private let backend: SyaiBackend
    private let client: SyaiEnvelopedClient
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

    public enum BindError: Error, CustomStringConvertible {
        case notConfigured
        public var description: String {
            switch self {
            case .notConfigured: return "Syai backend credentials not configured (log in first)."
            }
        }
    }

    /// Register `mac` to the logged-in account. Returns the parsed bind
    /// response (`SyaiBindResult`): `code` is `OK`/`SUCCESS` on success or a
    /// business code on a server rejection. `stateInfo` is the hex of the
    /// sensor-state read the official app sends for some firmwares; empty
    /// otherwise.
    public func bind(
        mac: String,
        deviceVersion: String,
        activatedAt: Date,
        stateInfo: String = ""
    ) async throws -> SyaiBindResult {
        guard backend.isConfigured else { throw BindError.notConfigured }
        let activeTimeMs = Int(activatedAt.timeIntervalSince1970 * 1000)
        return try await sessionRetrying.run(client: client, backend: backend) { client, _ in
            try await client.bind(
                mac: mac,
                deviceVersion: deviceVersion,
                activeTime: activeTimeMs,
                stateInfo: stateInfo
            )
        }
    }

    /// The sensor's own coefficients and key group from a successful bind.
    /// Throws when the record is missing or incomplete; callers fall back to
    /// `SyaiBoundSensorLookup`, never to defaults.
    public func provisioning(from result: SyaiBindResult, mac: String) throws -> SyaiProvisioning {
        guard let record = result.deviceRecord,
              let body = try? JSONSerialization.jsonObject(with: record) as? [String: Any]
        else {
            throw SyaiServerCalibrationProvider.ServerError.decode("bind response has no device record")
        }
        return try SyaiServerCalibrationProvider.provisioning(
            fromDeviceBody: body, mac: mac, glucoseSecretKey: backend.glucoseSecretKey
        )
    }

    /// Release `mac` from the logged-in account, ending the sensor's session
    /// server-side.
    ///
    /// One-way in practice: after this the server answers
    /// `validateDeviceByMacV3` for the MAC with `AppDevice_EndUsing` forever,
    /// so the sensor can never be paired again by anyone.
    public func unbind(mac: String, reason: SyaiUnbindReason) async throws -> String {
        guard backend.isConfigured else { throw BindError.notConfigured }
        return try await sessionRetrying.run(client: client, backend: backend) { client, _ in
            try await client.unbindDevice(mac: mac, reason: reason)
        }
    }

    /// One half of the `markDeviceStatus` bind bracket: `inProgress: true`
    /// fires immediately before `bind`, `false` immediately after. Body:
    /// `{"mac","state":1|0,"duration":5}` inside the standard cipher
    /// envelope. Callers should still tolerate a throw and proceed.
    public func markDeviceStatus(mac: String, inProgress: Bool) async throws {
        guard backend.isConfigured else { throw BindError.notConfigured }
        try await client.markDeviceStatus(mac: mac, inProgress: inProgress)
    }
}

public extension SyaiEnvelopedClient {
    /// `POST deviceBind/composite/bindV3`, registers `mac` to the logged-in
    /// account. Body `{mac, deviceType, deviceVersion, activeTime, newBindType,
    /// deviceInfo}`; no md5 `signature`, auth is the JWT `Authorization` header
    /// plus the secure-channel `cipherBodySignature` only. `activeTime` is the
    /// activation moment in epoch-ms.
    func bind(
        mac: String,
        deviceVersion: String,
        activeTime: Int = 0,
        stateInfo: String = ""
    ) async throws -> SyaiBindResult {
        guard backend.isConfigured else { throw TransportError.notConfigured }
        // Pairing has no offline fallback so always try fresh.
        try await ensureAccessToken(bypassKnownLockout: true)
        let body: [String: Any] = [
            "mac": mac,
            "deviceType": "cgm",
            "deviceVersion": deviceVersion,
            "activeTime": activeTime,
            "newBindType": 1,
            "deviceInfo": stateInfo
        ]
        let data = try await envelopedPOST(path: "deviceBind/composite/bindV3", body: body)
        return SyaiBindResult.parse(decryptedResponse: data)
    }

    /// `PUT deviceBind/unBindDevice`, the counterpart to `bind`: releases `mac`
    /// from the logged-in account and marks the sensor ended server-side.
    /// Body `{mac, deviceType:"cgm", unbindType}`; no md5 `signature`, same as
    /// `bind`.
    func unbindDevice(mac: String, reason: SyaiUnbindReason) async throws -> String {
        guard backend.isConfigured else { throw TransportError.notConfigured }
        // Ending a sensor has no offline fallback either so always try fresh.
        try await ensureAccessToken(bypassKnownLockout: true)
        let data = try await envelopedPUT(path: "deviceBind/unBindDevice", body: [
            "mac": mac,
            "deviceType": "cgm",
            "unbindType": reason.rawValue
        ])
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "OK"
        }
        return (root["code"] as? String) ?? "OK"
    }

    /// `POST deviceBind/markDeviceStatus`: the "binding in progress" bracket.
    /// Fires as the first and last thing around a bind: `(mac, true)`
    /// immediately before `composite/bindV3`, `(mac, false)` immediately after.
    /// Body: `{"mac": <mac>, "state": <int 1/0>, "duration": 5}` (`state` is
    /// an integer, not a bool). This bracket tolerates a throw and proceeds
    /// regardless, so pairing is never blocked by it.
    func markDeviceStatus(mac: String, inProgress: Bool) async throws {
        guard backend.isConfigured else { throw TransportError.notConfigured }
        // Part of the bind/unbind bracket, same reasoning as bind/unbindDevice above.
        try await ensureAccessToken(bypassKnownLockout: true)
        _ = try await envelopedPOST(path: "deviceBind/markDeviceStatus", body: [
            "mac": mac,
            "state": inProgress ? 1 : 0,
            "duration": 5
        ])
    }
}

/// The parsed response of `deviceBind/composite/bindV3`. The `method` blob is
/// persisted verbatim but deliberately not decrypted or compared.
/// `deviceRecord` is the sensor's device record (`cgmDeviceRespVO`) as JSON,
/// which carries its coefficients and key group.
public struct SyaiBindResult: Sendable, Equatable {
    public let code: String
    public let methodId: Int?
    public let methodUpdateTime: Int64?
    public let methodBlob: String?
    public let deviceRecord: Data?

    public init(
        code: String,
        methodId: Int? = nil,
        methodUpdateTime: Int64? = nil,
        methodBlob: String? = nil,
        deviceRecord: Data? = nil
    ) {
        self.code = code
        self.methodId = methodId
        self.methodUpdateTime = methodUpdateTime
        self.methodBlob = methodBlob
        self.deviceRecord = deviceRecord
    }

    public var isSuccess: Bool { code == "OK" || code == "SUCCESS" }

    public static func parse(decryptedResponse data: Data) -> SyaiBindResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SyaiBindResult(code: "OK")
        }
        let code = (root["code"] as? String) ?? "OK"
        let body = root["data"] as? [String: Any]
        let device = body?["cgmDeviceRespVO"] as? [String: Any]
        // The method lived in its own VO on the old bind; the V3 record carries it inline.
        let vo = (body?["cgmDeviceMethodVO"] as? [String: Any]) ?? device
        return SyaiBindResult(
            code: code,
            methodId: (vo?["methodId"] as? NSNumber)?.intValue,
            methodUpdateTime: (vo?["methodUpdateTime"] as? NSNumber)?.int64Value,
            methodBlob: vo?["method"] as? String,
            deviceRecord: device.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        )
    }
}
