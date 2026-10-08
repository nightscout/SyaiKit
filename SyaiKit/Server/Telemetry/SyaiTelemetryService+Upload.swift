//
//  SyaiTelemetryService+Upload.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

extension SyaiTelemetryService {
    /// Offline-queue cap: 360 records (~6h at one record/min). Past it the oldest are dropped.
    public static let queueCap = 360

    /// Transport-failure backoff ladder in seconds.
    public static let backoffSeconds: [TimeInterval] = [30, 60, 120, 300]

    /// Test/diagnostic introspection (@testable).
    var pendingCount: Int { queue.count }
    var pendingRecords: [SyaiUploadRecord] { queue }
    var acceptedCursor: UInt16? { lastAcceptedFrontIdx }

    /// Enqueue one decoded record for upload. No-op when opted out or at/below the dedup cursor.
    /// Also mirrors into the event channel as a `cgm_state` event. Never blocks the caller.
    public func enqueue(_ record: SyaiUploadRecord) {
        guard tier().uploadsGlucose else { return }
        if let sensor = sensorContext(), let account = accountContext() {
            bufferEvent(
                eventType: "flutter_cgm_event",
                eventName: "cgm_state",
                eventInfo: Self.cgmStateEventInfo(record: record, sensor: sensor, account: account),
                account: account
            )
        }
        if let last = lastAcceptedFrontIdx, cursorMac == sensorContext()?.mac,
           record.frontIdx <= last
        {
            return
        }
        queue.append(record)
        if queue.count > Self.queueCap {
            let dropped = queue.count - Self.queueCap
            queue.removeFirst(dropped)
            logger.warning("upload queue over cap \(Self.queueCap); dropped \(dropped) oldest record(s)")
        }
        persistQueue(queue)
        kickDrain()
    }

    /// Final upload before a sensor is ended; returns `true` when nothing is outstanding.
    /// Answers "were readings that *should* have been uploaded left behind?", not "does the
    /// server have every reading?". Below `full` tier there is nothing outstanding by design.
    /// Bounded: each pass must shrink the queue or the loop stops, so teardown is not blocked.
    public func flushBeforeTeardown(timeout: TimeInterval = 10) async -> Bool {
        guard !queue.isEmpty else { return true }
        guard tier().uploadsGlucose else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while !queue.isEmpty, Date() < deadline {
            let before = queue.count
            kickDrain()
            guard let task = drainTask else { break }
            await task.value
            if queue.count >= before {
                logger.debug("teardown flush made no progress; \(queue.count) record(s) unsynced")
                break
            }
        }
        return queue.isEmpty
    }

    func kickDrain() {
        guard drainTask == nil else {
            drainAgain = true
            return
        }
        drainAgain = false
        drainTask = Task { [weak self] in
            await self?.drain()
        }
    }

    /// One drain pass: upload the backlog as one batched POST. All entries share one `timeAppReceive`.
    private func drain() async {
        defer {
            drainTask = nil
            if drainAgain { kickDrain() }
        }
        guard tier().uploadsGlucose else { return }
        guard !queue.isEmpty else { return }
        guard let context = sensorContext() else {
            logger.debug("no active sensor context; \(queue.count) record(s) stay queued")
            return
        }
        if context.mac != cursorMac {
            cursorMac = context.mac
            lastAcceptedFrontIdx = nil
        }

        // `serverDeviceId` comes from `device/authInfo`, fetched lazily on first upload and then
        // persisted. If it can't be fetched, records stay queued; an id is never fabricated.
        var serverDeviceId = context.serverDeviceId
        if serverDeviceId == nil {
            do {
                let fetched = try await fetchServerDeviceId(context.mac)
                await forwardSessionRotation()
                if let fetched {
                    persistServerDeviceId(fetched)
                    serverDeviceId = fetched
                    logger.debug("authInfo: lazily fetched serverDeviceId=\(fetched)")
                } else {
                    logger.warning("authInfo carried no device id; keeping \(queue.count) record(s) queued")
                    scheduleRetry()
                    return
                }
            } catch {
                await forwardSessionRotation()
                logger.warning("authInfo failed: \(String(describing: error)); keeping \(queue.count) record(s) queued")
                handleTransportFailure()
                return
            }
        }
        guard tier().uploadsGlucose, let deviceId = serverDeviceId else { return }

        // Build the batched body: every record contributes a `dataType:1` row; at `frontIdx % 5 == 0`
        // (excluding 0) a field-identical `dataType:2` checkpoint piggybacks after it. A multi-record
        // batch shares one `timeAppReceive`, the newest record's receipt instant.
        let batch = queue
        let sharedReceiptMs = batch[batch.count - 1].receivedAtMs
        var dataList: [[String: Any]] = []
        dataList.reserveCapacity(batch.count * 2)
        for record in batch {
            var entry = record.dataListEntry(activatedAtMs: context.activatedAtMs)
            if batch.count > 1 { entry["timeAppReceive"] = NSNumber(value: sharedReceiptMs) }
            dataList.append(entry)
            if record.frontIdx % 5 == 0, record.frontIdx != 0 {
                var dup = record.checkpointDuplicate(activatedAtMs: context.activatedAtMs)
                if batch.count > 1 { dup["timeAppReceive"] = NSNumber(value: sharedReceiptMs) }
                dataList.append(dup)
            }
        }
        let body: [String: Any] = [
            "deviceId": NSNumber(value: deviceId),
            "embeddedSoftVersion": context.embeddedSoftVersion,
            "dataList": dataList
        ]

        do {
            let code = try await sendBatch(body)
            await forwardSessionRotation()
            // applyTierChange / clearQueue may have emptied the queue while
            // the POST was in flight; only mutate when our batch is still
            // intact at the front.
            guard queue.starts(with: batch) else { return }
            if code == "OK" || code == "SUCCESS" {
                lastAcceptedFrontIdx = batch[batch.count - 1].frontIdx
                queue.removeFirst(batch.count)
                persistQueue(queue)
                consecutiveFailures = 0
                retryTask?.cancel()
                retryTask = nil
                logger.debug("uploaded \(batch.count) record(s) (\(dataList.count) entries); code=\(code)")
                if !queue.isEmpty { kickDrain() } // records arrived mid-flight
            } else {
                // Business-code rejection is terminal for the batch; drop rather than spin.
                logger.error("glucose upload rejected code=\(code); dropping \(batch.count) record(s)")
                queue.removeFirst(batch.count)
                persistQueue(queue)
                consecutiveFailures = 0
            }
        } catch {
            await forwardSessionRotation()
            logger.warning("glucose upload failed: \(String(describing: error)); \(batch.count) record(s) stay queued")
            handleTransportFailure()
        }
    }

    private func handleTransportFailure() {
        consecutiveFailures += 1
        persistQueue(queue) // spill so a kill doesn't lose the backlog
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        let delay = Self.backoffSeconds[min(max(consecutiveFailures - 1, 0), Self.backoffSeconds.count - 1)]
        logger.debug("retrying glucose upload in \(Int(delay))s (failure \(consecutiveFailures))")
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.fireRetry()
        }
    }

    private func fireRetry() {
        retryTask = nil
        guard tier().uploadsGlucose else { return }
        kickDrain()
    }
}

public extension SyaiEnvelopedClient {
    /// `POST cgm/security/data/collect/collect/glucose/v2`. Body is `{deviceId, embeddedSoftVersion,
    /// dataList:[…]}` built from `SyaiUploadRecord`s.
    ///
    /// Returns the envelope `code` (defaults to "OK" when absent). The `data:1` payload is an
    /// opaque success ack, not an accepted count.
    ///
    /// Lives under a different path base (`cgm/security/data/collect`) than every other call
    /// (`cgm/security/app/server`), so it uses an absolute URL; routing through `envelopedPOST(path:)`
    /// would wrongly prepend the app/server prefix and 404.
    private static let uploadGlucoseURL = URL(
        string: "https://api.syai.com/cgm/security/data/collect/collect/glucose/v2"
    )!

    func uploadGlucose(_ body: [String: Any]) async throws -> String {
        guard backend.isConfigured else { throw TransportError.notConfigured }
        try await ensureAccessToken() // gated call: needs a live Authorization token
        let data = try await envelopedPOST(
            url: Self.uploadGlucoseURL,
            bodyJSON: try JSONSerialization.data(withJSONObject: body),
            extraHeaders: [:], includeProductModel: false, authed: true
        )
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (root?["code"] as? String) ?? "OK"
    }

    /// Parsed `GET device/authInfo` result: server `id` (upload body's `deviceId`), server `code`,
    /// and the raw decrypted payload (reused by the calibration provider's keyA handling).
    struct SyaiAuthInfo: Sendable {
        /// Server `code` (`OK` on success; e.g. `USER_NOT_BIND_DEVICE`). Surfaced, not thrown.
        public let code: String
        /// `data.id`: numeric server-side device id; nil when absent.
        public let serverDeviceId: Int?
        /// Full decrypted response body.
        public let raw: Data
    }

    /// GET `device/authInfo`. Enveloped body is `{mac, sign}` (`sign`, not `signature`), signed
    /// with the sandwiched-key md5 (`SyaiBackend.signAuthInfo`), and carries the `productModel` header.
    func authInfo(mac: String) async throws -> SyaiAuthInfo {
        guard backend.isConfigured else { throw TransportError.notConfigured }
        try await ensureAccessToken() // gated call: needs a live Authorization token
        let ts = SyaiBackend.timestampMillis()
        let signature = backend.signAuthInfo(mac: mac, timestamp: ts)
        let data = try await envelopedGET(
            path: "device/authInfo",
            body: ["mac": mac, "sign": signature],
            extraHeaders: ["timestamp": ts],
            includeProductModel: true // carries productModel like validateMac (python reference)
        )
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TransportError.badResponse("authInfo body not JSON")
        }
        let code = (root["code"] as? String) ?? "OK"
        let dataObj = (root["data"] as? [String: Any]) ?? root
        let serverDeviceId = (dataObj["id"] as? NSNumber)?.intValue
        return SyaiAuthInfo(code: code, serverDeviceId: serverDeviceId, raw: data)
    }
}
