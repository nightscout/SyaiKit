//
//  SyaiSensorStore.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// One persisted per-sensor record. `deviceInfo` is the single source of truth
/// for identity and calibration; `keyGroup` holds the 6 per-sensor BLE keys.
public struct SyaiSensorRecord: Equatable, Sendable, Identifiable, RawRepresentable {
    public var deviceInfo: DeviceInfo
    public var keyGroup: SyaiKeyGroup
    public var activatedAt: Date?
    public var retiredAt: Date?
    public var peripheralID: UUID?
    /// The server's numeric device `id` for this sensor (from `device/authInfo`),
    /// used as the glucose-upload body's `deviceId`. nil until the first authInfo
    /// fetch; never fabricated.
    public var serverDeviceId: Int?
    /// Encrypted adjust-program blob from the bind response's `method` field,
    /// persisted verbatim (decrypt/compare is deliberately not ported).
    public var methodBlob: String?

    public var id: String { deviceInfo.mac }
    public var mac: String { deviceInfo.mac }

    /// True if activation happened and the wear window hasn't ended yet.
    /// Used to decide whether a re-added CGM manager should silently resume
    /// this sensor as active rather than treat it as merely historical.
    public var isWithinWearWindow: Bool {
        guard let activatedAt else { return false }
        return activatedAt.addingTimeInterval(deviceInfo.activeDuration) > Date()
    }

    public init(
        deviceInfo: DeviceInfo,
        keyGroup: SyaiKeyGroup,
        activatedAt: Date? = nil,
        retiredAt: Date? = nil,
        peripheralID: UUID? = nil,
        serverDeviceId: Int? = nil,
        methodBlob: String? = nil
    ) {
        self.deviceInfo = deviceInfo
        self.keyGroup = keyGroup
        self.activatedAt = activatedAt
        self.retiredAt = retiredAt
        self.peripheralID = peripheralID
        self.serverDeviceId = serverDeviceId
        self.methodBlob = methodBlob
    }

    public typealias RawValue = [String: Any]

    public init?(rawValue: RawValue) {
        guard let deviceRaw = rawValue["deviceInfo"] as? [String: Any],
              let deviceInfo = DeviceInfo(rawValue: deviceRaw),
              let keyB64 = rawValue["keyGroup"] as? String,
              let keyGroup = SyaiKeyGroup(rawValue: keyB64) else { return nil }
        self.deviceInfo = deviceInfo
        self.keyGroup = keyGroup
        activatedAt = rawValue["activatedAt"] as? Date
        retiredAt = rawValue["retiredAt"] as? Date
        peripheralID = (rawValue["peripheralID"] as? String).flatMap(UUID.init(uuidString:))
        serverDeviceId = rawValue["serverDeviceId"] as? Int // additive: absent key means nil
        methodBlob = rawValue["methodBlob"] as? String // additive: absent key means nil
    }

    public var rawValue: RawValue {
        var raw: RawValue = [
            "deviceInfo": deviceInfo.rawValue,
            "keyGroup": keyGroup.rawValue
        ]
        raw["activatedAt"] = activatedAt
        raw["retiredAt"] = retiredAt
        raw["peripheralID"] = peripheralID?.uuidString
        raw["serverDeviceId"] = serverDeviceId
        raw["methodBlob"] = methodBlob
        return raw
    }
}

/// Persisted store for activated sensors: the active record plus a capped
/// history of retired ones. Records are kept newest-first.
public struct SyaiSensorStore: Equatable, Sendable, RawRepresentable {
    /// Newest-first. The active record (matching `activeMAC`) sits at index 0
    /// after every `adopt`.
    public private(set) var records: [SyaiSensorRecord]
    public var activeMAC: String?

    /// Crash/interrupt insurance for the activation one-way door: the fetched
    /// record is persisted before the first write, since coefficients become
    /// unfetchable once activation writes land. Never cleared on activation
    /// failure, because a failed run may still have completed some writes.
    public private(set) var pendingActivation: SyaiSensorRecord?

    /// How many retired sensors to keep for diagnostics before trimming the
    /// oldest. The active record never counts against being dropped.
    public static let historyCap = 20

    public init(
        records: [SyaiSensorRecord] = [],
        activeMAC: String? = nil,
        pendingActivation: SyaiSensorRecord? = nil
    ) {
        self.records = records
        self.activeMAC = activeMAC
        self.pendingActivation = pendingActivation
    }

    public func current() -> SyaiSensorRecord? {
        guard let activeMAC else { return nil }
        return records.first { $0.mac == activeMAC }
    }

    public func history() -> [SyaiSensorRecord] { records }

    public mutating func setPendingActivation(_ record: SyaiSensorRecord) {
        pendingActivation = record
    }

    public func pendingActivation(forMAC mac: String) -> SyaiSensorRecord? {
        pendingActivation?.mac == mac ? pendingActivation : nil
    }

    /// Adopt `deviceInfo` as the active sensor, retiring whatever was active.
    public mutating func adopt(
        _ deviceInfo: DeviceInfo,
        keyGroup: SyaiKeyGroup,
        peripheralID: UUID?,
        activatedAt: Date?
    ) {
        let now = Date()
        if let activeMAC, activeMAC != deviceInfo.mac,
           let idx = records.firstIndex(where: { $0.mac == activeMAC })
        {
            records[idx].retiredAt = now
        }
        // Drop any prior record for this MAC: we re-insert a fresh one,
        // carrying over the lazily-fetched server device id (it's keyed by
        // MAC/account, so a same-MAC re-pair keeps it).
        let priorServerDeviceId = records.first { $0.mac == deviceInfo.mac }?.serverDeviceId
        records.removeAll { $0.mac == deviceInfo.mac }
        let record = SyaiSensorRecord(
            deviceInfo: deviceInfo, keyGroup: keyGroup,
            activatedAt: activatedAt, retiredAt: nil, peripheralID: peripheralID,
            serverDeviceId: priorServerDeviceId
        )
        records.insert(record, at: 0)
        activeMAC = deviceInfo.mac
        if pendingActivation?.mac == deviceInfo.mac { pendingActivation = nil }
        trim()
    }

    public mutating func setActivatedAt(_ date: Date?) {
        guard let activeMAC, let idx = records.firstIndex(where: { $0.mac == activeMAC }) else { return }
        records[idx].activatedAt = date
    }

    /// Persist the server's numeric device `id` on the active record,
    /// used as the glucose-upload body's `deviceId`.
    public mutating func setServerDeviceId(_ id: Int) {
        guard let activeMAC, let idx = records.firstIndex(where: { $0.mac == activeMAC }) else { return }
        records[idx].serverDeviceId = id
    }

    /// Persist the bind response's encrypted `method` blob on the active record.
    public mutating func setMethodBlob(_ blob: String) {
        guard let activeMAC, let idx = records.firstIndex(where: { $0.mac == activeMAC }) else { return }
        records[idx].methodBlob = blob
    }

    /// Persist the live CoreBluetooth peripheral ID for the active record.
    public mutating func setPeripheralID(_ id: UUID?) {
        guard let activeMAC, let idx = records.firstIndex(where: { $0.mac == activeMAC }) else { return }
        records[idx].peripheralID = id
    }

    public mutating func updateActiveCalibration(_ calibration: Calibration) {
        guard let activeMAC, let idx = records.firstIndex(where: { $0.mac == activeMAC }) else { return }
        let old = records[idx].deviceInfo
        records[idx].deviceInfo = DeviceInfo(
            mac: old.mac, serialNo: old.serialNo, batchNo: old.batchNo,
            deviceType: old.deviceType, deviceVersion: old.deviceVersion,
            coefficients: calibration.coefficients, k: calibration.k, b: calibration.b,
            produceTime: old.produceTime, expireTime: old.expireTime,
            activeDuration: old.activeDuration, preheatDuration: old.preheatDuration
        )
    }

    public mutating func updateActiveDeviceInfo(_ deviceInfo: DeviceInfo) {
        guard let activeMAC, activeMAC == deviceInfo.mac,
              let idx = records.firstIndex(where: { $0.mac == activeMAC }) else { return }
        records[idx].deviceInfo = deviceInfo
    }

    /// Union `records` with an externally-persisted list (by mac), preferring
    /// the in-memory record on collision since it's the live one. Called on
    /// every manager construction with `SyaiSensorHistoryStore`'s file
    /// contents as `external`, so history survives a CGM manager being
    /// deleted and re-added.
    public mutating func mergeHistory(_ external: [SyaiSensorRecord]) {
        guard !external.isEmpty else { return }
        var byMAC = Dictionary(uniqueKeysWithValues: records.map { ($0.mac, $0) })
        for record in external where byMAC[record.mac] == nil {
            byMAC[record.mac] = record
        }
        records = byMAC.values.sorted { lhs, rhs in
            let lhsDate = max(lhs.activatedAt ?? .distantPast, lhs.retiredAt ?? .distantPast)
            let rhsDate = max(rhs.activatedAt ?? .distantPast, rhs.retiredAt ?? .distantPast)
            return lhsDate > rhsDate
        }
        trim()

        // A record that was never explicitly retired (End Sensor / discardActive)
        // was still the active sensor when its old CGM manager was deleted -
        // deletion itself never retires anything. If this manager doesn't have
        // an active sensor of its own yet and that one hasn't expired, resume
        // it automatically: re-pairing would fail anyway, since the account
        // already activated it and the server refuses to re-answer for it.
        if activeMAC == nil,
           let resumable = records.first(where: { $0.retiredAt == nil && $0.isWithinWearWindow })
        {
            activeMAC = resumable.mac
        }
    }

    public mutating func discardActive() {
        if let activeMAC, let idx = records.firstIndex(where: { $0.mac == activeMAC }) {
            records[idx].retiredAt = records[idx].retiredAt ?? Date()
        }
        activeMAC = nil
    }

    private mutating func trim() {
        guard records.count > Self.historyCap else { return }
        records.removeLast(records.count - Self.historyCap)
    }

    public typealias RawValue = [String: Any]

    public init?(rawValue: RawValue) {
        // records live only in `SyaiSensorHistoryStore`'s file now; hydrated
        // separately via `mergeHistory` on manager construction.
        records = []
        activeMAC = rawValue["activeMAC"] as? String
        // additive: absent key means nil (state persisted before the slot existed)
        pendingActivation = (rawValue["pendingActivation"] as? [String: Any])
            .flatMap(SyaiSensorRecord.init(rawValue:))
    }

    public var rawValue: RawValue {
        // `records` is deliberately not written here: it lives only in
        // `SyaiSensorHistoryStore`'s file now (see `mergeHistory`), so
        // rawState carries just the index - `activeMAC` - plus in-flight
        // activation insurance. Avoids storing the same coefficients/BLE
        // keys in two plists.
        var raw: RawValue = [:]
        raw["activeMAC"] = activeMAC
        raw["pendingActivation"] = pendingActivation?.rawValue
        return raw
    }
}
