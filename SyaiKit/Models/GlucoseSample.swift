//
//  GlucoseSample.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

public struct GlucoseSample: Equatable, Sendable {
    public enum Trend: Equatable, Sendable {
        case notDetermined
        case fallingQuickly
        case falling
        case stable
        case rising
        case risingQuickly
    }

    public enum Source: Equatable, Sendable {
        case realtime
        case historicalBackfill
    }

    public enum Condition: Equatable, Sendable {
        case belowRange
        case aboveRange
    }

    public let date: Date
    public let valueMgDL: Double
    public let trend: Trend
    public let rateOfChangeMgDLPerMinute: Double?
    public let condition: Condition?

    /// Sensor's own running record index. Unique within a session; used as
    /// the dedup key and syncIdentifier suffix.
    public let sequence: UInt16
    public let rawBaseMgDL: Double

    /// Raw electrode current (the decoder's V0 channel), feeding the
    /// plausibility guard (`SyaiPlausibilityGuard`); nil only for samples
    /// persisted before this field existed.
    public let rawCurrent: Double?

    /// Seconds since sensor activation (the decoder's V2 channel): the
    /// sensor's own clock, unaffected by BLE notify latency or reconnect
    /// churn. This is the source of truth `date` is derived from; nil only
    /// for samples persisted before this field existed.
    public let elapsedSeconds: TimeInterval?

    /// Sensor-reported hardware/data fault; drop rather than forward.
    public let hasBlockingIssue: Bool

    public let source: Source
    public let wasForwarded: Bool
    public let forwardSkipReason: String?

    public init(
        date: Date,
        valueMgDL: Double,
        trend: Trend,
        rateOfChangeMgDLPerMinute: Double?,
        sequence: UInt16,
        rawBaseMgDL: Double,
        rawCurrent: Double? = nil,
        elapsedSeconds: TimeInterval? = nil,
        condition: Condition? = nil,
        hasBlockingIssue: Bool = false,
        source: Source = .realtime,
        wasForwarded: Bool = false,
        forwardSkipReason: String? = nil
    ) {
        self.date = date
        self.valueMgDL = valueMgDL
        self.trend = trend
        self.rateOfChangeMgDLPerMinute = rateOfChangeMgDLPerMinute
        self.sequence = sequence
        self.rawBaseMgDL = rawBaseMgDL
        self.rawCurrent = rawCurrent
        self.elapsedSeconds = elapsedSeconds
        self.condition = condition
        self.hasBlockingIssue = hasBlockingIssue
        self.source = source
        self.wasForwarded = wasForwarded
        self.forwardSkipReason = forwardSkipReason
    }

    public func withForwardingOutcome(wasForwarded: Bool, skipReason: String?) -> GlucoseSample {
        GlucoseSample(
            date: date, valueMgDL: valueMgDL, trend: trend,
            rateOfChangeMgDLPerMinute: rateOfChangeMgDLPerMinute, sequence: sequence,
            rawBaseMgDL: rawBaseMgDL,
            rawCurrent: rawCurrent,
            elapsedSeconds: elapsedSeconds,
            condition: condition,
            hasBlockingIssue: hasBlockingIssue,
            source: source,
            wasForwarded: wasForwarded, forwardSkipReason: skipReason
        )
    }
}

extension GlucoseSample {
    init?(rawValue: [String: Any]) {
        guard let date = rawValue["d"] as? Date,
              let valueMgDL = rawValue["v"] as? Double,
              let seq = (rawValue["sq"] as? Int).map({ UInt16(clamping: $0) }),
              let trendRaw = rawValue["tr"] as? String,
              let trend = Trend(rawString: trendRaw)
        else { return nil }
        self.date = date
        self.valueMgDL = valueMgDL
        self.trend = trend
        rateOfChangeMgDLPerMinute = rawValue["r"] as? Double
        sequence = seq
        rawBaseMgDL = rawValue["rb"] as? Double ?? valueMgDL
        rawCurrent = rawValue["rc"] as? Double
        elapsedSeconds = rawValue["es"] as? Double
        source = (rawValue["s"] as? String).flatMap(Source.init(rawString:)) ?? .realtime
        wasForwarded = rawValue["fw"] as? Bool ?? false
        forwardSkipReason = rawValue["fr"] as? String
        hasBlockingIssue = rawValue["bi"] as? Bool ?? false
        condition = (rawValue["c"] as? String).flatMap(Condition.init(rawString:))
    }

    var rawValue: [String: Any] {
        var raw: [String: Any] = [
            "d": date, "v": valueMgDL, "sq": Int(sequence),
            "tr": trend.rawString,
            "rb": rawBaseMgDL
        ]
        raw["r"] = rateOfChangeMgDLPerMinute
        raw["rc"] = rawCurrent
        raw["es"] = elapsedSeconds
        if source != .realtime { raw["s"] = source.rawString }
        if wasForwarded { raw["fw"] = true }
        raw["fr"] = forwardSkipReason
        if hasBlockingIssue { raw["bi"] = true }
        if let condition { raw["c"] = condition.rawString }
        return raw
    }
}

extension GlucoseSample.Condition {
    fileprivate var rawString: String {
        switch self {
        case .belowRange: return "lo"
        case .aboveRange: return "hi"
        }
    }

    init?(rawString: String) {
        switch rawString {
        case "lo": self = .belowRange
        case "hi": self = .aboveRange
        default: return nil
        }
    }
}

extension GlucoseSample.Source {
    fileprivate var rawString: String {
        switch self {
        case .realtime: return "rt"
        case .historicalBackfill: return "hb"
        }
    }

    init?(rawString: String) {
        switch rawString {
        case "rt": self = .realtime
        case "hb": self = .historicalBackfill
        default: return nil
        }
    }
}

extension GlucoseSample.Trend {
    fileprivate var rawString: String {
        switch self {
        case .notDetermined: return "u"
        case .fallingQuickly: return "ff"
        case .falling: return "f"
        case .stable: return "s"
        case .rising: return "r"
        case .risingQuickly: return "rr"
        }
    }

    init?(rawString: String) {
        switch rawString {
        case "u": self = .notDetermined
        case "ff": self = .fallingQuickly
        case "f": self = .falling
        case "s": self = .stable
        case "r": self = .rising
        case "rr": self = .risingQuickly
        default: return nil
        }
    }
}
