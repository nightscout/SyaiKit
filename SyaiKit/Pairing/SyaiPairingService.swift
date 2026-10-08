//
//  SyaiPairingService.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import CoreBluetooth
import Foundation

public final class SyaiPairingService {
    public enum Stage: Sendable, Equatable {
        case discoveringSensor
        case sensorFound(mac: String)
        case bleSearching
        case bleConnecting
        case handshaking
        case resolvingCalibration
        case binding
        case activating
    }

    public enum Failure: Error, CustomStringConvertible {
        case noKeyGroup
        case bleNoSensorDiscovered
        /// The sensor may be in a firmware-idle power state (no interaction for ~2h
        /// drops the BLE radio). The real kit should throw this once it can
        /// tell "no advertisement seen, possibly dormant" apart from a generic scan
        /// timeout.
        case sensorDormantNeedsNFC
        /// The BLE link dropped after a successful connect (mid-auth or mid-GATT),
        /// as opposed to never finding/connecting the sensor at all. A much stronger
        /// "it's right here" signal than a scan/connect miss, so callers (e.g.
        /// `scheduleReconnect`) retry this near-continuously instead of backing off.
        case droppedAfterConnect(String)
        /// The sensor's firmware produces readings SyaiKit can't decode. Raised
        /// before any activation write, so the sensor is left untouched.
        case unsupportedFirmware(String)
        /// The sensor is activated but its own coefficients/keys couldn't be
        /// fetched yet. Pairing resumes from the bind on the next attempt.
        case awaitingSensorRecord(String)
        /// The post-bind coefficients disagree with the ones the server gave
        /// before activation. Refused rather than guessing which set is real.
        case calibrationMismatch
        case underlying(String)

        public var description: String {
            switch self {
            case .noKeyGroup:
                return "Missing the sensor key group. Please try again."
            case .bleNoSensorDiscovered:
                return "Couldn't find the sensor over Bluetooth. Make sure it's active and nearby."
            case .sensorDormantNeedsNFC:
                return "Sensor is out of range or not advertising. Keep it nearby; \(Bundle.main.syaiHostAppName) will keep trying."
            case .droppedAfterConnect:
                return "Lost the connection, reconnecting…"
            case let .unsupportedFirmware(version):
                return "This sensor's firmware (\(version)) isn't supported yet. It hasn't been activated, so it can still be used with the official Syai app."
            case let .awaitingSensorRecord(detail):
                return "The sensor is activated, but Syai hasn't provided its calibration yet (\(detail)). Try again; pairing will pick up where it left off."
            case .calibrationMismatch:
                return "Syai returned two different calibrations for this sensor, so \(Bundle.main.syaiHostAppName) won't use it. Please report this with your logs."
            case let .underlying(m):
                return m
            }
        }
    }

    public struct AttachOutcome: Sendable {
        public let mac: String
        public let peripheralID: UUID
        public let monitor: SyaiSensorMonitor
        public let deviceInfo: DeviceInfo
        public let keyGroup: SyaiKeyGroup
        public let activatedAt: Date?
        public let methodBlob: String?
    }

    private let logger = SyaiLogger(category: "PairingService")

    private let sensorKit: SyaiBLE
    private let calibrationProvider: CalibrationProvider

    /// Account-backed binder and bound-sensor lookup. Required on the
    /// `activate` path (the bind is what hands out the sensor's keys), unused
    /// by `reconnect`.
    private let binder: SyaiServerDeviceBinder?
    private let boundSensorLookup: SyaiBoundSensorLookup?

    public init(
        sensorKit: SyaiBLE,
        calibrationProvider: CalibrationProvider,
        binder: SyaiServerDeviceBinder? = nil,
        boundSensorLookup: SyaiBoundSensorLookup? = nil
    ) {
        self.sensorKit = sensorKit
        self.calibrationProvider = calibrationProvider
        self.binder = binder
        self.boundSensorLookup = boundSensorLookup
    }

    /// Reconnect an already-persisted sensor: no server round-trip, the mac +
    /// keyGroup + device record all come from the persisted `SyaiSensorRecord`.
    public func reconnect(
        mac: String,
        keyGroup: SyaiKeyGroup,
        deviceInfo: DeviceInfo,
        expectedPeripheralID: UUID?,
        onStage: @Sendable @escaping (Stage) -> Void = { _ in }
    ) async throws -> AttachOutcome {
        let identity = SyaiSensorIdentity(mac: mac)
        let session = try await connect(
            identity: identity, keyGroup: keyGroup, expectedPeripheralID: expectedPeripheralID, onStage: onStage
        )
        return makeOutcome(mac: identity.mac, session: session, deviceInfo: deviceInfo, activatedAt: nil)
    }

    /// Activation (primary pairing path), following the official app:
    ///
    /// 1. `validateDeviceByMacV3` confirms the sensor may be started.
    /// 2. Over BLE, the server answers the sensor's auth challenge and supplies
    ///    the encrypted activation frames (`SyaiBLE.activateRemotely`).
    /// 3. `bindV3` registers the sensor; its response carries the sensor's own
    ///    coefficients and key group, with `getBindDevice`/`authInfo` as the
    ///    fallback source.
    /// 4. A fresh, locally authenticated connection starts streaming.
    ///
    /// The phone holds no key group until step 3, so a sensor activated but
    /// not yet bound can't be read at all. `onActivated` fires the moment the
    /// activate command lands so the manager can persist a pending-bind marker;
    /// `pendingBind` hands it back on the next attempt, which then skips
    /// straight to step 3 instead of trying to activate the sensor again.
    public func activate(
        preselectedIdentity: SyaiSensorIdentity? = nil,
        pendingBind: (@Sendable(String) -> SyaiPendingBind?)? = nil,
        onActivated: (@Sendable(SyaiPendingBind) -> Void)? = nil,
        onStage: @Sendable @escaping (Stage) -> Void = { _ in }
    ) async throws -> AttachOutcome {
        logger.info("pairing start app=\(SyaiDiagnostics.appVersionStamp) verbose=\(SyaiDiagnostics.verboseBLELogging)")
        var pairMAC: String?
        var pairSucceeded = false
        defer {
            if pairSucceeded {
                logger.info("pairing end result=success mac=\(SyaiRedact.mac(pairMAC))")
            } else {
                logger.error("pairing end result=failed mac=\(SyaiRedact.mac(pairMAC))")
            }
        }

        guard let binder else { throw Failure.underlying("Log in to Syai first.") }

        // A picker-selected identity skips BLE discovery.
        let identity = try await resolveIdentity(knownIdentity: preselectedIdentity, onStage: onStage)
        pairMAC = identity.mac

        let pending: SyaiPendingBind
        var expectedCoefficients: [Double]?
        var activationPeripheralID: UUID?
        if let resumed = pendingBind?(identity.mac) {
            logger.info("resuming pairing for \(SyaiRedact.mac(identity.mac)): sensor already activated, going straight to the bind")
            pending = resumed
        } else {
            onStage(.resolvingCalibration)
            let validation: SyaiSensorValidation
            do {
                validation = try await calibrationProvider.validate(mac: identity.mac)
            } catch {
                throw Failure.underlying("Could not check this sensor with Syai: \(error.localizedDescription)")
            }
            expectedCoefficients = validation.coefficients

            onStage(.bleSearching)
            onStage(.handshaking)
            onStage(.activating)
            let provider = calibrationProvider
            var activateAttemptedAt: Date?
            var attempt = 0
            var outcome: SyaiBLE.RemoteActivationOutcome?
            while outcome == nil {
                attempt += 1
                do {
                    outcome = try await sensorKit.activateRemotely(identity: identity) { authDev, authFlag in
                        try await provider.authorizeActivation(mac: identity.mac, authDev: authDev, authFlag: authFlag)
                    }
                } catch {
                    if case SyaiActivationSequence.ActivationError.interrupted(at: .activate, _) = error {
                        // The activate command may have landed; the cmd gate on the next attempt tells.
                        activateAttemptedAt = activateAttemptedAt ?? Date()
                    }
                    guard Self.isRetryableActivationFailure(error), attempt < Self.maxActivationAttempts else {
                        if let activateAttemptedAt {
                            onActivated?(SyaiPendingBind(
                                mac: identity.mac, deviceVersion: validation.deviceVersion, activatedAt: activateAttemptedAt
                            ))
                        }
                        if let failure = error as? Failure { throw failure }
                        throw Failure.underlying("Activation failed: \(error.localizedDescription)")
                    }
                    logger.warning("activation attempt \(attempt) failed (\(error)); reconnecting for attempt \(attempt + 1)")
                    try await Task.sleep(nanoseconds: Self.activationRetryDelayNanos)
                }
            }
            guard let outcome else { throw Failure.underlying("Activation failed.") }
            if !outcome.didActivate, activateAttemptedAt == nil {
                logger.warning("sensor was already activated before this attempt; binding with the current time as its start")
            }
            activationPeripheralID = outcome.peripheralID
            let deviceVersion = validation.deviceVersion.isEmpty
                ? Self.deviceVersion(fromFirmware: outcome.firmwareVersion)
                : validation.deviceVersion
            // Started on this attempt → now; already active after an interrupted
            // activate write on an earlier attempt → that write's time.
            let activatedAt = outcome.didActivate ? Date() : (activateAttemptedAt ?? Date())
            pending = SyaiPendingBind(mac: identity.mac, deviceVersion: deviceVersion, activatedAt: activatedAt)
            onActivated?(pending)
        }

        onStage(.binding)
        let (provisioning, methodBlob) = try await bindAndProvision(
            pending, binder: binder, expectedCoefficients: expectedCoefficients
        )

        let session = try await connect(
            identity: identity, keyGroup: provisioning.keyGroup,
            expectedPeripheralID: activationPeripheralID, onStage: onStage
        )

        pairSucceeded = true
        return makeOutcome(
            mac: identity.mac,
            session: session,
            deviceInfo: provisioning.deviceInfo,
            activatedAt: pending.activatedAt,
            methodBlob: methodBlob
        )
    }

    /// Binds the activated sensor and resolves its own record: the bind
    /// response first, then the bound-sensor lookup. A failed bind is not
    /// fatal by itself, since the sensor may already be bound from an earlier
    /// attempt; only ending up with no record is.
    private func bindAndProvision(
        _ pending: SyaiPendingBind,
        binder: SyaiServerDeviceBinder,
        expectedCoefficients: [Double]?
    ) async throws -> (SyaiProvisioning, String?) {
        let mac = pending.mac
        await Self.attemptMarkDeviceStatus(binder: binder, mac: mac, inProgress: true)
        defer {
            Task { await Self.attemptMarkDeviceStatus(binder: binder, mac: mac, inProgress: false) }
        }

        var bindResult: SyaiBindResult?
        var lastProblem = "no bind response"
        do {
            let result = try await binder.bind(
                mac: mac, deviceVersion: pending.deviceVersion, activatedAt: pending.activatedAt
            )
            logger.info("registering sensor: \(result.code)")
            bindResult = result
            lastProblem = "bind answered \(result.code)"
        } catch {
            logger.warning("registering sensor failed: \(error.localizedDescription)")
            lastProblem = error.localizedDescription
        }

        var provisioning: SyaiProvisioning?
        if let bindResult, bindResult.isSuccess {
            do {
                provisioning = try binder.provisioning(from: bindResult, mac: mac)
            } catch {
                logger.warning("bind response has no usable sensor record: \(error)")
                lastProblem = "\(error)"
            }
        }
        if provisioning == nil, let boundSensorLookup {
            do {
                if let bound = try await boundSensorLookup.boundSensor(),
                   bound.mac.uppercased() == mac.uppercased()
                {
                    logger.info("sensor record resolved from the bound-sensor lookup")
                    provisioning = SyaiProvisioning(deviceInfo: bound.deviceInfo, keyGroup: bound.keyGroup)
                } else {
                    lastProblem = "the account has no record of this sensor yet"
                }
            } catch {
                logger.warning("bound-sensor lookup failed: \(error.localizedDescription)")
                lastProblem = error.localizedDescription
            }
        }
        guard let provisioning else { throw Failure.awaitingSensorRecord(lastProblem) }

        if let expectedCoefficients,
           !Self.coefficientsMatch(expectedCoefficients, provisioning.deviceInfo.coefficients)
        {
            logger.error("post-bind coefficients differ from the pre-activation set; refusing the sensor")
            throw Failure.calibrationMismatch
        }
        return (provisioning, bindResult?.methodBlob)
    }

    /// Activation attempts per pairing. Each one is a fresh connection with a
    /// fresh server answer, since the frames are only valid for the link they
    /// were made for.
    static let maxActivationAttempts = 3
    static let activationRetryDelayNanos: UInt64 = 2_000_000_000

    /// A dropped link or an interrupted write is worth another connection; the
    /// cmd-state gate keeps a retry from re-activating a sensor that got there.
    /// Server refusals, missing frames and unsupported firmware are final.
    static func isRetryableActivationFailure(_ error: Error) -> Bool {
        switch error {
        case Failure.droppedAfterConnect: return true
        case SyaiActivationSequence.ActivationError.interrupted: return true
        default: return false
        }
    }

    static func coefficientsMatch(_ a: [Double], _ b: [Double]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { abs($0 - $1) <= 1e-9 * max(1, abs($0), abs($1)) }
    }

    /// The server-style firmware version (`V1.7.SH22601.3`) out of the BLE
    /// version string (`E2.0.3(V1.7.SH22601.3),STDRD`), for a bind whose
    /// validate answer didn't carry one.
    static func deviceVersion(fromFirmware firmware: String) -> String {
        guard let open = firmware.firstIndex(of: "("),
              let close = firmware[open...].firstIndex(of: ")"),
              firmware.index(after: open) < close
        else { return firmware.trimmingCharacters(in: .whitespaces) }
        return String(firmware[firmware.index(after: open) ..< close])
    }

    private func resolveIdentity(
        knownIdentity: SyaiSensorIdentity?,
        onStage: @Sendable @escaping (Stage) -> Void
    ) async throws -> SyaiSensorIdentity {
        if let knownIdentity { return knownIdentity }
        onStage(.discoveringSensor)
        let identity: SyaiSensorIdentity
        do {
            identity = try await sensorKit.readMAC()
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.underlying("Sensor discovery failed: \(error.localizedDescription)")
        }
        guard !identity.mac.isEmpty else { throw Failure.bleNoSensorDiscovered }
        logger.info("discovered sensor \(SyaiRedact.mac(identity.mac))")
        onStage(.sensorFound(mac: identity.mac))
        return identity
    }

    private func connect(
        identity: SyaiSensorIdentity,
        keyGroup: SyaiKeyGroup?,
        expectedPeripheralID: UUID?,
        onStage: @Sendable @escaping (Stage) -> Void
    ) async throws -> SyaiSensorSession {
        onStage(.bleSearching)
        onStage(.bleConnecting)
        onStage(.handshaking)
        do {
            return try await sensorKit.connectAndAuthenticate(
                identity: identity, keyGroup: keyGroup, expectedPeripheralID: expectedPeripheralID
            )
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.underlying("BLE connect/auth failed: \(error.localizedDescription)")
        }
    }

    private func makeOutcome(
        mac: String, session: SyaiSensorSession, deviceInfo: DeviceInfo, activatedAt: Date?,
        methodBlob: String? = nil
    ) -> AttachOutcome {
        let monitor = SyaiSensorMonitor.make(session: session, sensorKit: sensorKit, calibration: deviceInfo.calibration)
        return AttachOutcome(
            mac: mac,
            peripheralID: session.peripheralID,
            monitor: monitor,
            deviceInfo: deviceInfo,
            keyGroup: session.keyGroup,
            activatedAt: activatedAt,
            methodBlob: methodBlob
        )
    }

    private static func attemptMarkDeviceStatus(binder: SyaiServerDeviceBinder, mac: String, inProgress: Bool) async {
        do {
            try await binder.markDeviceStatus(mac: mac, inProgress: inProgress)
        } catch {
            SyaiLogger(category: "PairingService").debug(
                "could not send markDeviceStatus(\(inProgress)): \(error.localizedDescription)"
            )
        }
    }
}
