//
//  SyaiBLE.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import CoreBluetooth
import Foundation

public final class SyaiBLE: @unchecked Sendable {
    private let logger = SyaiLogger(category: "SensorKit")
    private let central = SyaiBLECentral.shared
    private let frameParsing: SyaiFrameParsing
    private let overrideMAC: String?
    private let discoveryScanTimeout: TimeInterval
    private let scanTimeout: TimeInterval
    private let reconnectScanTimeout: TimeInterval
    private let aes = AESECB()

    public init(
        frameParsing: SyaiFrameParsing = SyaiV17FrameParsing(fallback: SyaiV16FrameParsing()),
        overrideMAC: String? = nil,
        discoveryScanTimeout: TimeInterval = 30,
        scanTimeout: TimeInterval = 20,
        reconnectScanTimeout: TimeInterval = 180
    ) {
        self.frameParsing = frameParsing
        self.overrideMAC = overrideMAC
        self.discoveryScanTimeout = discoveryScanTimeout
        self.scanTimeout = scanTimeout
        self.reconnectScanTimeout = reconnectScanTimeout
    }

    public func readMAC() async throws -> SyaiSensorIdentity {
        if let overrideMAC, !overrideMAC.isEmpty {
            return SyaiSensorIdentity(mac: overrideMAC.uppercased())
        }

        let found = try await central.discoverSensors(scanTimeout: discoveryScanTimeout)
        guard let strongest = found.first else {
            throw SyaiPairingService.Failure.bleNoSensorDiscovered
        }
        if found.count > 1 {
            logger.info(
                "multiple sensors in range; picking strongest \(SyaiRedact.mac(strongest.mac)) "
                    + "(rssi \(strongest.rssi)) of \(found.count)"
            )
        }
        return SyaiSensorIdentity(mac: strongest.mac)
    }

    public func discoverSensorCandidates() async throws -> [SyaiSensorCandidate] {
        if let overrideMAC, !overrideMAC.isEmpty {
            return [SyaiSensorCandidate(mac: overrideMAC.uppercased())]
        }

        return try await central.discoverSensors(scanTimeout: discoveryScanTimeout)
            .map { SyaiSensorCandidate(mac: $0.mac, rssi: $0.rssi) }
    }

    public func connectAndAuthenticate(
        identity: SyaiSensorIdentity,
        keyGroup: SyaiKeyGroup?,
        expectedPeripheralID: UUID?
    ) async throws -> SyaiSensorSession {
        guard let keyGroup else { throw SyaiPairingService.Failure.noKeyGroup }
        let s = try await connectAndAuth(
            mac: identity.mac,
            keyGroup: keyGroup,
            expectedPeripheralID: expectedPeripheralID,
            scanTimeout: reconnectScanTimeout
        )
        try refuseUnverifiedFirmware(s)
        return makeSession(s, keyGroup: keyGroup, cmdState: s.cmdState)
    }

    public func activate(
        identity: SyaiSensorIdentity,
        keyGroup: SyaiKeyGroup?,
        calibration: Calibration,
        activeDurationSeconds: UInt32
    ) async throws -> SyaiSensorSession {
        guard let keyGroup else { throw SyaiPairingService.Failure.noKeyGroup }

        let s = try await connectAndAuth(
            mac: identity.mac,
            keyGroup: keyGroup,
            expectedPeripheralID: nil,
            scanTimeout: scanTimeout
        )
        try refuseUnverifiedFirmware(s)
        var cmdState = s.cmdState
        do {
            logger.info("activating sensor mac=\(SyaiRedact.mac(identity.mac))")
            try await SyaiActivationSequence.run(
                transport: s.peripheral, calibration: calibration,
                durationSeconds: activeDurationSeconds,
                encrypt: {
                    try self.aes.encryptECB(
                        SyaiActivationFrame.zeroPadToBlock($0),
                        key: s.sessionKey,
                        padding: false
                    )
                }
            )
            logger.info("activated sensor mac=\(SyaiRedact.mac(identity.mac))")
            cmdState = Self.healthyCmdState
        } catch let SyaiActivationSequence.ActivationError.alreadyActive(state) {
            logger.info("sensor already activated (cmd-state \(state)); skipping writes mac=\(SyaiRedact.mac(identity.mac))")
        }
        return makeSession(s, keyGroup: keyGroup, cmdState: cmdState)
    }

    public func rawChannels(from frame: SyaiDecryptedFrame) throws -> SyaiGlucoseDecoder.RawChannels {
        try SyaiFrameParser.rawChannels(from: frame, using: frameParsing)
    }

    private struct AuthedLink {
        let peripheral: SyaiBLEPeripheral
        let sessionKey: Data
        let firmwareVersion: String
        let parseVersion: String
        /// The cmd characteristic's lifecycle state at connect, or nil if the read failed.
        let cmdState: Int?
    }

    // 0: starting, 1: self-test, 2: unactivated, 3: healthy, 4: faulty/obsolete
    static let healthyCmdState = 3

    private func connectAndAuth(
        mac: String,
        keyGroup: SyaiKeyGroup,
        expectedPeripheralID: UUID?,
        scanTimeout: TimeInterval
    ) async throws -> AuthedLink {
        let peripheral: SyaiBLEPeripheral
        do {
            peripheral = try await central.scanAndConnect(
                mac: mac, expectedPeripheralID: expectedPeripheralID, scanTimeout: scanTimeout
            )
        } catch let SyaiBLECentral.BLEError.disconnected(reason) {
            throw SyaiPairingService.Failure.droppedAfterConnect(reason)
        }

        let sessionKey: Data
        do {
            sessionKey = try await SyaiBLEAuthV2.authenticate(
                transport: peripheral, mac: mac, keyGroup: keyGroup
            )
        } catch {
            throw SyaiPairingService.Failure.droppedAfterConnect(error.localizedDescription)
        }

        let versionData = (try? await peripheral.read(SyaiGATT.softVersion)) ?? Data()
        let versionStr = String(data: versionData, encoding: .utf8) ?? ""
        let parseVersion = SyaiFrameParser.parseVersion(forDeviceVersion: versionStr)
        if versionStr.contains("V1.8.") || versionStr.contains("V2.0.") {
            logger.info("firmware \"\(versionStr)\" is decoded as V1.7 per the vendor profile; first hardware sighting")
        }

        do {
            try await peripheral.write(
                SyaiActivationFrame.defaultBleIntervalFrame(),
                to: SyaiGATT.ctlDevice,
                withResponse: false
            )
            logger.debug("wrote BLE interval setting")
        } catch {
            logger.debug("BLE interval setting write failed: \(error.localizedDescription)")
        }

        let cmdState = (try? await peripheral.read(SyaiGATT.cmd)).flatMap(\.first).map(Int.init)
        if let cmdState, cmdState > Self.healthyCmdState {
            logger
                .error("sensor cmd-state \(cmdState) (> \(Self.healthyCmdState)): device state obsolete (sensor needs replacing)")
        }
        logger
            .info(
                "authenticated. mac=\(SyaiRedact.mac(mac)) fw=\"\(versionStr)\" parseVersion=\(parseVersion) cmdState=\(cmdState.map(String.init) ?? "unread")"
            )
        return AuthedLink(
            peripheral: peripheral,
            sessionKey: sessionKey,
            firmwareVersion: versionStr,
            parseVersion: parseVersion,
            cmdState: cmdState
        )
    }

    /// Drops the link to a sensor whose readings can't be decoded, before
    /// anything is written to it.
    private func refuseUnverifiedFirmware(_ link: AuthedLink) throws {
        guard !SyaiFrameParser.isVerified(parseVersion: link.parseVersion) else { return }
        logger.error("refusing sensor: firmware \"\(link.firmwareVersion)\" has no verified glucose decode")
        link.peripheral.disconnect()
        throw SyaiPairingService.Failure.unsupportedFirmware(link.firmwareVersion)
    }

    private func makeSession(_ link: AuthedLink, keyGroup: SyaiKeyGroup, cmdState: Int?) -> SyaiSensorSession {
        SyaiSensorSession(
            transport: link.peripheral, keyGroup: keyGroup, sessionKey: link.sessionKey,
            parseVersion: link.parseVersion, aes: aes,
            reportedCmdState: cmdState
        )
    }
}
