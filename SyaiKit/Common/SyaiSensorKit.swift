//
//  SyaiSensorKit.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import CoreBluetooth
import Foundation

public struct SyaiSensorIdentity: Equatable, Sendable {
    public let mac: String
    public init(mac: String) { self.mac = mac }
}

public struct SyaiSensorCandidate: Equatable, Sendable, Identifiable {
    public let mac: String
    public let rssi: Int?
    public var id: String { mac }
    public init(mac: String, rssi: Int? = nil) {
        self.mac = mac
        self.rssi = rssi
    }
}

/// The BLE auth key group; 6 keys unique to each sensor.
public struct SyaiKeyGroup: Equatable, Sendable, RawRepresentable {
    public let raw: Data
    public init(raw: Data) { self.raw = raw }

    public init?(rawValue: String) {
        guard let data = Data(base64Encoded: rawValue) else { return nil }
        raw = data
    }

    public var rawValue: String { raw.base64EncodedString() }
}

public struct SyaiSensorFault: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The cmd characteristic latched to a fault state (>= 4). This is the
        /// only positively identified fault signal in the protocol; it is terminal
        /// and must be treated as replace-the-sensor. It persists into
        /// `CGMManagerState` and surfaces as `SyaiSensorStatusDisplay.malfunction`.
        case deviceStateObsolete(state: Int)

        /// The cmd characteristic reports a state below "activated" (0 starting,
        /// 1 self-test, 2 unactivated) on a sensor we already hold an
        /// `activatedAt` for — its lifecycle state doesn't match what we expect.
        /// Terminal: nothing this session reports can be trusted for dosing.
        case deviceStateUnactivated(state: Int)

        /// Client-side verdict: the raw electrode current stayed below the
        /// plausibility floor for a full streak. The cmd state does not report this
        /// failure mode — it reads healthy while the electrode is dead — so it is
        /// detected from the data stream. Terminal and persisted, but ending the
        /// sensor stays user-confirmed.
        case signalImplausible

        /// An `errorInfo` payload. Nothing in this channel is currently known to
        /// be a fault; it carries routine `0x77XX` status frames on every connect,
        /// so this case exists for a future positively identified encoding and is
        /// never produced today.
        case errorInfo
    }

    public let kind: Kind
    public let raw: Data
    public let receivedAt: Date

    public var isTerminal: Bool {
        switch kind {
        case .deviceStateObsolete,
             .deviceStateUnactivated,
             .signalImplausible: return true
        case .errorInfo: return false
        }
    }

    public init(kind: Kind = .errorInfo, raw: Data, receivedAt: Date) {
        self.kind = kind
        self.raw = raw
        self.receivedAt = receivedAt
    }
}

public enum SyaiHistoricalBatchStatus: Equatable, Sendable {
    /// One paged history packet arrived. `recordCount` counts only real records;
    /// `surplusPackage` is the packet's own countdown (`>= 1` means more coming).
    case packetReceived(startIndex: UInt16, recordCount: Int, surplusPackage: Int16)
    case batchComplete
}

public struct SyaiDecryptedFrame: Equatable, Sendable {
    public let plaintext: Data
    public let sequence: UInt16
    public let parseVersion: String
    public let receivedAt: Date
    public let isHistorical: Bool
    public init(plaintext: Data, sequence: UInt16, parseVersion: String, receivedAt: Date, isHistorical: Bool = false) {
        self.plaintext = plaintext
        self.sequence = sequence
        self.parseVersion = parseVersion
        self.receivedAt = receivedAt
        self.isHistorical = isHistorical
    }
}

/// A sensor's own device record (identity, coefficients, durations) and BLE key
/// group, as the server hands them out once the sensor is bound to the account.
public struct SyaiProvisioning: Equatable, Sendable {
    public let deviceInfo: DeviceInfo
    public let keyGroup: SyaiKeyGroup
    public init(deviceInfo: DeviceInfo, keyGroup: SyaiKeyGroup) {
        self.deviceInfo = deviceInfo
        self.keyGroup = keyGroup
    }
}

/// The pre-activation answer for a factory sensor (`validateDeviceByMacV3`).
/// It confirms the account may start this sensor and carries what the bind
/// needs. Coefficients and keys are not handed out until the sensor is bound;
/// when the server does include coefficients they're kept, so the post-bind
/// set can be checked against them.
public struct SyaiSensorValidation: Equatable, Sendable {
    public let mac: String
    public let deviceVersion: String
    public let coefficients: [Double]?

    public init(mac: String, deviceVersion: String, coefficients: [Double]? = nil) {
        self.mac = mac
        self.deviceVersion = deviceVersion
        self.coefficients = coefficients
    }
}

/// Server-built activation material for one BLE connection (`cgmAuth/verify`).
/// The server answers the sensor's auth challenge itself, so the phone holds
/// neither the key group nor the session key while activating; every frame
/// below is already encrypted for this connection and is written verbatim.
public struct SyaiRemoteActivation: Equatable, Sendable {
    /// Written to `authHost` / `authFlag` to complete the handshake.
    public let authHost: Data
    public let authFlag: Data
    /// Written to `ctlDevice`, `activeDuration` and `cmd` respectively.
    public let coefficientFrame: Data?
    public let durationFrame: Data?
    public let activateFrame: Data?

    public init(authHost: Data, authFlag: Data, coefficientFrame: Data?, durationFrame: Data?, activateFrame: Data?) {
        self.authHost = authHost
        self.authFlag = authFlag
        self.coefficientFrame = coefficientFrame
        self.durationFrame = durationFrame
        self.activateFrame = activateFrame
    }
}

/// The server side of activating a factory sensor. Kept separate from `SyaiBLE`
/// so the BLE layer never talks to the account. There is deliberately no
/// offline/default implementation: a sensor without its own server record is
/// not paired.
public protocol CalibrationProvider: Sendable {
    func validate(mac: String) async throws -> SyaiSensorValidation
    func authorizeActivation(mac: String, authDev: Data, authFlag: Data) async throws -> SyaiRemoteActivation
}
