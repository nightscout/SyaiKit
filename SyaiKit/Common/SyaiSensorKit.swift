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

/// Device record + BLE keys resolved for a MAC. The sensor must be a still-unbound
/// factory sensor for the fetch to succeed at all (an already-bound sensor can't
/// be fetched, so there is no attach path). `keyGroup` is optional to accommodate
/// providers/fakes with no real keys; shipping providers always supply one.
public struct SyaiProvisioning: Sendable {
    public let deviceInfo: DeviceInfo
    public let keyGroup: SyaiKeyGroup?
    public init(deviceInfo: DeviceInfo, keyGroup: SyaiKeyGroup?) {
        self.deviceInfo = deviceInfo
        self.keyGroup = keyGroup
    }
}

/// Supplies the per-sensor `DeviceInfo` (identity + calibration coefficients) and
/// BLE key group for a MAC. Kept separate from `SyaiBLE` so the sourcing strategy
/// is swappable. There is deliberately no offline/default implementation: a sensor
/// without a real per-sensor record is not paired.
public protocol CalibrationProvider: Sendable {
    func provision(forMAC mac: String) async throws -> SyaiProvisioning
}
