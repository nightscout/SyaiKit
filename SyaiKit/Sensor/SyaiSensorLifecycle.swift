//
//  SyaiSensorLifecycle.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

public enum SyaiSensorLifecycle: Equatable {
    case noSensor
    case warmup(progress: Double, remaining: TimeInterval)
    case active(remaining: TimeInterval, total: TimeInterval)
    case expired
    case signalLost(since: Date)
    /// The sensor's own cmd characteristic reported itself dead (state >= 4);
    /// replace the sensor.
    case failed
    /// The sensor's own cmd characteristic reports itself unactivated (state < 3)
    /// while we hold an activation record for it — its lifecycle state doesn't
    /// match what we expect, so nothing it reports can be trusted for dosing.
    case unactivated

    static let signalLostThreshold: TimeInterval = 6 * 60

    /// Seconds since activation. Comes from the sensor's own elapsed-seconds
    /// field wherever it is available, with the phone clock spanning only the
    /// silence since that record arrived.
    public static func age(
        activatedAt: Date?,
        sensorAge: (elapsed: TimeInterval, at: Date)?,
        now: Date = Date()
    ) -> TimeInterval? {
        if let sensorAge { return sensorAge.elapsed + now.timeIntervalSince(sensorAge.at) }
        return activatedAt.map { now.timeIntervalSince($0) }
    }

    /// Faults take precedence: the sensor's cmd-characteristic state reports
    /// failed/unactivated, and the client-side plausibility guard is equally
    /// terminal. Timestamp math only runs when there is no fault, because
    /// cmd's "activated" state (3) does not distinguish warmup from active.
    public static func compute(
        sensorPaired: Bool,
        activatedAt: Date?,
        sensorAge: (elapsed: TimeInterval, at: Date)? = nil,
        latestReadingAt: Date?,
        hasLiveMonitor: Bool,
        reportedFault: SyaiSensorFault.Kind? = nil,
        activeDuration: TimeInterval? = nil,
        preheatDuration: TimeInterval? = nil,
        now: Date = Date()
    ) -> SyaiSensorLifecycle {
        guard sensorPaired else { return .noSensor }
        switch reportedFault {
        case .signalImplausible: return .failed
        case .deviceStateUnactivated: return .unactivated
        case .deviceStateObsolete: // generic state for "not working"
            if let activatedAt, let wear = activeDuration,
               let age = Self.age(activatedAt: activatedAt, sensorAge: sensorAge, now: now),
               age >= wear // beyond expiration date
            {
                break
            }
            return .failed
        case .errorInfo,
             nil: break
        }
        // `activatedAt`/`activeDuration`/`preheatDuration` all come from the same
        // server-fetched DeviceInfo record — a bound sensor's validateDeviceByMacV2
        // always returns real durations, so they're present or absent together. No
        // placeholder default: a missing duration means the lifecycle isn't known
        // yet, not that a generic 14-day/30-min guess applies.
        guard let activatedAt, let wear = activeDuration, let warmup = preheatDuration else {
            return .noSensor
        }
        let age = Self.age(activatedAt: activatedAt, sensorAge: sensorAge, now: now) ?? 0
        if age >= wear { return .expired }
        if age < warmup {
            return .warmup(progress: age / warmup, remaining: warmup - age)
        }
        let stale = latestReadingAt.map { abs(now.timeIntervalSince($0)) > signalLostThreshold } ?? !hasLiveMonitor
        if stale { return .signalLost(since: latestReadingAt ?? activatedAt) }
        return .active(remaining: wear - age, total: wear)
    }

    public var needsEnding: Bool {
        self == .failed
    }

    public var displayName: String {
        switch self {
        case .noSensor: return LocalizedString("No sensor", comment: "Syai lifecycle: none")
        case .warmup: return LocalizedString("Warming up", comment: "Syai lifecycle: warming up")
        case .active: return LocalizedString("Active", comment: "Syai lifecycle: active")
        case .expired: return LocalizedString("Expired", comment: "Syai lifecycle: expired")
        case .signalLost: return LocalizedString("Signal loss", comment: "Syai lifecycle: signal loss")
        case .failed: return LocalizedString("Sensor failed", comment: "Syai lifecycle: failed")
        case .unactivated: return LocalizedString("Sensor uninitialized", comment: "Syai lifecycle: unactivated")
        }
    }

    public static func faultStatusDetail(for kind: SyaiSensorFault.Kind) -> String {
        switch kind {
        case .deviceStateObsolete:
            return LocalizedString("Sensor malfunction, replace sensor", comment: "Status: sensor obsolete/dead")
        case .deviceStateUnactivated:
            return LocalizedString("Sensor uninitialized, is it activated?", comment: "Status: sensor reports itself unactivated")
        case .signalImplausible:
            return LocalizedString(
                "Sensor readings implausible, consider replacing sensor",
                comment: "Status: sensor is reporting implausable readings"
            )
        case .errorInfo:
            return LocalizedString("Sensor malfunction", comment: "Status: unspecified sensor fault")
        }
    }
}

func LocalizedString(_ key: String, tableName: String? = nil, value: String? = nil, comment: String) -> String {
    let bundle = Bundle(for: SyaiCGMManager.self)
    if let value = value {
        return NSLocalizedString(key, tableName: tableName, bundle: bundle, value: value, comment: comment)
    }
    return NSLocalizedString(key, tableName: tableName, bundle: bundle, comment: comment)
}
