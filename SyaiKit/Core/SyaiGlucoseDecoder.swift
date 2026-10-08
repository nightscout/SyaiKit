//
//  SyaiGlucoseDecoder.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

public struct SyaiGlucoseDecoder {
    public static let glucoseProgram =
        "V1 C0 ad C1 ml C2 ad;" +
        "V0 R0 2 pw dv;" +
        "C3 0 ml C4 R1 2 pw ml ad C5 R1 ml ad C6 ad;" +
        "C7 R2 2 pw ml C8 R2 ml ad C9 ad;" +
        "C10 V2 86400 dv C11 ml sb V2 C12 1 le ml V2 C12 1 gt C13 ml ad;" +
        "R3 R4 ml 1 rd"

    public struct RawChannels: Equatable, Sendable {
        public let v0: Double
        public let v1: Double
        public let v2: Double
        public init(v0: Double, v1: Double, v2: Double) {
            self.v0 = v0
            self.v1 = v1
            self.v2 = v2
        }
    }

    public static let minDisplayableMgDL = 36.0
    public static let maxDisplayableMgDL = 450.0

    public struct Output: Equatable, Sendable {
        public let rawGlucoseMgDL: Double
        public let adjustedGlucoseMgDL: Double
        public let condition: GlucoseSample.Condition?
    }

    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case nonFiniteGlucose
        case wrongCoefficientCount(Int)

        public var description: String {
            switch self {
            case .nonFiniteGlucose:
                return "glucose decode produced a non-finite value"
            case let .wrongCoefficientCount(count):
                return "calibration has \(count) coefficients, expected \(SyaiGlucoseDecoder.coefficientCount)"
            }
        }
    }

    static let coefficientCount = 14

    private let logger = SyaiLogger(category: "SyaiGlucoseDecoder")

    public init() {}

    public func glucose(from raw: RawChannels, calibration: Calibration) throws -> Output {
        // Throw rather than trap: a corrupt persisted record must drop frames,
        // not crash the host app.
        guard calibration.coefficients.count == Self.coefficientCount else {
            throw DecodeError.wrongCoefficientCount(calibration.coefficients.count)
        }

        let env = SyaiRPNEvaluator.Environment(
            v: [raw.v0, raw.v1, raw.v2],
            c: calibration.coefficients
        )

        let rawGlucoseMmolL = try SyaiRPNEvaluator.evaluateProgram(Self.glucoseProgram, environment: env)

        let rawGlucose = rawGlucoseMmolL * 18.0

        // NaN compares false against both clamps below and would pass through
        // as an ordinary in-range reading — and crash HKQuantity on the dosing
        // path. A non-finite result is a decode failure; drop the frame.
        guard rawGlucose.isFinite else { throw DecodeError.nonFiniteGlucose }

        let condition: GlucoseSample.Condition?
        let clamped: Double
        if rawGlucose <= Self.minDisplayableMgDL {
            condition = .belowRange
            clamped = Self.minDisplayableMgDL
        } else if rawGlucose >= Self.maxDisplayableMgDL {
            condition = .aboveRange
            clamped = Self.maxDisplayableMgDL
        } else {
            condition = nil
            clamped = rawGlucose
        }

        return Output(
            rawGlucoseMgDL: rawGlucose,
            adjustedGlucoseMgDL: clamped,
            condition: condition
        )
    }
}
