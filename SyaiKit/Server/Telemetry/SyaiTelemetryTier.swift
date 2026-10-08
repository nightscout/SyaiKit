//
//  SyaiTelemetryTier.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

public enum SyaiTelemetryTier: Int, Sendable, Equatable, Comparable, CaseIterable {
    /// Sensor lifecycle only. Nothing about the sensor's operation or readings leaves the phone.
    case minimal = 0

    /// Adds sensor health (conn-state beacon, status frames). Carries no glucose.
    case standard = 1

    /// Adds glucose upload and the `cgm_state` event stream, which also embeds glucose values.
    case full = 2

    public static func < (lhs: SyaiTelemetryTier, rhs: SyaiTelemetryTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Whether sensor-health reporting is permitted (`standard` and up).
    public var reportsSensorHealth: Bool { self >= .standard }

    /// Whether anything carrying a glucose value may leave the phone. Gates both the upload queue
    /// and the `cgm_state` analytics event, which carries `adjustGlucose`/`orgGlucose`.
    public var uploadsGlucose: Bool { self == .full }

    /// Stable tag for `rawState`, independent of enum ordering.
    public var persistedTag: String {
        switch self {
        case .minimal: return "minimal"
        case .standard: return "standard"
        case .full: return "full"
        }
    }

    public init(persistedTag: String) {
        switch persistedTag {
        case "standard": self = .standard
        case "full": self = .full
        // Unknown or garbled tags fail closed to the least-sharing tier;
        // "minimal" itself also lands here via the default.
        default: self = .minimal
        }
    }
}
