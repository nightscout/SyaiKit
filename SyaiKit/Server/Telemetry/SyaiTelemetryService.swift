//
//  SyaiTelemetryService.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// OEM telemetry coordinator. Owns the account-backed `SyaiEnvelopedClient`, the glucose-upload
/// offline queue, and the event buffer. `actor` so the queue, dedup cursor, and event buffer are
/// serialized across concurrent `ingest` enqueues and reconnect bursts.
///
/// Work is split by file: uploader (`+Upload.swift`), conn-state beacon (`+ConnState.swift`), and
/// event tracker (`+Events.swift`). Stored state lives here because extensions can't add stored
/// properties. Network work runs inside the actor's own Tasks so upload failures never delay dosing.
public actor SyaiTelemetryService {
    /// Active-sensor fields for the upload body: `serverDeviceId` from `device/authInfo`,
    /// `embeddedSoftVersion` firmware string, `activatedAtMs` time anchor, `mac` dedup identity.
    public struct SensorContext: Sendable, Equatable {
        public let serverDeviceId: Int?
        public let embeddedSoftVersion: String
        public let activatedAtMs: Int64
        public let mac: String

        public init(
            serverDeviceId: Int?,
            embeddedSoftVersion: String,
            activatedAtMs: Int64,
            mac: String
        ) {
            self.serverDeviceId = serverDeviceId
            self.embeddedSoftVersion = embeddedSoftVersion
            self.activatedAtMs = activatedAtMs
            self.mac = mac
        }
    }

    /// Account fields for the event-tracking envelope: `userId` and the OEM `appName`
    /// (from the JWT/backend, e.g. "Syai Tag"), never the host app's name.
    public struct AccountContext: Sendable, Equatable {
        public let userId: String
        public let appName: String

        public init(userId: String, appName: String) {
            self.userId = userId
            self.appName = appName
        }
    }

    nonisolated let logger = SyaiLogger(category: "Telemetry")

    private let client: SyaiEnvelopedClient
    let tier: @Sendable() -> SyaiTelemetryTier
    let persistQueue: @Sendable([SyaiUploadRecord]) -> Void
    let sensorContext: @Sendable() -> SensorContext?
    let accountContext: @Sendable() -> AccountContext?
    private let onSessionRotated: @Sendable(SyaiCredentials, String?) -> Void
    private let onAccountLockoutChanged: (@Sendable(Bool) -> Void)?
    let persistServerDeviceId: @Sendable(Int) -> Void

    /// Injectable "send one batched POST" step. Default rides `client.uploadGlucose` with one
    /// 401 refresh-and-retry; further retries are left to the queue backoff.
    let sendBatch: @Sendable([String: Any]) async throws -> String
    /// Injectable lazy `device/authInfo` fetch. Returns the numeric server device id or nil;
    /// never fabricates one.
    let fetchServerDeviceId: @Sendable(String) async throws -> Int?
    /// Injectable "send one conn-state POST" step. Default rides `client.updateDeviceConnState`;
    /// conn-state is fire-and-forget, unlike the queued uploader.
    let sendConnState: @Sendable(String) async throws -> Void
    /// Injectable "send one event batch" step. Argument is a top-level JSON array of event dicts.
    /// Default rides `client.batchStoreEventTracking`; failures are dropped (analytics only).
    let sendEvents: @Sendable([[String: Any]]) async throws -> Void

    public init(
        client: SyaiEnvelopedClient,
        restoredQueue: [SyaiUploadRecord] = [],
        tier: @escaping @Sendable() -> SyaiTelemetryTier,
        persistQueue: @escaping @Sendable([SyaiUploadRecord]) -> Void,
        sensorContext: @escaping @Sendable() -> SensorContext?,
        accountContext: @escaping @Sendable() -> AccountContext?,
        onSessionRotated: @escaping @Sendable(SyaiCredentials, String?) -> Void,
        persistServerDeviceId: @escaping @Sendable(Int) -> Void,
        onAccountLockoutChanged: (@Sendable(Bool) -> Void)? = nil,
        sendBatch: (@Sendable([String: Any]) async throws -> String)? = nil,
        fetchServerDeviceId: (@Sendable(String) async throws -> Int?)? = nil,
        sendConnState: (@Sendable(String) async throws -> Void)? = nil,
        sendEvents: (@Sendable([[String: Any]]) async throws -> Void)? = nil
    ) {
        self.client = client
        self.tier = tier
        self.persistQueue = persistQueue
        self.sensorContext = sensorContext
        self.accountContext = accountContext
        self.onSessionRotated = onSessionRotated
        self.onAccountLockoutChanged = onAccountLockoutChanged
        self.persistServerDeviceId = persistServerDeviceId
        self.sendBatch = sendBatch ?? { [client] body in
            do {
                return try await client.uploadGlucose(body)
            } catch let SyaiEnvelopedClient.TransportError.http(status, _) where status == 401 {
                try await client.ensureAccessToken()
                return try await client.uploadGlucose(body)
            }
        }
        self.fetchServerDeviceId = fetchServerDeviceId ?? { [client] mac in
            try await client.authInfo(mac: mac).serverDeviceId
        }
        self.sendConnState = sendConnState ?? { [client] mac in
            try await client.updateDeviceConnState(mac: mac)
        }
        self.sendEvents = sendEvents ?? { [client] events in
            try await client.batchStoreEventTracking(events)
        }
        // Clamp a restored spill to the cap (drop oldest) and resume draining it.
        self.queue = Array(restoredQueue.suffix(Self.queueCap))
        if !queue.isEmpty, tier().uploadsGlucose {
            // Actor init is nonisolated, so hop onto the actor to call isolated `kickDrain()`.
            Task { [weak self] in await self?.kickDrain() }
        }
    }

    var queue: [SyaiUploadRecord] = []
    /// Highest `frontIdx` accepted for the current sensor run; reconnect bursts don't double-upload.
    /// Resets on sensor swap and is not restored across launches (benign re-upload; server may dedupe).
    var lastAcceptedFrontIdx: UInt16?
    /// Sensor run the cursor belongs to; reset on sensor swap.
    var cursorMac: String?
    var consecutiveFailures = 0
    var drainTask: Task<Void, Never>?
    var retryTask: Task<Void, Never>?
    /// Set when an enqueue lands while a drain is in flight, so the finished drain re-kicks immediately.
    var drainAgain = false

    /// In-memory event buffer, not persisted (analytics only; a killed process loses at most 9 events).
    var eventBuffer: [[String: Any]] = []
    /// Anchor for `eventDiffTime`: ms elapsed since the previously buffered event.
    var eventDiffAnchorMs: Int64?

    /// React to a tier change. Anything the new tier no longer permits is discarded immediately,
    /// so stepping down can never leave a later-uploading backlog; stepping up resumes draining.
    public func applyTierChange(_ newTier: SyaiTelemetryTier) {
        if !newTier.uploadsGlucose, !queue.isEmpty {
            logger.debug("tier now \(newTier.persistedTag); discarding \(queue.count) queued record(s)")
            retryTask?.cancel()
            retryTask = nil
            queue.removeAll()
            consecutiveFailures = 0
            persistQueue(queue)
        }
        // Events span both tiers (`cgm_state` carries glucose, the rest do not), so any step down
        // drops the whole buffer rather than sorting best-effort analytics.
        if newTier != .full, !eventBuffer.isEmpty {
            eventBuffer.removeAll()
        }
        if newTier.uploadsGlucose { kickDrain() }
    }

    /// Sensor swap/discard: pending records carry the old sensor's origin and would upload under
    /// the new sensor's `deviceId`, so drop them and reset the dedup cursor.
    public func clearQueue() {
        retryTask?.cancel()
        retryTask = nil
        if !queue.isEmpty {
            logger.debug("sensor discarded; dropping \(queue.count) queued record(s) for the old sensor")
            queue.removeAll()
        }
        eventBuffer.removeAll()
        eventDiffAnchorMs = nil
        lastAcceptedFrontIdx = nil
        cursorMac = nil
        persistQueue(queue)
    }

    /// Re-persist any token rotation and account-lockout state after every network
    /// interaction, success or failure.
    func forwardSessionRotation() async {
        await SyaiSessionRetrying.forwardRotation(
            client, onSessionRotated: onSessionRotated, onAccountLockoutChanged: onAccountLockoutChanged
        )
    }
}
