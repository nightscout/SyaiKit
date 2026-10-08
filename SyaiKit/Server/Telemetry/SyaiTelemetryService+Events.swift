//
//  SyaiTelemetryService+Events.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

extension SyaiTelemetryService {
    /// Auto-flush threshold, matching the official app's buffer size.
    public static let eventBatchThreshold = 10

    /// Test/diagnostic introspection (@testable).
    var pendingEventCount: Int { eventBuffer.count }

    private static func epochMs(_ date: Date = Date()) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    /// Buffer one event, computing `eventDiffTime` and wrapping `eventInfo` in the event envelope.
    /// Auto-flushes at `eventBatchThreshold`. Callers have already passed the opt-out gate.
    func bufferEvent(
        eventType: String,
        eventName: String,
        eventInfo: [String: Any],
        account: AccountContext
    ) {
        let now = Self.epochMs()
        var info = eventInfo
        info["eventDiffTime"] = NSNumber(value: eventDiffAnchorMs.map { now - $0 } ?? 0)
        eventDiffAnchorMs = now
        let event: [String: Any] = [
            "userId": account.userId,
            "appName": account.appName,
            "eventType": eventType,
            "eventName": eventName,
            "eventInfo": info,
            "eventPlatform": "APP",
            "appCreateTime": NSNumber(value: now)
        ]
        eventBuffer.append(event)
        if eventBuffer.count >= Self.eventBatchThreshold {
            flushEvents()
        }
    }

    /// Send the buffered batch to `batchStoreEventTracking`. Fire-and-forget: the buffer is
    /// cleared up front, so a failed batch is dropped with no retry or persistence (analytics only).
    public func flushEvents() {
        guard tier().reportsSensorHealth else { return }
        guard !eventBuffer.isEmpty else { return }
        let batch = eventBuffer
        eventBuffer.removeAll()
        // The first event of the next buffer measures its `eventDiffTime`
        // from this flush.
        eventDiffAnchorMs = Self.epochMs()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sendEvents(batch)
                self.logger.debug("event batch flushed (\(batch.count) event(s))")
            } catch {
                self.logger.warning("event batch dropped after send failure (no retry, analytics): \(String(describing: error))")
            }
            await self.forwardSessionRotation()
        }
    }

    /// `cgm_state` eventInfo shape. `glucose` is the raw current (integer), not a glucose value.
    /// `deviceId` and `voltage` are omitted when nil. `eventDiffTime` is added by `bufferEvent`.
    static func cgmStateEventInfo(
        record: SyaiUploadRecord,
        sensor: SensorContext,
        account: AccountContext
    ) -> [String: Any] {
        var info: [String: Any] = [
            "userId": account.userId,
            "mac": sensor.mac,
            "time": NSNumber(value: record.runSec),
            "dataNo": NSNumber(value: record.frontIdx),
            "glucose": NSNumber(value: record.current),
            "temperature": record.temperatureC,
            "adjustGlucose": record.glucoseMmol,
            "orgGlucose": record.glucoseMmol,
            "adjustState": NSNull(),
            "monitorTime": NSNumber(value: sensor.activatedAtMs + Int64(record.runSec) * 1000),
            "dataStatus": 1,
            "softVersion": sensor.embeddedSoftVersion,
            "dataTag": "expression"
        ]
        if let voltage = record.voltage { info["voltage"] = NSNumber(value: voltage) }
        if let deviceId = sensor.serverDeviceId { info["deviceId"] = NSNumber(value: deviceId) }
        return info
    }

    /// `cgm_connect`/`cgm_disconnect` eventInfo shape. Durations are 0-placeholders: BLE timings
    /// are not plumbed through three layers for an analytics channel. `eventDiffTime` is added by `bufferEvent`.
    static func connEventInfo(mac: String, connected: Bool) -> [String: Any] {
        [
            "mac": mac,
            "state": connected ? "true" : "false",
            "steps": [Any](),
            "errorInfo": "",
            "scanDuration": 0,
            "connectDuration": 0,
            "authDuration": 0,
            "allDuration": 0
        ]
    }

    /// `cgm_notify_info`: wire-ready but deliberately uncalled. Raw error-info notify bytes are
    /// not surfaced above `SyaiBLE` today; to wire this up, add a notify stream to `SyaiSensorSession`.
    public func reportNotifyInfo(orgHex: String, mac: String) {
        guard tier().reportsSensorHealth else { return }
        guard let account = accountContext() else { return }
        guard let info = Self.notifyInfoEventInfo(orgHex: orgHex, mac: mac) else { return }
        bufferEvent(
            eventType: "flutter_cgm_event",
            eventName: "cgm_notify_info",
            eventInfo: info,
            account: account
        )
    }

    /// `cgm_notify_info` eventInfo shape. `header` is the decimal LE16 opcode, `headerHex` its
    /// 4-char hex, `content` the body as one LE integer decimal string. nil for malformed hex or
    /// a frame under 2 bytes; a body over 8 bytes reports content "0".
    private static func notifyInfoEventInfo(orgHex: String, mac: String) -> [String: Any]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(orgHex.count / 2)
        var index = orgHex.startIndex
        while index < orgHex.endIndex {
            let next = orgHex.index(index, offsetBy: 2, limitedBy: orgHex.endIndex) ?? orgHex.endIndex
            guard let byte = UInt8(orgHex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        guard bytes.count >= 2 else { return nil }
        let header = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let body = bytes.dropFirst(2)
        var content: UInt64 = 0
        if body.count <= 8 {
            for (i, b) in body.enumerated() { content |= UInt64(b) << (8 * i) }
        }
        return [
            "header": String(header),
            "headerHex": String(format: "%04x", header),
            "content": String(content),
            "orgHex": orgHex,
            "mac": mac
        ]
    }
}

extension SyaiEnvelopedClient {
    /// Event-tracking endpoint on its own host (`tracking.syai.com`), reusing the same
    /// AES-GCM session negotiated with `api.syai.com`.
    private static let eventTrackingURL = URL(
        string: "https://tracking.syai.com/ab-event/data/collect/security/eventTracking/batchStoreEventTracking"
    )!

    /// `POST tracking.syai.com/…/batchStoreEventTracking`. Two deviations: plaintext body is a
    /// top-level JSON array (not an object), and the response carries no application data, so it
    /// is deliberately not parsed (transport-200 is success).
    public func batchStoreEventTracking(_ events: [[String: Any]]) async throws {
        guard backend.isConfigured else { throw TransportError.notConfigured }
        try await ensureAccessToken() // gated call: needs a live Authorization token
        let bodyJSON = try JSONSerialization.data(withJSONObject: events)
        _ = try await envelopedPOST(
            url: Self.eventTrackingURL,
            bodyJSON: bodyJSON,
            extraHeaders: [:],
            includeProductModel: false,
            authed: true
        )
    }
}
