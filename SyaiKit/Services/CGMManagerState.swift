//
//  CGMManagerState.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

public struct CGMManagerState: RawRepresentable, Equatable {
    public typealias RawValue = [String: Any]

    public var sensors = SyaiSensorStore()

    public var latestReadingTimestamp: Date?
    public var lastGridSequence: UInt16?

    /// The sensor's own elapsed-seconds field for the newest live record, and
    /// the wall-clock instant that record arrived. Sensor age is
    /// `elapsed + (now - receivedAt)`: the sensor accounts for everything up to
    /// its last word and the phone clock only spans the silence since, so
    /// warmup and expiry don't depend on `activatedAt` being right. Only live
    /// records update this — a backfilled record's arrival time is when we
    /// asked for history, not when the reading was taken.
    public var latestElapsedSeconds: TimeInterval?
    public var latestElapsedReceivedAt: Date?

    public var mac: String? { sensors.activeMAC }
    public var peripheralID: UUID? { sensors.current()?.peripheralID }
    public var activatedAt: Date? { sensors.current()?.activatedAt }
    public var activeDuration: TimeInterval? { sensors.current()?.deviceInfo.activeDuration }
    public var preheatDuration: TimeInterval? { sensors.current()?.deviceInfo.preheatDuration }

    public var latestSample: GlucoseSample?
    public var recentSamples: [GlucoseSample] = []
    public static let recentSamplesPersistenceCap = 12

    public var latestForwardedToLoopAt: Date?

    public var sensorFault: SyaiSensorFault.Kind?
    public var sensorNeedsReplacement: Bool { sensorFault != nil }

    public var telemetryTier: SyaiTelemetryTier = .full
    public var telemetryDisclosureShown: Bool = false
    public var telemetryQueue: [SyaiUploadRecord] = []

    /// Set when the account session was invalidated by a login elsewhere (e.g. the official
    /// Syai app on another device); telemetry is paused until it clears.
    public var accountLockedOutElsewhere: Bool = false

    public mutating func resetSensorSession() {
        latestReadingTimestamp = nil
        lastGridSequence = nil
        latestElapsedSeconds = nil
        latestElapsedReceivedAt = nil
        latestSample = nil
        recentSamples = []
        latestForwardedToLoopAt = nil
        sensorFault = nil
        telemetryQueue = []
    }

    public init() {}

    public init?(rawValue: RawValue) {
        if let sensorsRaw = rawValue["sensors"] as? [String: Any],
           let sensors = SyaiSensorStore(rawValue: sensorsRaw)
        {
            self.sensors = sensors
        }
        latestReadingTimestamp = rawValue["latestReadingTimestamp"] as? Date
        lastGridSequence = (rawValue["lastGridSequence"] as? Int).map { UInt16(clamping: $0) }
        latestElapsedSeconds = rawValue["latestElapsedSeconds"] as? Double
        latestElapsedReceivedAt = rawValue["latestElapsedReceivedAt"] as? Date
        if let latestRaw = rawValue["latestSample"] as? [String: Any] {
            latestSample = GlucoseSample(rawValue: latestRaw)
        }
        if let recentRaw = rawValue["recentSamples"] as? [[String: Any]] {
            recentSamples = recentRaw.compactMap(GlucoseSample.init(rawValue:))
        }
        latestForwardedToLoopAt = rawValue["latestForwardedToLoopAt"] as? Date
        if let kindTag = rawValue["sensorFaultKind"] as? String,
           let state = rawValue["sensorFaultState"] as? Int
        {
            switch kindTag {
            case "obsolete": sensorFault = .deviceStateObsolete(state: state)
            case "unactivated": sensorFault = .deviceStateUnactivated(state: state)
            default: sensorFault = nil
            }
        } else if rawValue["sensorFaultKind"] as? String == "implausible" {
            sensorFault = .signalImplausible
        }

        // Pre-tier installs persisted a single `telemetryEnabled` Bool, written
        // only when false. Honour that explicit "no" as `.minimal` instead of
        // letting the missing tier key fall through to `.full`: the user
        // already has `telemetryDisclosureShown`, so they would never be asked
        // again and would silently start uploading glucose they had declined.
        // The tier key always wins once it exists.
        if let tag = rawValue["telemetryTier"] as? String {
            telemetryTier = SyaiTelemetryTier(persistedTag: tag)
        } else if rawValue["telemetryEnabled"] as? Bool == false {
            telemetryTier = .minimal
        } else {
            telemetryTier = .full
        }
        telemetryDisclosureShown = rawValue["telemetryDisclosureShown"] as? Bool ?? false
        if let queueRaw = rawValue["telemetryQueue"] as? [[String: Any]] {
            telemetryQueue = queueRaw.compactMap(SyaiUploadRecord.init(plistRawValue:))
        }
        accountLockedOutElsewhere = rawValue["accountLockedOutElsewhere"] as? Bool ?? false
    }

    public var rawValue: RawValue {
        var raw: RawValue = [:]
        raw["sensors"] = sensors.rawValue
        raw["latestReadingTimestamp"] = latestReadingTimestamp
        raw["lastGridSequence"] = lastGridSequence.map { Int($0) }
        raw["latestElapsedSeconds"] = latestElapsedSeconds
        raw["latestElapsedReceivedAt"] = latestElapsedReceivedAt
        raw["latestSample"] = latestSample?.rawValue
        if !recentSamples.isEmpty {
            raw["recentSamples"] = recentSamples.prefix(Self.recentSamplesPersistenceCap).map(\.rawValue)
        }
        raw["latestForwardedToLoopAt"] = latestForwardedToLoopAt

        switch sensorFault {
        case let .deviceStateObsolete(state):
            raw["sensorFaultKind"] = "obsolete"
            raw["sensorFaultState"] = state
        case let .deviceStateUnactivated(state):
            raw["sensorFaultKind"] = "unactivated"
            raw["sensorFaultState"] = state
        case .signalImplausible:
            raw["sensorFaultKind"] = "implausible"
        case .errorInfo,
             nil:
            break
        }

        if telemetryTier != .full {
            raw["telemetryTier"] = telemetryTier.persistedTag
        }
        if telemetryDisclosureShown {
            raw["telemetryDisclosureShown"] = true
        }
        if !telemetryQueue.isEmpty {
            raw["telemetryQueue"] = telemetryQueue.map(\.plistRawValue)
        }
        if accountLockedOutElsewhere {
            raw["accountLockedOutElsewhere"] = true
        }
        return raw
    }

    public var debugDescription: String {
        [
            "* mac: \(SyaiRedact.mac(mac))",
            "* peripheralID: \(String(describing: peripheralID))",
            "* activatedAt: \(String(describing: activatedAt))",
            "* latestReadingTimestamp: \(String(describing: latestReadingTimestamp))",
            "* lastGridSequence: \(String(describing: lastGridSequence))",
            "* latestElapsedSeconds: \(String(describing: latestElapsedSeconds))",
            "* activeDuration: \(String(describing: activeDuration))",
            "* sensorHistory.count: \(sensors.history().count)",
            "* latestSample: \(String(describing: latestSample))",
            "* recentSamples.count: \(recentSamples.count)",
            "* latestForwardedToLoopAt: \(String(describing: latestForwardedToLoopAt))",
            "* sensorFault: \(String(describing: sensorFault))",
            "* accountLockedOutElsewhere: \(accountLockedOutElsewhere)"
        ].joined(separator: "\n")
    }
}
