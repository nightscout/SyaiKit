//
//  CGMManager+Ingest.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation
import HealthKit
@preconcurrency import LoopKit

extension SyaiCGMManager {
    @MainActor func ingest(_ sample: GlucoseSample) {
        if state.sensorNeedsReplacement {
            logger.debug("sensor marked for replacement; dropping seq=\(sample.sequence) (\(Int(sample.valueMgDL)) mg/dL)")
            return
        }

        var sample = sample
        // The frame's arrival instant, captured before `date` is replaced by
        // sensor time. The only thing it is ever used for is spanning the
        // silence since the sensor last spoke; it never dates a reading.
        let receivedAt = sample.date

        // `activatedAt` is normally exact already: captured once, at the
        // moment the activation write reset the sensor's RTC to 0
        // (`SyaiPairingService.swift`), and persisted from then on — nothing
        // needs to re-derive it in the common case. This only fills it in if
        // it's somehow missing, using a realtime frame's own wall-clock
        // receipt time and elapsed-seconds field; backfilled frames' receipt
        // time is "when we requested history", not "when the reading was
        // taken", so it must never feed this.
        var activatedAt = state.activatedAt
        if activatedAt == nil, sample.source == .realtime, let elapsedSeconds = sample.elapsedSeconds {
            activatedAt = sample.date.addingTimeInterval(-elapsedSeconds)
        }

        if let elapsedSeconds = sample.elapsedSeconds, let activatedAt {
            let trueDate = activatedAt.addingTimeInterval(elapsedSeconds)
            sample = GlucoseSample(
                date: trueDate, valueMgDL: sample.valueMgDL, trend: sample.trend,
                rateOfChangeMgDLPerMinute: sample.rateOfChangeMgDLPerMinute,
                sequence: sample.sequence, rawBaseMgDL: sample.rawBaseMgDL,
                rawCurrent: sample.rawCurrent, elapsedSeconds: sample.elapsedSeconds,
                condition: sample.condition, hasBlockingIssue: sample.hasBlockingIssue,
                source: sample.source
            )
        }

        let isWarmupReading = Self.isWarmup(
            elapsedSeconds: sample.elapsedSeconds,
            preheatDuration: state.preheatDuration
        )
        let isExpiredReading = Self.isPastWear(
            elapsedSeconds: sample.elapsedSeconds,
            activeDuration: state.activeDuration
        )
        if !isWarmupReading, !isExpiredReading { recordSample(sample) }

        if sample.source == .realtime {
            firePendingBackfill(newest: sample.sequence)
        }

        var updated = state

        // Never move the freshness marker backwards for an old backfilled
        // record. Ordered by the sensor's elapsed field rather than by the
        // dates themselves, so nothing here depends on the phone's clock or on
        // `activatedAt` being right.
        // Only a live record can be the newest one, and it updates both halves
        // of the pair together: an elapsed value paired with a receipt instant
        // from a different frame would misstate the age by the difference.
        if sample.source == .realtime,
           let elapsedSeconds = sample.elapsedSeconds,
           elapsedSeconds >= (updated.latestElapsedSeconds ?? -1)
        {
            updated.latestReadingTimestamp = sample.date
            updated.latestElapsedSeconds = elapsedSeconds
            updated.latestElapsedReceivedAt = receivedAt
        }

        // Tracks the newest record we hold *on the grid*, not the newest record
        // full stop: recovery is expressed in the same terms as forwarding, so
        // a grid record we failed to fetch stays inside the request range until
        // it actually arrives. Because it's the newest grid record rather than
        // the oldest missing one, a record the sensor can't produce is dropped
        // as soon as any later grid record lands — the retry is bounded by
        // itself and needs no attempt counter.
        if Self.isOnForwardGrid(sequence: sample.sequence),
           sample.sequence > (updated.lastGridSequence ?? 0)
        {
            updated.lastGridSequence = sample.sequence
        }

        if state.activatedAt == nil, let activatedAt {
            updated.sensors.setActivatedAt(activatedAt)
        }
        setState(updated)
        notifyStateObservers()

        updateStatusDetail(nil)

        if isWarmupReading {
            logger.debug("preheat: \(Int(sample.valueMgDL)) mg/dL seq=\(sample.sequence); not forwarding")
            return
        }

        // The sensor keeps streaming past the end of its wear window; those
        // records are beyond what the calibration covers, so like warmup they
        // are dropped here rather than shown or dosed on. The freshness
        // markers above still advance, so a chatty dead sensor doesn't read
        // as signal loss.
        if isExpiredReading {
            logger.debug("past wear: \(Int(sample.valueMgDL)) mg/dL seq=\(sample.sequence); not forwarding")
            return
        }

        if sample.hasBlockingIssue {
            logger.debug("blocking issue: \(Int(sample.valueMgDL)) mg/dL seq=\(sample.sequence); not forwarding")
            recordForwardingOutcome(
                forSequence: sample.sequence,
                wasForwarded: false,
                skipReason: "Sensor reported fault"
            )
            return
        }

        // Data-plausibility guard (fed post-warmup samples only). `attention`
        // suppresses forwarding while it holds; `broken` latches the sensor as
        // failed, persisted, with no destructive action.
        if let rawCurrent = sample.rawCurrent {
            if let event = plausibilityGuard.record(
                sequence: sample.sequence,
                current: rawCurrent,
                glucoseMmolL: sample.rawBaseMgDL / 18.0
            ) {
                switch event.level {
                case .attention:
                    logger
                        .warning(
                            "implausible data streak (\(event.reason.rawValue)) at seq=\(sample.sequence); suppressing forwarding while it holds"
                        )
                case .broken:
                    logger
                        .error(
                            "implausible data broken tier (\(event.reason.rawValue)) at seq=\(sample.sequence); declaring sensor failed"
                        )
                    markSensorFailed(SyaiSensorFault(kind: .signalImplausible, raw: Data(), receivedAt: sample.date))
                }
            }
        }
        if state.sensorFault != nil {
            recordForwardingOutcome(
                forSequence: sample.sequence,
                wasForwarded: false,
                skipReason: "Sensor declared failed (implausible data)"
            )
            return
        }
        if plausibilityGuard.attentionActive {
            updateStatusDetail(LocalizedString(
                "Sensor data looks wrong, readings paused — if this persists, replace the sensor",
                comment: "Status: implausible data streak"
            ))
            recordForwardingOutcome(
                forSequence: sample.sequence,
                wasForwarded: false,
                skipReason: "Implausible data streak"
            )
            return
        }

        // The sensor pushes every minute; Loop doses on a 5-minute cadence.
        // Which readings get forwarded is decided entirely by the sensor's own
        // counter — every 5th record, live or backfilled, no wall-clock
        // comparison anywhere — for the same reason `date` comes from the
        // sensor's elapsed-seconds field: receipt times drift with BLE latency
        // and reconnect churn, the sequence doesn't. One grid shared by both
        // sources is what stops them landing a minute apart or out of order,
        // and every point on it clears stock Trio's 3.5-min backfill dedupe.
        guard Self.isOnForwardGrid(sequence: sample.sequence) else {
            logger.debug("not forwarding \(Int(sample.valueMgDL)) mg/dL seq=\(sample.sequence): off the 5-min grid")
            recordForwardingOutcome(
                forSequence: sample.sequence,
                wasForwarded: false,
                skipReason: "Off the 5-min grid"
            )
            return
        }

        let loopCondition: GlucoseCondition?
        switch sample.condition {
        case .belowRange?: loopCondition = .belowRange
        case .aboveRange?: loopCondition = .aboveRange
        case nil: loopCondition = nil
        }

        let newSample = NewGlucoseSample(
            date: sample.date,
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: sample.valueMgDL),
            condition: loopCondition,
            trend: Self.mapTrend(sample.trend),
            trendRate: sample.rateOfChangeMgDLPerMinute.map {
                HKQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0)
            },
            isDisplayOnly: false,
            wasUserEntered: false,
            syncIdentifier: "syai-\(state.mac ?? "unknown")-\(sample.sequence)",
            syncVersion: 1,
            device: device
        )

        logger.debug("forwarding to Loop: \(Int(sample.valueMgDL)) mg/dL seq=\(sample.sequence)")
        var stamped = state

        // Diagnostic only — nothing reads this to make a decision — but kept in
        // sensor order like everything else.
        if sample.date > (stamped.latestForwardedToLoopAt ?? .distantPast) {
            stamped.latestForwardedToLoopAt = sample.date
        }
        if sample.source != .historicalBackfill {
            stamped.latestSample = sample.withForwardingOutcome(wasForwarded: true, skipReason: nil)
        }
        setState(stamped)
        recordForwardingOutcome(forSequence: sample.sequence, wasForwarded: true, skipReason: nil)

        if sample.source == .historicalBackfill {
            pendingBackfillSamples.append(newSample)
        } else {
            flushPendingBackfill()
            delegateQueue?.async { [weak self] in
                guard let self else { return }
                self.cgmManagerDelegate?.cgmManager(self, hasNew: .newData([newSample]))
            }
        }
    }

    /// Whether a sample sits on the 5-minute forwarding grid (LibreLoop's
    /// `lifeCount % 5` pattern, so no Trio-side patch is needed). The sequence
    /// ticks exactly 1/min from activation, so `% 5` is a 5-min grid fixed by
    /// the sensor itself — the same grid for live and backfilled readings,
    /// which is what keeps the two sources from interleaving. Stock Trio
    /// dedupes incoming backfill against any stored point within 3.5 min, and
    /// every point on this grid clears that window.
    static func isOnForwardGrid(sequence: UInt16) -> Bool {
        sequence % forwardGridStep == 0
    }

    /// One forwarded reading per this many sensor records (1 record = 1 min).
    static let forwardGridStep: UInt16 = 5

    /// Whether a reading was taken during warmup, judged by the sensor's own
    /// elapsed-seconds field rather than `date - activatedAt`: same answer when
    /// the anchor is right, independent of it when it isn't.
    ///
    /// Deliberately not expressed as a sequence range. The record index ticks
    /// from 0 at activation at exactly 60 s on both firmwares, but index 0 is
    /// not at the same offset — measured `60·idx + 60` on V1.6 and
    /// `60·idx + 62` on V1.7 — so a 30-minute preheat ends after index 29 on
    /// one and index 28 on the other. Testing elapsed seconds is right on both
    /// without knowing which. A sensor with no known preheat isn't in warmup:
    /// the durations arrive together with the rest of `DeviceInfo`.
    static func isWarmup(elapsedSeconds: TimeInterval?, preheatDuration: TimeInterval?) -> Bool {
        guard let elapsedSeconds, let preheatDuration else { return false }
        return elapsedSeconds <= preheatDuration
    }

    static func isPastWear(elapsedSeconds: TimeInterval?, activeDuration: TimeInterval?) -> Bool {
        guard let elapsedSeconds, let activeDuration else { return false }
        return elapsedSeconds >= activeDuration
    }

    /// First sequence index worth requesting in a historical backfill.
    /// Warmup-era records do exist on the sensor (idx 0 of a fresh activation
    /// is a real, stored, wildly-wrong ~31 mmol/L record) and are technically
    /// backfillable, but the ingest preheat gate always drops them, so
    /// requesting them just buys airtime for guaranteed-dropped records.
    ///
    /// Index 0 is emitted ~1 min after activation, so `preheatMinutes` is the
    /// first index safely past preheat on either firmware mapping (see
    /// `isWarmup`: the exact boundary is index 29 on V1.6 and 28 on V1.7). One
    /// index conservative on V1.7, which costs nothing — `backfillRange` snaps
    /// the start up to the grid, and the first grid index at or after either
    /// boundary is 30 regardless.
    static func firstBackfillableSequence(preheatDuration: TimeInterval) -> UInt16 {
        let first = max(0, preheatDuration / 60)
        return UInt16(min(first, Double(UInt16.max)))
    }

    @MainActor func flushPendingBackfill() {
        guard !pendingBackfillSamples.isEmpty else { return }
        let batch = pendingBackfillSamples
        pendingBackfillSamples.removeAll()
        logger.debug("backfill: flushing \(batch.count) sample(s) to Loop in one batch")
        delegateQueue?.async { [weak self] in
            guard let self else { return }
            self.cgmManagerDelegate?.cgmManager(self, hasNew: .newData(batch))
        }
    }

    private static func mapTrend(_ trend: GlucoseSample.Trend) -> GlucoseTrend? {
        SyaiGlucoseDisplay.mapTrend(trend)
    }

    /// Records that fit in one history notify packet, which is the largest
    /// request the sensor is trusted to serve. Asking for more makes it page,
    /// and one V1.7 build mis-serves paged responses: the packet headers count
    /// correctly while the bodies replay earlier records, so the readings are
    /// real but attributed to the wrong minutes. Paging is sound by protocol
    /// and works on V1.6, so this is a firmware workaround, not a limit.
    ///
    /// A packet is an 8-byte header plus fixed-width records, capped at 176 B
    /// by the ATT MTU: 18 records on V1.7, 20 on V1.6. Both observed on the
    /// wire. Only a confirmed V1.6 gets the larger count, since 18 fits one
    /// packet at either record width.
    ///
    /// A smaller MTU would invalidate these; `SyaiSensorMonitor` warns if a
    /// request ever pages, and its per-record clock check stops a mis-served
    /// batch from being believed.
    static func maxBackfillRequestCount(parseVersion: String) -> UInt16 {
        parseVersion == "V1.6" ? 20 : 18
    }

    /// The records a backfill request should ask for, given the newest grid
    /// record we already hold (`have`) and the live sequence that just arrived.
    ///
    /// Both ends snap to the grid. Off-grid records at the head or tail of a
    /// hole would be thinned out on arrival, so fetching them only spends
    /// airtime on a link that has usually just come back up — the same
    /// reasoning as the preheat clamp. A hole with no grid record in it snaps
    /// to nothing and is not requested at all.
    ///
    /// `newest` is excluded: it is the frame that triggered this request, so we
    /// already have it. Asking for it anyway re-delivers a reading that was
    /// just ingested live, which shows up in Loop as a duplicate at the same
    /// timestamp. `remaining` is the tail left over when the hole is wider than
    /// one request, to be picked up by the next live sample.
    static func backfillRange(
        have: UInt16,
        newest: UInt16,
        firstRequestable: UInt16,
        maxCount: UInt16
    ) -> (start: UInt16, count: UInt16, remaining: UInt16?)? {
        let step = Int(forwardGridStep)
        guard maxCount > 0 else { return nil }
        let start = Self.nextOnGrid(atOrAfter: max(Int(have) + 1, Int(firstRequestable)))
        let last = (Int(newest) - 1) / step * step
        guard last >= start else { return nil }
        // Chunked walks stop on a grid index too, so resuming from `remaining`
        // can't step over the records the chunk didn't reach.
        let end = min(last, (start + Int(maxCount) - 1) / step * step)
        guard end >= start else { return nil }
        return (UInt16(start), UInt16(end - start + 1), end < last ? UInt16(end) : nil)
    }

    private static func nextOnGrid(atOrAfter sequence: Int) -> Int {
        let step = Int(forwardGridStep)
        return sequence + ((step - sequence % step) % step)
    }

    /// Requests whatever is missing between the newest record we hold and the
    /// live one that just arrived. Returns whether a request went out, so the
    /// caller knows older readings are still inbound.
    @MainActor private func firePendingBackfill(newest: UInt16) {
        // A gap opens two ways — a reconnect, or a frame lost mid-stream — and
        // both look identical from here. `pendingBackfillFrom` only carries the
        // tail of a gap too wide for one request; otherwise the ingest
        // watermark is the newest record we hold.
        guard let have = pendingBackfillFrom ?? state.lastGridSequence else { return }
        pendingBackfillFrom = nil
        guard let monitor else {
            logger.debug("backfill: skipped, no live monitor (have=\(have), seq=\(newest))")
            return
        }
        guard let preheat = state.preheatDuration else {
            logger.debug("backfill: skipped, no preheat duration for the current sensor (have=\(have), seq=\(newest))")
            return
        }
        let parseVersion = SyaiFrameParser.parseVersion(
            forDeviceVersion: state.sensors.current()?.deviceInfo.deviceVersion ?? ""
        )
        guard let range = Self.backfillRange(
            have: have,
            newest: newest,
            firstRequestable: Self.firstBackfillableSequence(preheatDuration: preheat),
            maxCount: Self.maxBackfillRequestCount(parseVersion: parseVersion)
        ) else {
            logger.debug("backfill: nothing missing at seq=\(newest) (have=\(have))")
            return
        }
        pendingBackfillFrom = range.remaining
        let end = range.start + range.count - 1
        if let remaining = range.remaining {
            logger.debug("backfill: requesting records \(range.start)…\(end) (of \(newest - 1); more queued from \(remaining))")
        } else {
            logger.debug("backfill: requesting records \(range.start)…\(end)")
        }
        Task { [weak self] in
            do {
                try await monitor.requestHistoricalBackfill(fromSequence: range.start, count: range.count)
            } catch {
                self?.logger.debug("historical backfill request failed: \(String(describing: error)); hole stays queued")

                Task { @MainActor in
                    guard let self, self.pendingBackfillFrom == range.remaining else { return }
                    self.pendingBackfillFrom = have
                }
            }
        }
    }
}
