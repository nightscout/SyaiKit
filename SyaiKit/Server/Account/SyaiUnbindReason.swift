//
//  SyaiUnbindReason.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// Why a sensor's session is being ended, sent as `unBindDevice`'s `unbindType`.
///
/// The server treats this as an attribution field: every code performs the same
/// unbind, but it tells Syai whether a sensor was retired normally or died.
/// Getting it right matters for the user, not for us — a hardware failure
/// filed as a voluntary end is the kind of thing that decides a warranty claim.
public enum SyaiUnbindReason: Int, Sendable, Equatable {
    /// The sensor reported itself dead.
    case sensorFailed = 19

    /// Ended before the sensor ever finished warming up.
    case endedDuringWarmup = 16

    /// Wear window elapsed, everything uploaded.
    case expired = 10

    /// Wear window elapsed, readings left unuploaded.
    case expiredDiscardingData = 11

    /// Finished early by choice, everything uploaded.
    case endedEarly = 13

    /// Finished early by choice, readings left unuploaded.
    case endedEarlyDiscardingData = 20

    /// Pick the reason the way the app's equivalent flow does: warmup first,
    /// then expiry, then a plain early end, with the sync state choosing within
    /// each pair — and our own fault latch taking priority over all of it.
    public static func forLifecycle(
        _ lifecycle: SyaiSensorLifecycle,
        hasUnsyncedData: Bool
    ) -> SyaiUnbindReason {
        switch lifecycle {
        case .failed: return .sensorFailed
        case .warmup: return .endedDuringWarmup
        case .expired: return hasUnsyncedData ? .expiredDiscardingData : .expired
        // `signalLost` is usually transient and `unactivated` just means the
        // sensor's reported state doesn't match what we expect; neither says
        // this sensor's wear ended.
        case .active,
             .noSensor,
             .signalLost,
             .unactivated:
            return hasUnsyncedData ? .endedEarlyDiscardingData : .endedEarly
        }
    }
}
