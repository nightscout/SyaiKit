//
//  SyaiPlausibilityGuard.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// Client-side data-plausibility engine. The firmware never reports sensor-health
/// failures in its cmd state, so health is detected from the decoded data stream.
///
/// `attentionActive` suppresses forwarding to the dosing path once any detector
/// reaches its attention count (the official app only shows a dialog).
///
/// Glucose is evaluated unclamped (pre-range-censoring). Only the latched
/// `broken` verdict is persisted; streak/shake state is session-local.
///
/// Fed every post-warmup sample regardless of source, live or backfilled —
/// `ingest()` doesn't discriminate, and `record`'s dedup is per-sequence
/// rather than a monotonic watermark specifically so a backfilled gap still
/// reaches the detectors even though the live sample that triggered the
/// backfill request is always fed first and is usually the newer sequence.
public struct SyaiPlausibilityGuard: Sendable {
    public enum Reason: String, Equatable, Sendable, CaseIterable {
        case lowCurrent
        case glucoseHigh0
        case glucoseLow0
        case glucoseHigh1
        case glucoseLow1
        case shake
    }

    public enum Level: Equatable, Sendable, Comparable {
        case attention
        case broken
        private var rank: Int { self == .attention ? 0 : 1 }
        public static func < (l: Level, r: Level) -> Bool { l.rank < r.rank }
    }

    /// A threshold crossing entered on the most recent sample.
    public struct Event: Equatable, Sendable {
        public let reason: Reason
        public let level: Level
        public init(reason: Reason, level: Level) {
            self.reason = reason
            self.level = level
        }
    }

    public static let lowCurrentThreshold = 2000.0
    public static let high0Threshold = 40.0 // mmol/L
    public static let low0Threshold = 1.0
    public static let high1Threshold = 35.0
    public static let low1Threshold = 2.1
    public static let attentionCount0 = 5 // amps/high0/low0 attention streak
    public static let brokenCount0 = 35 // amps/high0/low0 broken streak
    public static let attentionCount1 = 10 // high1/low1 attention streak
    public static let brokenCount1 = 250 // high1/low1 broken streak
    public static let shakeMinDeltaMmolL = 2.0
    public static let shakePointLimit = 30

    public private(set) var attentionReasons: Set<Reason> = []

    private var streaks: [Reason: Int] = [:]
    private var shakePoints: Set<UInt16> = []

    /// Last fed samples for the three-point extremum test. A sequence gap
    /// (reconnect, dropped record) breaks the window rather than comparing
    /// across it.
    private var window: [(sequence: UInt16, glucoseMmolL: Double)] = []

    /// Sequences already fed, so a re-delivered frame (reconnect churn,
    /// overlapping backfill range) can't be counted twice. Deliberately not a
    /// monotonic high-watermark: a live sample commonly arrives (and gets fed)
    /// before the backfill batch that fills the gap behind it, and that older,
    /// never-before-seen backfill still needs to reach the detectors instead
    /// of being mistaken for something already screened.
    private var fedSequences: Set<UInt16> = []

    public init() {}

    public var attentionActive: Bool { !attentionReasons.isEmpty }

    /// Feed one post-warmup sample — live or backfilled, in whatever order it
    /// arrives. Returns the highest-severity threshold crossing this sample
    /// caused, if any. A sequence already fed (exact re-delivery) is ignored
    /// so interleaving can't double-count; that's the only case skipped, so
    /// backfill that lands behind an already-fed live sample still counts.
    public mutating func record(sequence: UInt16, current: Double, glucoseMmolL: Double) -> Event? {
        guard fedSequences.insert(sequence).inserted else { return nil }

        var event: Event?
        for detector in Self.detectors {
            let streak = detector.isError(current, glucoseMmolL) ? (streaks[detector.reason] ?? 0) + 1 : 0
            streaks[detector.reason] = streak
            if streak >= detector.attentionCount {
                if streak == detector.attentionCount, event == nil {
                    event = Event(reason: detector.reason, level: .attention)
                }
                attentionReasons.insert(detector.reason)
            } else {
                attentionReasons.remove(detector.reason)
            }
            if streak == detector.brokenCount {
                event = Event(reason: detector.reason, level: .broken)
            }
        }

        window.append((sequence, glucoseMmolL))
        if window.count > 3 { window.removeFirst() }
        if let extremum = shakeExtremumSequence(),
           shakePoints.insert(extremum).inserted,
           shakePoints.count == Self.shakePointLimit, event?.level != .broken
        {
            event = Event(reason: .shake, level: .broken)
        }
        return event
    }

    private static let detectors: [(reason: Reason, isError: (Double, Double) -> Bool, attentionCount: Int, brokenCount: Int)] = [
        (.lowCurrent, { current, _ in current < lowCurrentThreshold }, attentionCount0, brokenCount0),
        (.glucoseHigh0, { _, mmol in mmol > high0Threshold }, attentionCount0, brokenCount0),
        (.glucoseLow0, { _, mmol in mmol < low0Threshold }, attentionCount0, brokenCount0),
        (.glucoseHigh1, { _, mmol in mmol > high1Threshold }, attentionCount1, brokenCount1),
        (.glucoseLow1, { _, mmol in mmol < low1Threshold }, attentionCount1, brokenCount1)
    ]

    /// A shake point is a local extremum across three consecutively-indexed
    /// records whose middle value differs from both neighbours by at least
    /// `shakeMinDeltaMmolL`. Each sample gets exactly one chance to qualify.
    private func shakeExtremumSequence() -> UInt16? {
        guard window.count == 3,
              window[0].sequence + 1 == window[1].sequence,
              window[1].sequence + 1 == window[2].sequence else { return nil }
        let a = window[0].glucoseMmolL, b = window[1].glucoseMmolL, c = window[2].glucoseMmolL
        let isExtremum = (b > a && b > c) || (a > b && c > b)
        guard isExtremum,
              abs(b - a) >= Self.shakeMinDeltaMmolL,
              abs(b - c) >= Self.shakeMinDeltaMmolL else { return nil }
        return window[1].sequence
    }
}
