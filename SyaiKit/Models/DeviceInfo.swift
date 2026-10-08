//
//  DeviceInfo.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

public struct DeviceInfo: Equatable, Sendable, Identifiable, RawRepresentable {
    public let mac: String
    public let serialNo: String
    public let batchNo: String
    public let deviceType: String
    public let deviceVersion: String
    public let coefficients: [Double]
    public let k: Double
    public let b: Double
    public let produceTime: Date
    public let expireTime: Date?
    public let activeDuration: TimeInterval
    public let preheatDuration: TimeInterval

    public var id: String { mac }

    public init(
        mac: String,
        serialNo: String,
        batchNo: String,
        deviceType: String,
        deviceVersion: String,
        coefficients: [Double],
        k: Double,
        b: Double,
        produceTime: Date,
        expireTime: Date? = nil,
        activeDuration: TimeInterval,
        preheatDuration: TimeInterval
    ) {
        self.mac = mac
        self.serialNo = serialNo
        self.batchNo = batchNo
        self.deviceType = deviceType
        self.deviceVersion = deviceVersion
        self.coefficients = coefficients
        self.k = k
        self.b = b
        self.produceTime = produceTime
        self.expireTime = expireTime
        self.activeDuration = activeDuration
        self.preheatDuration = preheatDuration
    }

    public var calibration: Calibration {
        Calibration(coefficients: coefficients, k: k, b: b)
    }

    public typealias RawValue = [String: Any]

    public init?(rawValue: RawValue) {
        guard let mac = rawValue["mac"] as? String,
              let coefficients = rawValue["coefficients"] as? [Double],
              let k = rawValue["k"] as? Double,
              let b = rawValue["b"] as? Double,
              let activeDuration = rawValue["activeDurationSeconds"] as? Double,
              let preheatDuration = rawValue["preheatDurationSeconds"] as? Double else { return nil }
        self.mac = mac
        serialNo = rawValue["serialNo"] as? String ?? ""
        batchNo = rawValue["batchNo"] as? String ?? ""
        deviceType = rawValue["deviceType"] as? String ?? ""
        deviceVersion = rawValue["deviceVersion"] as? String ?? ""
        self.coefficients = coefficients
        self.k = k
        self.b = b
        produceTime = rawValue["produceTime"] as? Date ?? Date(timeIntervalSince1970: 0)
        expireTime = rawValue["expireTime"] as? Date
        self.activeDuration = activeDuration
        self.preheatDuration = preheatDuration
    }

    public var rawValue: RawValue {
        var raw: RawValue = [
            "mac": mac,
            "serialNo": serialNo,
            "batchNo": batchNo,
            "deviceType": deviceType,
            "deviceVersion": deviceVersion,
            "coefficients": coefficients,
            "k": k,
            "b": b,
            "produceTime": produceTime
        ]
        raw["expireTime"] = expireTime
        raw["activeDurationSeconds"] = activeDuration
        raw["preheatDurationSeconds"] = preheatDuration
        return raw
    }
}
