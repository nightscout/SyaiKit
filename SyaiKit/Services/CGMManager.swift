//
//  CGMManager.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation
import HealthKit
@preconcurrency import LoopKit
import os.log
import UIKit

public final class SyaiCGMManager: CGMManager, @unchecked Sendable {
    public static let pluginIdentifier = "SyaiCGMManager"
    public static let localizedTitle = "Syai Ultra"
    public static let healthKitStorageDelay: TimeInterval = 0

    public var localizedTitle: String { Self.localizedTitle }
    public var pluginIdentifier: String { Self.pluginIdentifier }
    public func markAsDepedency(_: Bool) {}

    public weak var cgmManagerDelegate: CGMManagerDelegate?
    public var delegateQueue: DispatchQueue!

    public internal(set) var state: CGMManagerState
    public var rawState: SyaiCGMManager.RawStateValue { state.rawValue }

    var monitor: SyaiSensorMonitor? {
        didSet { notifyStateObservers() }
    }

    /// A link to the sensor is up. On device that means a live monitor; the
    /// simulator build also counts its stand-in link.
    var hasLiveLink: Bool {
        #if targetEnvironment(simulator)
            return monitor != nil || simulatedLinkUp
        #else
            return monitor != nil
        #endif
    }

    #if targetEnvironment(simulator)
        var simulatedLinkUp = false { didSet { notifyStateObservers() } }
        var simulatedAccount = false
        var simulatedBound: SyaiBoundSensor?
        var simulationTimer: Timer?
    #endif

    internal let logger = SyaiLogger(category: "CgmManager")

    var sensorKit: SyaiBLE?
    var calibrationProvider: CalibrationProvider?
    var telemetryService: SyaiTelemetryService?

    public internal(set) var account: SyaiAccountSession? {
        didSet { notifyStateObservers() }
    }

    let sessionRecovery = SyaiSessionRecovery()

    public internal(set) var connectedAt: Date? { didSet { notifyStateObservers() } }
    var reconnectAttempt: Task<Void, Never>?
    private(set) var isDeleted = false

    var firingAlertConditions: Set<SyaiAlertCondition> = []

    var pendingBackfillFrom: UInt16?
    var pendingBackfillSamples: [NewGlucoseSample] = []

    /// Client-side data-plausibility engine. Lives manager-side so streaks survive
    /// BLE reconnects; only the latched `broken` verdict is persisted.
    var plausibilityGuard = SyaiPlausibilityGuard()

    public var latestSample: GlucoseSample? { state.latestSample }
    public private(set) var recentSamples: [GlucoseSample] {
        get {
            recentSamplesLock.lock()
            defer { recentSamplesLock.unlock() }
            return _recentSamples
        }
        set {
            recentSamplesLock.lock()
            _recentSamples = newValue
            recentSamplesLock.unlock()
        }
    }

    private var _recentSamples: [GlucoseSample] = []
    private let recentSamplesLock = NSLock()
    private static let recentSamplesCap = 100

    let stateObservers = SyaiWeakObserverSet<SyaiStateObserver>()

    public internal(set) var statusDetail: String? { didSet { notifyStateObservers() } }
    public func updateStatusDetail(_ text: String?) {
        if Thread.isMainThread { statusDetail = text }
        else { DispatchQueue.main.async { [weak self] in self?.statusDetail = text } }
    }

    var isReconnecting: Bool = false { didSet { notifyStateObservers() } }

    /// A connection attempt failed for a sensor the host app has never connected to.
    /// In-memory only: the first successful connection clears it.
    var firstConnectionFailed = false { didSet { notifyStateObservers() } }

    public enum ConnectionStatus: Equatable {
        case notPaired
        case connecting
        case connected
        case reconnecting
        case disconnected
    }

    public var connectionStatus: ConnectionStatus {
        guard state.mac != nil else { return .notPaired }
        if hasLiveLink { return .connected }
        return isReconnecting ? .reconnecting : .disconnected
    }

    /// Seconds since activation, from the sensor's own clock. The UI reads this
    /// rather than doing its own `Date()` arithmetic against `activatedAt`.
    public var sensorAge: TimeInterval? {
        SyaiSensorLifecycle.age(activatedAt: state.activatedAt, sensorAge: sensorAgeReading)
    }

    public var sensorExpirationDate: Date? {
        guard let activatedAt = state.activatedAt, let activeDuration = state.activeDuration else {
            return nil
        }
        return activatedAt.addingTimeInterval(activeDuration)
    }

    public var sensorWarmupEndDate: Date? {
        guard let activatedAt = state.activatedAt, let preheatDuration = state.preheatDuration else {
            return nil
        }
        return activatedAt.addingTimeInterval(preheatDuration)
    }

    private var sensorAgeReading: (elapsed: TimeInterval, at: Date)? {
        state.latestElapsedSeconds.flatMap { elapsed in
            state.latestElapsedReceivedAt.map { (elapsed, $0) }
        }
    }

    public var sensorLifecycle: SyaiSensorLifecycle {
        SyaiSensorLifecycle.compute(
            sensorPaired: state.mac != nil,
            activatedAt: state.activatedAt,
            sensorAge: sensorAgeReading,
            latestReadingAt: state.latestReadingTimestamp,
            hasLiveMonitor: hasLiveLink,
            reportedFault: state.sensorFault,
            activeDuration: state.activeDuration,
            preheatDuration: state.preheatDuration
        )
    }

    public let isOnboarded = true
    public var appURL: URL? { nil }
    public var providesBLEHeartbeat: Bool { true }
    public var shouldSyncToRemoteService: Bool { true }
    public var managedDataInterval: TimeInterval? { nil }

    public var glucoseDisplay: GlucoseDisplayable? {
        guard let sample = state.latestSample else { return nil }
        guard abs(Date().timeIntervalSince(sample.date)) <= SyaiSensorLifecycle.signalLostThreshold else { return nil }
        return SyaiGlucoseDisplay(sample: sample)
    }

    public var inSignalLoss: Bool {
        guard state.mac != nil else { return false }
        return !hasLiveLink
    }

    public var isInoperable: Bool { state.sensorNeedsReplacement }

    public var cgmManagerStatus: CGMManagerStatus {
        CGMManagerStatus(
            hasValidSensorSession: state.mac != nil && !state.sensorNeedsReplacement,
            lastCommunicationDate: state.latestReadingTimestamp,
            device: device
        )
    }

    public var device: HKDevice? {
        HKDevice(
            name: "Syai CGM",
            manufacturer: "Syai",
            model: "X1",
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: nil,
            localIdentifier: state.mac,
            udiDeviceIdentifier: nil
        )
    }

    public var debugDescription: String {
        """
        ## SyaiCGMManager
        * mac: \(SyaiRedact.mac(state.mac))
        * activatedAt: \(String(describing: state.activatedAt))
        * latestReadingTimestamp: \(String(describing: state.latestReadingTimestamp))
        """
    }

    public convenience init() {
        self.init(initialState: CGMManagerState())
    }

    public required convenience init?(rawState: SyaiCGMManager.RawStateValue) {
        self.init(initialState: CGMManagerState(rawValue: rawState) ?? CGMManagerState())

        if let pending = state.sensors.pendingBind {
            logger
                .warning(
                    "pending bind for \(SyaiRedact.mac(pending.mac)): the sensor was activated but its bind didn't complete. Re-run pairing for it to resume at the bind."
                )
        }
    }

    /// The stack (and with it the telemetry service, which snapshots the
    /// persisted upload queue) is wired exactly once, from the final state.
    /// Wiring from a blank state first would restore an empty queue.
    private init(initialState: CGMManagerState) {
        state = initialState
        recentSamples = initialState.recentSamples
        account = SyaiKeychain.loadAccount()
        syncSensorHistoryFile()
        if state.mac != nil {
            wireStackForRestoreIfNeeded()
            Task { @MainActor in self.scheduleReconnect() }
        }
    }

    @MainActor func recordSample(_ sample: GlucoseSample) {
        recentSamplesLock.lock()
        // Newest-first by the reading's own timestamp, not by arrival: a
        // backfilled record is always ingested after the newer live sample that
        // triggered the request, so inserting by arrival would list it above
        // that sample and push a stale reading into the "latest" prefix.
        let insertionIndex = _recentSamples.firstIndex { $0.date <= sample.date } ?? _recentSamples.count
        _recentSamples.insert(sample, at: insertionIndex)
        if _recentSamples.count > Self.recentSamplesCap {
            _recentSamples.removeLast(_recentSamples.count - Self.recentSamplesCap)
        }
        let persistedPrefix = Array(_recentSamples.prefix(CGMManagerState.recentSamplesPersistenceCap))
        recentSamplesLock.unlock()
        var updated = state
        updated.recentSamples = persistedPrefix
        setState(updated)
    }

    @MainActor func recordForwardingOutcome(forSequence sequence: UInt16, wasForwarded: Bool, skipReason: String?) {
        recentSamplesLock.lock()
        guard let idx = _recentSamples.firstIndex(where: { $0.sequence == sequence }) else {
            recentSamplesLock.unlock()
            return
        }
        let updated = _recentSamples[idx].withForwardingOutcome(wasForwarded: wasForwarded, skipReason: skipReason)
        _recentSamples[idx] = updated
        let persistedPrefix = Array(_recentSamples.prefix(CGMManagerState.recentSamplesPersistenceCap))
        recentSamplesLock.unlock()
        var s = state
        s.recentSamples = persistedPrefix
        setState(s)
    }

    @MainActor public func applyCalibration(_ calibration: Calibration) {
        var updated = state
        updated.sensors.updateActiveCalibration(calibration)
        setState(updated)
    }

    @MainActor public func discardSensor() {
        cancelReconnect()
        logger.info("discard sensor: releasing BLE link (mac=\(SyaiRedact.mac(state.mac)))")

        monitor?.disconnect()
        monitor = nil
        #if targetEnvironment(simulator)
            stopSimulation()
        #endif
        isReconnecting = false
        recentSamples = []
        plausibilityGuard = SyaiPlausibilityGuard()
        pendingBackfillFrom = nil
        pendingBackfillSamples = []
        if let mac = state.mac {
            let event = PersistedCgmEvent(date: Date(), type: .sensorEnd, deviceIdentifier: mac)
            delegateQueue?.async { [weak self] in
                guard let self else { return }
                self.cgmManagerDelegate?.cgmManager(self, hasNew: [event])
            }
        }

        clearState()

        if let service = telemetryService {
            Task { await service.clearQueue() }
        }
    }

    @MainActor private func clearState() {
        var blank = state
        blank.sensors.discardActive()
        blank.resetSensorSession()
        setState(blank)
    }

    public func delete(completion: @escaping () -> Void) {
        isDeleted = true
        Task { @MainActor in self.cancelReconnect() }
        logger.info("cgm delete: releasing BLE link")
        monitor?.disconnect()
        monitor = nil
        #if targetEnvironment(simulator)
            Task { @MainActor in self.stopSimulation() }
        #endif

        guard delegateQueue != nil else {
            completion()
            return
        }
        notifyDelegateOfDeletion(completion: completion)
    }

    public func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            if !self.hasLiveLink, self.state.mac != nil {
                self.scheduleReconnect()
            }

            self.evaluateAlerts()
        }
        completion(.noData)
    }

    public func acknowledgeAlert(alertIdentifier _: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    public func getSoundBaseURL() -> URL? { nil }
    public func getSounds() -> [Alert.Sound] { [] }

    private let statusObservers = WeakSynchronizedSet<CGMManagerStatusObserver>()
    public func addStatusObserver(_ observer: CGMManagerStatusObserver, queue: DispatchQueue) {
        statusObservers.insert(observer, queue: queue)
    }

    public func removeStatusObserver(_ observer: CGMManagerStatusObserver) {
        statusObservers.removeElement(observer)
    }

    private func notifyStatusObservers() {
        let status = cgmManagerStatus
        statusObservers.forEach { $0.cgmManager(self, didUpdate: status) }
    }

    private func syncSensorHistoryFile() {
        state.sensors.mergeHistory(SyaiSensorHistoryStore.load())
        SyaiSensorHistoryStore.save(state.sensors.records)
    }

    @MainActor func setState(_ newState: CGMManagerState) {
        if newState.sensors.records != state.sensors.records {
            SyaiSensorHistoryStore.save(newState.sensors.records)
        }
        state = newState
        delegateQueue?.async { [weak self] in
            guard let self else { return }
            self.cgmManagerDelegate?.cgmManagerDidUpdateState(self)
        }
        notifyStateObservers()
    }
}

struct SyaiGlucoseDisplay: GlucoseDisplayable {
    let sample: GlucoseSample
    var isStateValid: Bool { !sample.hasBlockingIssue }
    var isLocal: Bool { true }
    var glucoseRangeCategory: GlucoseRangeCategory? { nil }
    var trendType: GlucoseTrend? { Self.mapTrend(sample.trend) }

    static func mapTrend(_ trend: GlucoseSample.Trend) -> GlucoseTrend? {
        switch trend {
        case .notDetermined: return nil
        case .fallingQuickly: return .downDown
        case .falling: return .down
        case .stable: return .flat
        case .rising: return .up
        case .risingQuickly: return .upUp
        }
    }

    var trendRate: HKQuantity? {
        sample.rateOfChangeMgDLPerMinute.map {
            HKQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0)
        }
    }
}
