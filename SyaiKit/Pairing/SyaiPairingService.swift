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

    /// Optional account-backed binder. Present only on the `activate` path.
    private let binder: SyaiServerDeviceBinder?

    public init(
        sensorKit: SyaiBLE,
        calibrationProvider: CalibrationProvider,
        binder: SyaiServerDeviceBinder? = nil
    ) {
        self.sensorKit = sensorKit
        self.calibrationProvider = calibrationProvider
        self.binder = binder
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

    /// Activation (primary pairing path): resolve identity and device record,
    /// activate the factory sensor over BLE, then bind it to the logged-in account.
    ///
    /// ## Why activate-then-bind
    /// Binding flips the sensor's server-side lifecycle, after which the
    /// calibration fetch answers "already used" instead of returning coefficients.
    /// Binding before activation can leave the sensor bound but not activated,
    /// with unfetchable coefficients.
    ///
    /// ## Why provisioning is persisted before the writes
    /// Once activation writes land, the coefficient fetch is dead. If the app
    /// died between a successful write sequence and record persistence, the
    /// coefficients would be lost with no re-fetch path. `onProvisioningResolved`
    /// fires before any BLE traffic so the manager can persist a pending
    /// activation record.
    public func activate(
        preselectedIdentity: SyaiSensorIdentity? = nil,
        pendingProvisioning: (@Sendable(String) -> SyaiProvisioning?)? = nil,
        onProvisioningResolved: (@Sendable(SyaiProvisioning) -> Void)? = nil,
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

        // A picker-selected identity skips BLE discovery.
        let identity = try await resolveIdentity(knownIdentity: preselectedIdentity, onStage: onStage)
        pairMAC = identity.mac

        let provisioning: SyaiProvisioning
        if let pending = pendingProvisioning?(identity.mac) {
            logger.info("reusing pending-activation record for \(SyaiRedact.mac(identity.mac)), skipping calibration fetch")
            provisioning = pending
        } else {
            onStage(.resolvingCalibration)
            do {
                provisioning = try await calibrationProvider.provision(forMAC: identity.mac)
            } catch {
                throw Failure.underlying("Could not fetch calibration: \(error.localizedDescription)")
            }
            onProvisioningResolved?(provisioning)
        }

        let deviceInfo = provisioning.deviceInfo
        let keyGroup = provisioning.keyGroup

        onStage(.bleSearching)
        onStage(.handshaking)
        onStage(.activating)
        let session: SyaiSensorSession
        do {
            session = try await sensorKit.activate(
                identity: identity, keyGroup: keyGroup, calibration: deviceInfo.calibration,
                activeDurationSeconds: SyaiActivationSequence.activationDurationSeconds(for: deviceInfo)
            )
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.underlying("Activation failed: \(error.localizedDescription)")
        }

        let activatedAt = Date()

        // Binding is account bookkeeping after activation; a failure must not fail pairing.
        let bindResult = await registerSensor(
            mac: identity.mac,
            deviceInfo: deviceInfo,
            activatedAt: activatedAt,
            onStage: onStage
        )

        pairSucceeded = true
        return makeOutcome(
            mac: identity.mac,
            session: session,
            deviceInfo: deviceInfo,
            activatedAt: activatedAt,
            methodBlob: bindResult?.methodBlob
        )
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

    private func registerSensor(
        mac: String,
        deviceInfo: DeviceInfo,
        activatedAt: Date,
        onStage: @Sendable @escaping (Stage) -> Void
    ) async -> SyaiBindResult? {
        guard let binder else { return nil }
        onStage(.binding)
        await Self.attemptMarkDeviceStatus(binder: binder, mac: mac, inProgress: true)
        defer {
            Task { await Self.attemptMarkDeviceStatus(binder: binder, mac: mac, inProgress: false) }
        }
        do {
            let result = try await binder.bind(mac: mac, deviceInfo: deviceInfo, activatedAt: activatedAt)
            logger.info("registering sensor: \(result.code)")
            return result
        } catch {
            logger.warning("registering sensor failed: \(error.localizedDescription)")
            return nil
        }
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
