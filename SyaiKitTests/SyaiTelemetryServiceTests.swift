//
//  SyaiTelemetryServiceTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Offline tests for `SyaiTelemetryService` and the new `CGMManagerState`
/// telemetry fields. `SyaiEnvelopedClient` is an actor and can't be subclassed,
/// so the service's network steps are injected closures here; nothing in this
/// file touches the network.
final class SyaiTelemetryServiceTests: XCTestCase {
    /// Lock-protected mutable cell so @Sendable closures can share test state.
    private final class LockedBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ initial: T) { stored = initial }
        var value: T {
            get { lock.lock()
                defer { lock.unlock() }
                return stored }
            set { lock.lock()
                stored = newValue
                lock.unlock() }
        }
    }

    /// Records every body handed to the "send one batch" closure and returns a
    /// settable result — the network stand-in.
    private final class SendStub: @unchecked Sendable {
        private let lock = NSLock()
        private var _bodies: [[String: Any]] = []
        private var _result: Result<String, Error> = .success("OK")
        var bodies: [[String: Any]] { lock.lock()
            defer { lock.unlock() }
            return _bodies }

        var callCount: Int { bodies.count }
        func setResult(_ result: Result<String, Error>) { lock.lock()
            _result = result
            lock.unlock() }

        func send(_ body: [String: Any]) async throws -> String {
            let result = lock.withLock { () -> Result<String, Error> in
                _bodies.append(body)
                return _result
            }
            return try result.get()
        }
    }

    /// Records every mac handed to the "send one conn-state POST" closure and
    /// throws a settable error — the conn-state network stand-in.
    private final class ConnStateStub: @unchecked Sendable {
        private let lock = NSLock()
        private var _macs: [String] = []
        private var _error: Error?
        var macs: [String] { lock.lock()
            defer { lock.unlock() }
            return _macs }

        var callCount: Int { macs.count }
        func setError(_ error: Error?) { lock.lock()
            _error = error
            lock.unlock() }

        func send(_ mac: String) async throws {
            let error = lock.withLock { () -> Error? in
                _macs.append(mac)
                return _error
            }
            if let error { throw error }
        }
    }

    private struct StubTransportError: Error {}

    /// Records every event batch handed to the "send one event batch" closure
    /// and throws a settable error — the event-tracking network stand-in.
    /// The argument type pins the wire shape: a top-level JSON ARRAY of event
    /// dicts, exactly as captured.
    private final class EventStub: @unchecked Sendable {
        private let lock = NSLock()
        private var _batches: [[[String: Any]]] = []
        private var _error: Error?
        var batches: [[[String: Any]]] { lock.lock()
            defer { lock.unlock() }
            return _batches }

        var callCount: Int { batches.count }
        func setError(_ error: Error?) { lock.lock()
            _error = error
            lock.unlock() }

        func send(_ events: [[String: Any]]) async throws {
            let error = lock.withLock { () -> Error? in
                _batches.append(events)
                return _error
            }
            if let error { throw error }
        }
    }

    private static let defaultContext = SyaiTelemetryService.SensorContext(
        serverDeviceId: 11_994_938,
        embeddedSoftVersion: "E2.0.1(V1.7.SH22537.1)",
        activatedAtMs: 1_785_344_459_355,
        mac: "AABBCCDDEEFF"
    )

    private func rec(_ frontIdx: UInt16, receivedAtMs: Int64? = nil) -> SyaiUploadRecord {
        SyaiUploadRecord(
            runSec: UInt32(frontIdx) * 60,
            voltage: 31,
            receivedAtMs: receivedAtMs ?? (1_785_344_523_987 + Int64(frontIdx)),
            frontIdx: frontIdx,
            glucoseMmol: 9.2,
            current: 18612,
            temperatureC: 33.6,
            origin: Data([0, 0, 0, 0, 227, 127, 180, 242, 249, 0, 0, 113, 12])
        )
    }

    private func makeService(
        tier: LockedBox<SyaiTelemetryTier> = LockedBox(.full),
        context: LockedBox<SyaiTelemetryService.SensorContext?> = LockedBox(SyaiTelemetryServiceTests.defaultContext),
        account: LockedBox<SyaiTelemetryService.AccountContext?> = LockedBox(
            SyaiTelemetryService.AccountContext(userId: "10000001", appName: "Syai Tag")
        ),
        restoredQueue: [SyaiUploadRecord] = [],
        sends: SendStub = SendStub(),
        persisted: LockedBox<[SyaiUploadRecord]> = LockedBox([]),
        persistedIds: LockedBox<Int?> = LockedBox(nil),
        fetchId: (@Sendable(String) async throws -> Int?)? = nil,
        connSends: ConnStateStub = ConnStateStub(),
        eventSends: EventStub = EventStub(),
        onAccountLockoutChanged: (@Sendable(Bool) -> Void)? = nil
    ) -> SyaiTelemetryService {
        SyaiTelemetryService(
            // A template (logged-out) client — never called: the network steps
            // are injected below. Only its offline credential properties are read
            // by the session-rotation forwarder.
            client: SyaiEnvelopedClient(backend: .syaiTemplate),
            restoredQueue: restoredQueue,
            tier: { tier.value },
            persistQueue: { persisted.value = $0 },
            sensorContext: { context.value },
            accountContext: { account.value },
            onSessionRotated: { _, _ in },
            persistServerDeviceId: { persistedIds.value = $0 },
            onAccountLockoutChanged: onAccountLockoutChanged,
            sendBatch: { body in try await sends.send(body) },
            fetchServerDeviceId: fetchId ?? { _ in 11_994_938 },
            sendConnState: { mac in try await connSends.send(mac) },
            sendEvents: { events in try await eventSends.send(events) }
        )
    }

    /// Poll a condition until it holds or the timeout expires. The service's
    /// drain runs in its own Tasks, so tests can't await it directly.
    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    private func dataList(of body: [String: Any]) -> [[String: Any]] {
        (body["dataList"] as? [[String: Any]]) ?? []
    }

    private func frontIdx(of row: [String: Any]) -> Int? {
        (row["frontIdx"] as? NSNumber)?.intValue
    }

    /// A rawState with no tier key decodes as `.full`, matching the shipped
    /// default; the consent screen still runs before anything can be sent.
    func testRawStateMissingTelemetryTierKeyReadsFull() throws {
        let state = try XCTUnwrap(CGMManagerState(rawValue: [:]))
        XCTAssertEqual(state.telemetryTier, .full)
        XCTAssertFalse(state.telemetryDisclosureShown)
        XCTAssertTrue(state.telemetryQueue.isEmpty)
    }

    func testRawStateTelemetryTierRoundTrips() throws {
        var state = CGMManagerState()
        state.telemetryTier = .standard
        // Round-trip through a real plist so only plist-safe values survive.
        let data = try PropertyListSerialization.data(
            fromPropertyList: state.rawValue, format: .binary, options: 0
        )
        let raw = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let restored = try XCTUnwrap(CGMManagerState(rawValue: raw))
        XCTAssertEqual(restored.telemetryTier, .standard)
    }

    /// A pre-tier install that explicitly declined sharing must land on
    /// `.minimal`, not the `.full` default. Those users already have
    /// `telemetryDisclosureShown`, so the consent screen never reappears —
    /// falling through to the default would silently start uploading glucose
    /// they had said no to, with nothing to alert them.
    func testLegacyOptedOutRawStateDecodesAsMinimal() throws {
        let legacy: [String: Any] = ["telemetryEnabled": false, "telemetryDisclosureShown": true]
        let state = try XCTUnwrap(CGMManagerState(rawValue: legacy))
        XCTAssertEqual(state.telemetryTier, .minimal)
        XCTAssertFalse(state.telemetryTier.uploadsGlucose)
        XCTAssertFalse(state.telemetryTier.reportsSensorHealth)
    }

    /// The legacy ON case wrote no key at all, so it is indistinguishable from
    /// a fresh install and correctly reads as `.full` — the behaviour those
    /// users already had.
    func testLegacyOptedInRawStateDecodesAsFull() throws {
        let legacy: [String: Any] = ["telemetryDisclosureShown": true]
        let state = try XCTUnwrap(CGMManagerState(rawValue: legacy))
        XCTAssertEqual(state.telemetryTier, .full)
    }

    func testTierKeyWinsOverLegacyFlag() throws {
        let mixed: [String: Any] = ["telemetryTier": "full", "telemetryEnabled": false]
        let state = try XCTUnwrap(CGMManagerState(rawValue: mixed))
        XCTAssertEqual(state.telemetryTier, .full)
    }

    /// An unrecognized persisted tag must fail closed to the least-sharing
    /// tier; decoding it as the `.full` default would silently resume glucose
    /// upload from a state we cannot interpret.
    func testUnknownTierTagDecodesAsMinimal() throws {
        let raw: [String: Any] = ["telemetryTier": "bogus"]
        let state = try XCTUnwrap(CGMManagerState(rawValue: raw))
        XCTAssertEqual(state.telemetryTier, .minimal)
        XCTAssertFalse(state.telemetryTier.uploadsGlucose)
    }

    func testRawStateFullTierEncodesAsMissingKey() throws {
        // .full is the default, so it must NOT be written — the encode/decode
        // asymmetry is what keeps "missing ⇒ .full" consistent.
        let state = CGMManagerState()
        XCTAssertEqual(state.telemetryTier, .full)
        XCTAssertNil(state.rawValue["telemetryTier"])
    }

    func testRawStateDisclosureAndQueueSpillRoundTrip() throws {
        var state = CGMManagerState()
        state.telemetryDisclosureShown = true
        state.telemetryQueue = [rec(7), rec(8)]
        let data = try PropertyListSerialization.data(
            fromPropertyList: state.rawValue, format: .binary, options: 0
        )
        let raw = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let restored = try XCTUnwrap(CGMManagerState(rawValue: raw))
        XCTAssertTrue(restored.telemetryDisclosureShown)
        XCTAssertEqual(restored.telemetryQueue, [rec(7), rec(8)])
    }

    func testRawStateQueueSpillDropsMalformedEntries() throws {
        var state = CGMManagerState()
        state.telemetryQueue = [rec(7)]
        var raw = state.rawValue
        raw["telemetryQueue"] = [rec(7).plistRawValue, ["bogus": 1], ["runSec": "not-an-int"]]
        let restored = try XCTUnwrap(CGMManagerState(rawValue: raw))
        XCTAssertEqual(restored.telemetryQueue, [rec(7)])
    }

    func testEnqueueWhileDisabledIsNoOp() async {
        let sends = SendStub()
        let service = makeService(tier: LockedBox(.minimal), sends: sends)
        await service.enqueue(rec(1))
        let drained = await waitUntil(0.3) { sends.callCount > 0 }
        XCTAssertFalse(drained, "disabled service must never send")
        let v215 = await service.pendingCount
        XCTAssertEqual(v215, 0)
    }

    func testSetEnabledFalseDrainsAndDiscards() async {
        let sends = SendStub()
        sends.setResult(.failure(StubTransportError()))
        let persisted: LockedBox<[SyaiUploadRecord]> = LockedBox([])
        let service = makeService(sends: sends, persisted: persisted)
        await service.enqueue(rec(1))
        await service.enqueue(rec(2))
        await service.enqueue(rec(3))
        let v226 = await waitUntil { await service.pendingCount == 3 }
        XCTAssertTrue(v226)

        await service.applyTierChange(.minimal)

        let v230 = await service.pendingCount
        XCTAssertEqual(v230, 0)
        XCTAssertTrue(persisted.value.isEmpty, "the emptied queue must be persisted")
        let sendsBefore = sends.callCount
        let resent = await waitUntil(0.3) { sends.callCount > sendsBefore }
        XCTAssertFalse(resent, "no retry may fire after disable")
    }

    func testQueueBoundedAtCapDropsOldest() async {
        let sends = SendStub()
        sends.setResult(.failure(StubTransportError()))
        let service = makeService(sends: sends)
        for i: UInt16 in 0 ..< 365 { await service.enqueue(rec(i)) }
        let v244 = await waitUntil { await service.pendingCount == SyaiTelemetryService.queueCap }
        XCTAssertTrue(v244)
        let pending = await service.pendingRecords
        XCTAssertEqual(pending.count, 360)
        XCTAssertEqual(pending.first?.frontIdx, 5, "the 5 oldest records must be dropped")
        XCTAssertEqual(pending.last?.frontIdx, 364)
    }

    func testDedupCursorDropsReEnqueuedOlderRecords() async {
        let sends = SendStub()
        let service = makeService(sends: sends)
        await service.enqueue(rec(10))
        let v255 = await waitUntil { sends.callCount == 1 }
        XCTAssertTrue(v255)
        let v256 = await waitUntil { await service.pendingCount == 0 }
        XCTAssertTrue(v256)
        let v257 = await service.acceptedCursor
        XCTAssertEqual(v257, 10)

        // Reconnect-burst re-delivery of already-accepted records: dropped.
        await service.enqueue(rec(9))
        await service.enqueue(rec(10))
        let reSent = await waitUntil(0.3) { sends.callCount > 1 }
        XCTAssertFalse(reSent, "records at/below the cursor must not re-upload")
        let v264 = await service.pendingCount
        XCTAssertEqual(v264, 0)

        // A genuinely new record still uploads.
        await service.enqueue(rec(11))
        let v268 = await waitUntil { sends.callCount == 2 }
        XCTAssertTrue(v268)
        XCTAssertEqual(frontIdx(of: dataList(of: sends.bodies[1])[0]), 11)
    }

    /// Three queued records (frontIdx 7, 10, 12 — 10 % 5 == 0) must produce ONE
    /// POST with 4 dataList rows: the three dataType:1 rows plus the dataType:2
    /// checkpoint immediately after its row, all sharing the newest record's
    /// `timeAppReceive`.
    func testBacklogUploadsAsOneBatchedPost() async throws {
        let sends = SendStub()
        let restored = [
            rec(7, receivedAtMs: 1_785_344_520_000),
            rec(10, receivedAtMs: 1_785_344_523_000),
            rec(12, receivedAtMs: 1_785_344_525_000)
        ]
        let service = makeService(restoredQueue: restored, sends: sends)
        let v286 = await waitUntil { sends.callCount == 1 }
        XCTAssertTrue(v286)
        let v287 = await waitUntil { await service.pendingCount == 0 }
        XCTAssertTrue(v287)

        let body = try XCTUnwrap(sends.bodies.first)
        XCTAssertEqual((body["deviceId"] as? NSNumber)?.intValue, 11_994_938)
        XCTAssertEqual(body["embeddedSoftVersion"] as? String, "E2.0.1(V1.7.SH22537.1)")

        let rows = dataList(of: body)
        XCTAssertEqual(rows.count, 4, "3 records + 1 checkpoint duplicate")
        XCTAssertEqual(rows.map { frontIdx(of: $0) }, [7, 10, 10, 12])
        XCTAssertEqual((rows[0]["dataType"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((rows[1]["dataType"] as? NSNumber)?.intValue, 1)
        // The checkpoint: immediately after its own row, dataType 2, origin null.
        XCTAssertEqual((rows[2]["dataType"] as? NSNumber)?.intValue, 2)
        XCTAssertTrue(rows[2]["origin"] is NSNull)
        XCTAssertEqual((rows[3]["dataType"] as? NSNumber)?.intValue, 1)
        // One shared receipt instant = the newest record's.
        for row in rows {
            XCTAssertEqual((row["timeAppReceive"] as? NSNumber)?.int64Value, 1_785_344_525_000)
        }
    }

    /// Steady state: a single-record upload keeps the record's OWN receipt
    /// instant (no sharing rewrite for a 1-record batch).
    func testSingleRecordKeepsOwnReceiptInstant() async throws {
        let sends = SendStub()
        let service = makeService(sends: sends)
        await service.enqueue(rec(4, receivedAtMs: 1_785_344_523_987))
        let v314 = await waitUntil { sends.callCount == 1 }
        XCTAssertTrue(v314)
        let rows = dataList(of: try XCTUnwrap(sends.bodies.first))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual((rows[0]["timeAppReceive"] as? NSNumber)?.int64Value, 1_785_344_523_987)
    }

    func testBusinessCodeRejectionDropsBatchNoRetryStorm() async {
        let sends = SendStub()
        sends.setResult(.success("AppDevice_EndUsing"))
        // A restored backlog drains as ONE batch (deterministic — enqueue would
        // race the drain and could split the batch).
        let service = makeService(restoredQueue: [rec(1), rec(2)], sends: sends)
        let v328 = await waitUntil { await service.pendingCount == 0 }
        XCTAssertTrue(v328)
        XCTAssertEqual(sends.callCount, 1, "the rejected batch is dropped, not retried")
        let storm = await waitUntil(0.3) { sends.callCount > 1 }
        XCTAssertFalse(storm)
    }

    func testTransportFailureRetainsRecords() async {
        let sends = SendStub()
        sends.setResult(.failure(StubTransportError()))
        let persisted: LockedBox<[SyaiUploadRecord]> = LockedBox([])
        let service = makeService(sends: sends, persisted: persisted)
        await service.enqueue(rec(1))
        await service.enqueue(rec(2))
        let v341 = await waitUntil { sends.callCount >= 1 }
        XCTAssertTrue(v341)
        let v342 = await service.pendingCount
        XCTAssertEqual(v342, 2, "failed records stay queued")
        XCTAssertEqual(persisted.value, [rec(1), rec(2)], "the backlog spills to rawState")
    }

    /// Regression guard for the `onAccountLockoutChanged` plumbing: `forwardSessionRotation()`
    /// must call it after every drain, success or failure, exactly like it already does for
    /// `onSessionRotated`. (The actual lockout detection/cooldown lives in
    /// `SyaiEnvelopedClient` and is covered by `SyaiEnvelopedClientTests` — this only guards
    /// against the closure silently failing to get threaded through here.)
    func testDrainForwardsAccountLockoutStateAfterEveryAttempt() async {
        let sends = SendStub()
        sends.setResult(.failure(StubTransportError()))
        let reported: LockedBox<[Bool]> = LockedBox([])
        let service = makeService(sends: sends, onAccountLockoutChanged: { reported.value.append($0) })
        await service.enqueue(rec(1))
        let drained = await waitUntil { sends.callCount >= 1 }
        XCTAssertTrue(drained)
        let seen = await waitUntil { !reported.value.isEmpty }
        XCTAssertTrue(seen, "onAccountLockoutChanged must be invoked after a drain attempt")
    }

    /// A send that throws must not affect subsequent enqueues: the queued
    /// backlog plus the next record drain together once the network recovers.
    func testSendFailureDoesNotAffectSubsequentEnqueue() async throws {
        let sends = SendStub()
        sends.setResult(.failure(StubTransportError()))
        let service = makeService(sends: sends)
        await service.enqueue(rec(1))
        let v353 = await waitUntil { sends.callCount == 1 }
        XCTAssertTrue(v353)

        sends.setResult(.success("OK"))
        await service.enqueue(rec(2))
        let v357 = await waitUntil { await service.pendingCount == 0 }
        XCTAssertTrue(v357)

        let lastBody = try XCTUnwrap(sends.bodies.last)
        XCTAssertEqual(
            dataList(of: lastBody).map { frontIdx(of: $0) },
            [1, 2],
            "the retained backlog and the new record upload in one batch"
        )
        let v362 = await service.acceptedCursor
        XCTAssertEqual(v362, 2)
    }

    func testLazyServerDeviceIdFetchPersistsAndUploads() async throws {
        let sends = SendStub()
        let persistedIds: LockedBox<Int?> = LockedBox(nil)
        let base = SyaiTelemetryServiceTests.defaultContext
        let nilIdContext = SyaiTelemetryService.SensorContext(
            serverDeviceId: nil,
            embeddedSoftVersion: base.embeddedSoftVersion,
            activatedAtMs: base.activatedAtMs,
            mac: base.mac
        )
        let service = makeService(
            context: LockedBox(nilIdContext), sends: sends, persistedIds: persistedIds,
            fetchId: { _ in 555 }
        )
        await service.enqueue(rec(3))
        let v381 = await waitUntil { sends.callCount == 1 }
        XCTAssertTrue(v381)
        XCTAssertEqual(persistedIds.value, 555, "the fetched id must persist to the sensor record")
        let body = try XCTUnwrap(sends.bodies.first)
        XCTAssertEqual((body["deviceId"] as? NSNumber)?.intValue, 555)
    }

    func testAuthInfoWithoutIdKeepsRecordsQueued() async {
        let sends = SendStub()
        let nilIdContext = SyaiTelemetryService.SensorContext(
            serverDeviceId: nil,
            embeddedSoftVersion: SyaiTelemetryServiceTests.defaultContext.embeddedSoftVersion,
            activatedAtMs: SyaiTelemetryServiceTests.defaultContext.activatedAtMs,
            mac: SyaiTelemetryServiceTests.defaultContext.mac
        )
        let service = makeService(
            context: LockedBox(nilIdContext),
            sends: sends,
            fetchId: { _ in nil }
        )
        await service.enqueue(rec(3))
        let sent = await waitUntil(0.3) { sends.callCount > 0 }
        XCTAssertFalse(sent, "no id, no upload — and no fabricated id")
        let v400 = await service.pendingCount
        XCTAssertEqual(v400, 1)
    }

    func testMissingSensorContextKeepsRecordsQueued() async {
        let sends = SendStub()
        let service = makeService(
            context: LockedBox(nil), sends: sends
        )
        await service.enqueue(rec(1))
        let sent = await waitUntil(0.3) { sends.callCount > 0 }
        XCTAssertFalse(sent)
        let v412 = await service.pendingCount
        XCTAssertEqual(v412, 1)
    }

    func testReportConnStateDisabledNoOp() async {
        let connSends = ConnStateStub()
        let service = makeService(tier: LockedBox(.minimal), connSends: connSends)
        await service.reportConnState(connected: true)
        let sent = await waitUntil(0.3) { connSends.callCount > 0 }
        XCTAssertFalse(sent, "disabled service must never send conn-state")
    }

    /// No sensor context ⇒ no-op (the body is exactly {"mac": …}; no mac, no send).
    func testReportConnStateWithoutContextNoOp() async {
        let connSends = ConnStateStub()
        let service = makeService(context: LockedBox(nil), connSends: connSends)
        await service.reportConnState(connected: true)
        let sent = await waitUntil(0.3) { connSends.callCount > 0 }
        XCTAssertFalse(sent)
    }

    /// Enabled + context: exactly one send per call, carrying the context mac —
    /// event-driven (one per link transition), never batched or retried.
    func testReportConnStateSendsOncePerCall() async {
        let connSends = ConnStateStub()
        let service = makeService(connSends: connSends)
        await service.reportConnState(connected: true)
        await service.reportConnState(connected: true)
        let v442 = await waitUntil { connSends.callCount == 2 }
        XCTAssertTrue(v442)
        XCTAssertEqual(connSends.macs, ["AABBCCDDEEFF", "AABBCCDDEEFF"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(connSends.callCount, 2, "one send per call — no retries, no extra fires")
    }

    /// A failed send is log-only: swallowed, never retried, and the
    /// next transition still reports.
    func testReportConnStateFailureSwallowedNotRetried() async {
        let connSends = ConnStateStub()
        connSends.setError(StubTransportError())
        let service = makeService(connSends: connSends)
        await service.reportConnState(connected: true)
        let v455 = await waitUntil { connSends.callCount == 1 }
        XCTAssertTrue(v455)
        let retried = await waitUntil(0.3) { connSends.callCount > 1 }
        XCTAssertFalse(retried, "a failed conn-state report must not retry")

        connSends.setError(nil)
        await service.reportConnState(connected: true)
        let v461 = await waitUntil { connSends.callCount == 2 }
        XCTAssertTrue(v461)
    }

    /// A record matching the captured `cgm_state` exemplar: runSec 62,
    /// frontIdx 0, raw current 32739, temp 31.85, 17.3 mmol/L — so
    /// `monitorTime` = 1785344459355 + 62*1000 = 1785344521355 against the
    /// default context's `activatedAtMs`.
    private func exemplarRecord() -> SyaiUploadRecord {
        SyaiUploadRecord(
            runSec: 62, voltage: 31, receivedAtMs: 1_785_344_523_987, frontIdx: 0,
            glucoseMmol: 17.3, current: 32739, temperatureC: 31.85,
            origin: Data([0, 0, 0, 0, 227, 127, 180, 242, 249, 0, 0, 113, 12])
        )
    }

    /// The exact captured shape: every envelope constant and every eventInfo
    /// key/value pinned against the captured exemplar (userId/mac/deviceId
    /// are the fixture's synthetic placeholders, not the captured values).
    func testCgmStateEventExactShape() async throws {
        let eventSends = EventStub()
        let service = makeService(eventSends: eventSends)
        await service.enqueue(exemplarRecord())
        await service.flushEvents()
        let v486 = await waitUntil { eventSends.callCount == 1 }
        XCTAssertTrue(v486)

        // The wire body is a top-level JSON ARRAY of event dicts (captured).
        let batch = eventSends.batches[0]
        XCTAssertEqual(batch.count, 1)
        let event = batch[0]
        XCTAssertEqual(event["userId"] as? String, "10000001")
        XCTAssertEqual(event["appName"] as? String, "Syai Tag", "OEM identity — never Trio")
        XCTAssertEqual(event["eventType"] as? String, "flutter_cgm_event")
        XCTAssertEqual(event["eventName"] as? String, "cgm_state")
        XCTAssertEqual(event["eventPlatform"] as? String, "APP")
        let appCreateTime = (event["appCreateTime"] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(appCreateTime, 1_700_000_000_000, "epoch-ms, not seconds")

        let info = try XCTUnwrap(event["eventInfo"] as? [String: Any])
        XCTAssertEqual(info["userId"] as? String, "10000001")
        XCTAssertEqual(info["mac"] as? String, "AABBCCDDEEFF")
        XCTAssertEqual((info["time"] as? NSNumber)?.intValue, 62, "time = runSec")
        XCTAssertEqual((info["dataNo"] as? NSNumber)?.intValue, 0, "dataNo = frontIdx")
        XCTAssertEqual((info["voltage"] as? NSNumber)?.intValue, 31)
        XCTAssertEqual(
            (info["glucose"] as? NSNumber)?.intValue,
            32739,
            "glucose = the RAW current, NOT a glucose value"
        )
        XCTAssertEqual((info["temperature"] as? NSNumber)?.doubleValue ?? -1, 31.85, accuracy: 0.001)
        XCTAssertEqual((info["adjustGlucose"] as? NSNumber)?.doubleValue ?? -1, 17.3, accuracy: 0.001)
        XCTAssertEqual((info["orgGlucose"] as? NSNumber)?.doubleValue ?? -1, 17.3, accuracy: 0.001)
        XCTAssertTrue(info["adjustState"] is NSNull)
        XCTAssertEqual((info["monitorTime"] as? NSNumber)?.int64Value, 1_785_344_521_355)
        XCTAssertEqual((info["dataStatus"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(info["softVersion"] as? String, "E2.0.1(V1.7.SH22537.1)")
        XCTAssertEqual(info["dataTag"] as? String, "expression")
        XCTAssertEqual((info["deviceId"] as? NSNumber)?.intValue, 11_994_938)
        XCTAssertEqual(
            (info["eventDiffTime"] as? NSNumber)?.int64Value,
            0,
            "the first event at cold start diffs from 0 (plan §A.5, grade I)"
        )
    }

    /// Keys with no value are OMITTED, not nulled: `voltage` when the record
    /// carries none, `deviceId` while the numeric server id is unknown.
    func testCgmStateOmitsUnknownVoltageAndDeviceId() async throws {
        let eventSends = EventStub()
        let base = SyaiTelemetryServiceTests.defaultContext
        let nilIdContext = SyaiTelemetryService.SensorContext(
            serverDeviceId: nil, embeddedSoftVersion: base.embeddedSoftVersion,
            activatedAtMs: base.activatedAtMs, mac: base.mac
        )
        let service = makeService(
            context: LockedBox(nilIdContext),
            fetchId: { _ in nil },
            eventSends: eventSends
        )
        let noVoltage = SyaiUploadRecord(
            runSec: 62, voltage: nil, receivedAtMs: 1_785_344_523_987, frontIdx: 0,
            glucoseMmol: 17.3, current: 32739, temperatureC: 31.85,
            origin: Data([0, 0, 0, 0, 227, 127, 180, 242, 249, 0, 0, 113, 12])
        )
        await service.enqueue(noVoltage)
        await service.flushEvents()
        let v537 = await waitUntil { eventSends.callCount == 1 }
        XCTAssertTrue(v537)
        let info = try XCTUnwrap(eventSends.batches[0][0]["eventInfo"] as? [String: Any])
        XCTAssertNil(info["voltage"])
        XCTAssertNil(info["deviceId"])
    }

    /// `eventDiffTime`: 0 for the first event at cold start, then ms since the
    /// previously buffered event — small and non-decreasing for back-to-back
    /// enqueues.
    func testEventDiffTimeMonotonic() async throws {
        let eventSends = EventStub()
        let service = makeService(eventSends: eventSends)
        await service.enqueue(rec(1))
        await service.enqueue(rec(2))
        await service.flushEvents()
        let v552 = await waitUntil { eventSends.callCount == 1 }
        XCTAssertTrue(v552)
        let batch = eventSends.batches[0]
        XCTAssertEqual(batch.count, 2)
        let diffs = batch.map {
            (($0["eventInfo"] as? [String: Any])?["eventDiffTime"] as? NSNumber)?.int64Value
        }
        XCTAssertEqual(diffs[0], 0, "first event of a fresh service diffs from cold start")
        let second = try XCTUnwrap(diffs[1])
        XCTAssertGreaterThanOrEqual(second, 0)
        XCTAssertLessThan(second, 60000, "back-to-back events diff in ms, not minutes")
    }

    /// Buffering: nothing is sent below 10 events; the 10th event flushes the
    /// WHOLE buffer as one batch.
    func testAutoFlushAtThreshold() async {
        let eventSends = EventStub()
        let service = makeService(eventSends: eventSends)
        for i: UInt16 in 0 ..< 9 { await service.enqueue(rec(i)) }
        let early = await waitUntil(0.3) { eventSends.callCount > 0 }
        XCTAssertFalse(early, "no send below \(SyaiTelemetryService.eventBatchThreshold) events")
        let v572 = await service.pendingEventCount
        XCTAssertEqual(v572, 9)

        await service.enqueue(rec(9))
        let v575 = await waitUntil { eventSends.callCount == 1 }
        XCTAssertTrue(v575)
        XCTAssertEqual(eventSends.batches[0].count, 10, "the whole buffer goes as ONE batch")
        let v577 = await service.pendingEventCount
        XCTAssertEqual(v577, 0)
    }

    func testFlushEventsSendsPartialBuffer() async {
        let eventSends = EventStub()
        let service = makeService(eventSends: eventSends)
        await service.enqueue(rec(1))
        await service.enqueue(rec(2))
        await service.enqueue(rec(3))
        await service.flushEvents()
        let v588 = await waitUntil { eventSends.callCount == 1 }
        XCTAssertTrue(v588)
        XCTAssertEqual(eventSends.batches[0].count, 3)
        let v590 = await service.pendingEventCount
        XCTAssertEqual(v590, 0)
    }

    /// A failed batch is DROPPED: analytics, no retry, no persistence; the
    /// buffer is cleared on failure exactly as on success.
    func testEventBatchDroppedOnFailureNoRetry() async {
        let eventSends = EventStub()
        eventSends.setError(StubTransportError())
        let service = makeService(eventSends: eventSends)
        await service.enqueue(rec(1))
        await service.enqueue(rec(2))
        await service.flushEvents()
        let v602 = await waitUntil { eventSends.callCount == 1 }
        XCTAssertTrue(v602)
        let v603 = await service.pendingEventCount
        XCTAssertEqual(v603, 0, "a failed batch is dropped, not retained")
        let retried = await waitUntil(0.3) { eventSends.callCount > 1 }
        XCTAssertFalse(retried, "no retry for analytics")
    }

    /// Opt-out: disabled means `enqueue` buffers nothing and `flushEvents` is a
    /// no-op; disabling mid-stream clears the buffer (no stealth backlog, same
    /// contract as the upload queue).
    func testEventOptOutGatesBufferAndFlush() async {
        let eventSends = EventStub()
        let disabled = makeService(tier: LockedBox(.minimal), eventSends: eventSends)
        await disabled.enqueue(rec(1))
        let v615 = await disabled.pendingEventCount
        XCTAssertEqual(v615, 0, "disabled ⇒ don't even buffer")
        await disabled.flushEvents()
        let sent = await waitUntil(0.3) { eventSends.callCount > 0 }
        XCTAssertFalse(sent, "disabled ⇒ flush is a no-op")

        let service = makeService(eventSends: eventSends)
        await service.enqueue(rec(1))
        await service.enqueue(rec(2))
        let v623 = await service.pendingEventCount
        XCTAssertEqual(v623, 2)
        await service.applyTierChange(.minimal)
        let v625 = await service.pendingEventCount
        XCTAssertEqual(v625, 0, "stepping down clears the event buffer too")
    }

    /// No account context ⇒ no event (the captured envelope's `userId`/
    /// `appName` can't be built); the glucose upload path is unaffected.
    func testMissingAccountContextBuffersNoEvent() async {
        let eventSends = EventStub()
        let sends = SendStub()
        let service = makeService(account: LockedBox(nil), sends: sends, eventSends: eventSends)
        await service.enqueue(rec(1))
        let v635 = await waitUntil { sends.callCount == 1 }
        XCTAssertTrue(v635, "the upload still drains")
        let v636 = await service.pendingEventCount
        XCTAssertEqual(v636, 0)
    }

    /// `reportConnState(connected:)` mirrors the transition into the event
    /// channel: `cgm_connect`/`cgm_disconnect` with the STRING state, empty
    /// `steps`/`errorInfo`, and 0-placeholder durations.
    func testConnEventsMirrorTransition() async throws {
        let eventSends = EventStub()
        let service = makeService(eventSends: eventSends)
        await service.reportConnState(connected: true)
        await service.reportConnState(connected: false)
        await service.flushEvents()
        let v648 = await waitUntil { eventSends.callCount == 1 }
        XCTAssertTrue(v648)

        let batch = eventSends.batches[0]
        XCTAssertEqual(batch.count, 2)
        let connect = batch[0]
        let disconnect = batch[1]
        XCTAssertEqual(connect["eventType"] as? String, "flutter_cgm_event")
        XCTAssertEqual(connect["eventName"] as? String, "cgm_connect")
        XCTAssertEqual(disconnect["eventName"] as? String, "cgm_disconnect")

        let cInfo = try XCTUnwrap(connect["eventInfo"] as? [String: Any])
        XCTAssertEqual(cInfo["mac"] as? String, "AABBCCDDEEFF")
        XCTAssertEqual(cInfo["state"] as? String, "true", "state is a STRING, not a bool")
        XCTAssertEqual((cInfo["steps"] as? [Any])?.count, 0)
        XCTAssertEqual(cInfo["errorInfo"] as? String, "")
        for key in ["scanDuration", "connectDuration", "authDuration", "allDuration"] {
            XCTAssertEqual((cInfo[key] as? NSNumber)?.intValue, 0, "\(key) is a 0-placeholder")
        }
        let dInfo = try XCTUnwrap(disconnect["eventInfo"] as? [String: Any])
        XCTAssertEqual(dInfo["state"] as? String, "false")
        XCTAssertEqual(dInfo["mac"] as? String, "AABBCCDDEEFF")
    }

    /// The `cgm_notify_info` seam (uncalled in production — raw errorInfo
    /// bytes are not surfaced above BLE): the builder is pinned
    /// against the captured shape so wiring it later is call-site-only.
    /// Captured frame `077786010000` → header "30471", headerHex "7707",
    /// content "390".
    func testNotifyInfoEventShape() async throws {
        let eventSends = EventStub()
        let service = makeService(eventSends: eventSends)
        await service.reportNotifyInfo(orgHex: "077786010000", mac: "AABBCCDDEEFF")
        await service.flushEvents()
        let v681 = await waitUntil { eventSends.callCount == 1 }
        XCTAssertTrue(v681)

        let event = eventSends.batches[0][0]
        XCTAssertEqual(event["eventType"] as? String, "flutter_cgm_event")
        XCTAssertEqual(event["eventName"] as? String, "cgm_notify_info")
        let info = try XCTUnwrap(event["eventInfo"] as? [String: Any])
        XCTAssertEqual(info["header"] as? String, "30471")
        XCTAssertEqual(info["headerHex"] as? String, "7707")
        XCTAssertEqual(info["content"] as? String, "390")
        XCTAssertEqual(info["orgHex"] as? String, "077786010000")
        XCTAssertEqual(info["mac"] as? String, "AABBCCDDEEFF")
    }

    /// The happy path: the backlog goes up and the caller is told everything
    /// landed, so the unbind reports no discard.
    func testFlushBeforeTeardownUploadsTheBacklog() async {
        let sends = SendStub()
        let service = makeService(sends: sends)
        await service.enqueue(rec(1))
        await service.enqueue(rec(2))

        let synced = await service.flushBeforeTeardown()

        XCTAssertTrue(synced)
        XCTAssertGreaterThan(sends.callCount, 0)
    }

    /// Offline at teardown: the records stay queued and the caller learns they
    /// are being discarded, which is what selects the `_discard_sync` code.
    /// Must not spin — the loop stops as soon as a pass makes no progress.
    func testFlushBeforeTeardownReportsUnsyncedWhenSendFails() async {
        let sends = SendStub()
        sends.setResult(.failure(StubTransportError()))
        let service = makeService(sends: sends)
        await service.enqueue(rec(1))

        let synced = await service.flushBeforeTeardown()

        XCTAssertFalse(synced)
    }

    /// A user who opted out of data sharing has nothing outstanding: nothing was
    /// ever collected for upload, so ending the sensor is not a discard. This is
    /// the distinction the reason code turns on, so it is pinned deliberately
    /// rather than left to fall out of an empty queue.
    func testFlushBeforeTeardownTreatsOptedOutAsNothingOutstanding() async {
        let sends = SendStub()
        let service = makeService(tier: LockedBox(.minimal), sends: sends)
        await service.enqueue(rec(1)) // dropped: sharing is off

        let synced = await service.flushBeforeTeardown()

        XCTAssertTrue(synced)
        XCTAssertEqual(sends.callCount, 0, "nothing may be uploaded while sharing is off")
    }

    /// The one case where sharing being off still counts as a discard: a backlog
    /// restored from a run when sharing WAS on. Those are real readings that
    /// were meant to go up and now never will.
    func testFlushBeforeTeardownReportsUnsyncedForARestoredBacklogWhileDisabled() async {
        let sends = SendStub()
        let service = makeService(tier: LockedBox(.minimal), restoredQueue: [rec(1)], sends: sends)

        let synced = await service.flushBeforeTeardown()

        XCTAssertFalse(synced)
        XCTAssertEqual(sends.callCount, 0)
    }

    /// The load-bearing privacy invariant: at `standard` nothing carrying a
    /// glucose value may leave the phone. That covers the upload queue AND the
    /// `cgm_state` analytics event, which embeds adjustGlucose/orgGlucose and so
    /// belongs to the glucose tier despite riding the event channel.
    func testStandardTierEmitsNoGlucoseAnywhere() async {
        let sends = SendStub()
        let eventSends = EventStub()
        let service = makeService(tier: LockedBox(.standard), sends: sends, eventSends: eventSends)

        await service.enqueue(rec(1))
        await service.enqueue(rec(2))

        let queued = await service.pendingCount
        let buffered = await service.pendingEventCount
        XCTAssertEqual(queued, 0, "no glucose record may be queued below the full tier")
        XCTAssertEqual(buffered, 0, "cgm_state carries glucose and must not be buffered either")
        XCTAssertEqual(sends.callCount, 0)
    }

    /// Sensor health is exactly what `standard` adds, so the conn-state beacon
    /// and the device's own status frames must still flow there.
    func testStandardTierStillReportsSensorHealth() async {
        let connSends = ConnStateStub()
        let eventSends = EventStub()
        let service = makeService(tier: LockedBox(.standard), connSends: connSends, eventSends: eventSends)

        await service.reportConnState(connected: true)
        await service.reportNotifyInfo(orgHex: "077786010000", mac: "AABBCCDDEEFF")

        let ok = await waitUntil { connSends.macs.count == 1 }
        XCTAssertTrue(ok, "the conn-state beacon belongs to the standard tier")
        let buffered = await service.pendingEventCount
        XCTAssertGreaterThan(buffered, 0, "health events belong to the standard tier")
    }

    /// At `minimal` nothing at all goes out; only the lifecycle calls remain,
    /// and those never route through this service.
    func testMinimalTierEmitsNothing() async {
        let connSends = ConnStateStub()
        let eventSends = EventStub()
        let sends = SendStub()
        let service = makeService(
            tier: LockedBox(.minimal),
            sends: sends,
            connSends: connSends,
            eventSends: eventSends
        )

        await service.enqueue(rec(1))
        await service.reportConnState(connected: true)
        await service.reportNotifyInfo(orgHex: "077786010000", mac: "AABBCCDDEEFF")
        await service.flushEvents()

        let queued = await service.pendingCount
        let buffered = await service.pendingEventCount
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(buffered, 0)
        XCTAssertEqual(sends.callCount, 0)
        XCTAssertEqual(connSends.macs.count, 0)
        XCTAssertEqual(eventSends.batches.count, 0)
    }

    /// Stepping down must not leave a backlog that uploads later — the
    /// no-stealth-backlog rule, now keyed on the tier rather than a flag.
    func testSteppingDownFromFullDiscardsTheGlucoseBacklog() async {
        let sends = SendStub()
        sends.setResult(.failure(StubTransportError())) // keep the queue put
        let service = makeService(sends: sends)
        await service.enqueue(rec(1))
        await service.enqueue(rec(2))
        let before = await service.pendingCount
        XCTAssertGreaterThan(before, 0)

        await service.applyTierChange(.standard)

        let after = await service.pendingCount
        XCTAssertEqual(after, 0, "a step down may never leave glucose queued")
    }
}
