//
//  SyaiGlucoseDecoderTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Validates the ported glucose formula against the Syai binary's own logic.
final class SyaiGlucoseDecoderTests: XCTestCase {
    func testDefaultCoefficientsHaveFourteenEntries() {
        XCTAssertEqual(Calibration.appDefaultCoefficientsFixture.count, 14)
        // C12 is the 2-day age threshold (seconds).
        XCTAssertEqual(Calibration.appDefaultCoefficientsFixture[12], 172_800.0)
    }

    func testRPNEvaluatorBasicOps() throws {
        // "2 3 ad" = 5 ; "5 R0 ml" reads register 0 (=5) → 25 ; last statement wins.
        let env = SyaiRPNEvaluator.Environment(v: [], c: [])
        let result = try SyaiRPNEvaluator.evaluateProgram("2 3 ad;5 R0 ml", environment: env)
        XCTAssertEqual(result, 25.0, accuracy: 1E-9)
    }

    func testRPNComparatorsAreTernary() throws {
        // `a b c op` -> `(a <op> b) ? c : 0` — three operands,
        // not two. The old binary "push 1.0/0.0" model was wrong
        // (indistinguishable from correct below the program's only le/gt use's
        // regime boundary, V2 <= C12 = 172800s) and read dosing-grade low past it.
        let env = SyaiRPNEvaluator.Environment(v: [], c: [])
        XCTAssertEqual(
            try SyaiRPNEvaluator.evaluateStatement("1 2 99 le", environment: env),
            99.0,
            "1 <= 2 holds -> the true-value (99)"
        )
        XCTAssertEqual(
            try SyaiRPNEvaluator.evaluateStatement("3 2 99 le", environment: env),
            0.0,
            "3 <= 2 does not hold -> 0"
        )
        XCTAssertEqual(
            try SyaiRPNEvaluator.evaluateStatement("3 2 99 gt", environment: env),
            99.0,
            "3 > 2 holds -> the true-value (99)"
        )
        XCTAssertEqual(
            try SyaiRPNEvaluator.evaluateStatement("1 2 99 gt", environment: env),
            0.0,
            "1 > 2 does not hold -> 0"
        )
    }

    func testRPNComparatorsUnderflowBelowThreeOperands() {
        let env = SyaiRPNEvaluator.Environment(v: [], c: [])
        XCTAssertThrowsError(try SyaiRPNEvaluator.evaluateStatement("1 2 le", environment: env)) { error in
            guard case SyaiRPNEvaluator.EvalError.stackUnderflow = error else {
                return XCTFail("expected .stackUnderflow, got \(error)")
            }
        }
    }

    /// Statement 5's `R4` (the time-decay factor) must PIN to `C13` once
    /// `V2` exceeds `C12`, not keep drifting from `T` forever — the exact bug that
    /// went undetected until a session finally ran a sensor past 48h. Direct
    /// statement-level test (not routed through the full glucose program) so the
    /// magnitude of the old bug is checkable precisely, independent of any
    /// incidental rounding boundary in a specific V0/V1 pair.
    func testStatement5PinsToC13PastFortyEightHours() throws {
        // Real per-sensor coefficients.
        let coeffs = [
            0.1,
            0.5,
            18.5,
            0.0,
            -0.0016,
            0.5053,
            0.1458,
            0.015,
            1.05,
            0.8,
            1.05,
            0.025,
            172_800.0,
            1.0
        ]
        let statement5 = "C10 V2 86400 dv C11 ml sb V2 C12 1 le ml V2 C12 1 gt C13 ml ad"

        func r4(atV2 v2: Double) throws -> Double {
            let env = SyaiRPNEvaluator.Environment(v: [0, 0, v2], c: coeffs)
            return try SyaiRPNEvaluator.evaluateStatement(statement5, environment: env)
        }

        // Just under the 48h boundary: still ramping (T), essentially 1.0 but not
        // pinned yet.
        XCTAssertEqual(try r4(atV2: 172_799), 1.0, accuracy: 1E-6)
        // Exactly at, and just past: pinned to C13 = 1.0.
        XCTAssertEqual(try r4(atV2: 172_800), 1.0, accuracy: 1E-9)
        XCTAssertEqual(try r4(atV2: 172_801), 1.0, accuracy: 1E-9)
        // Day 14 (1,209,600s): the old (wrong) binary+takeFirst model would have
        // kept computing T = C10 - (V2/86400)*C11 = 1.05 - 14*0.025 = 0.7 here —
        // a 30% error. The corrected model must stay pinned at C13 = 1.0.
        XCTAssertEqual(
            try r4(atV2: 14 * 24 * 3600),
            1.0,
            accuracy: 1E-9,
            "R4 must stay pinned at C13, not keep drifting from T"
        )
        // Further out still: same pin holds.
        XCTAssertEqual(try r4(atV2: 30 * 24 * 3600), 1.0, accuracy: 1E-9)
    }

    func testRoundIsBinaryValueDigits() throws {
        // rd = round(value, ndigits). "12.345 1 rd" → 12.3
        let env = SyaiRPNEvaluator.Environment(v: [], c: [])
        XCTAssertEqual(try SyaiRPNEvaluator.evaluateStatement("12.345 1 rd", environment: env), 12.3, accuracy: 1E-9)
    }

    func testResidualStackIsReducedNotRejected() throws {
        // A malformed/non-single-result statement must not throw — `stack.first`
        // is a defensive fallback (with le/gt's correct ternary arity, every
        // statement in the real program balances to exactly one value on its own;
        // this residual-stack path was never actually exercised by the app's real
        // program, just a defensive backstop kept in case a future statement isn't
        // perfectly balanced).
        let env = SyaiRPNEvaluator.Environment(v: [1, 2, 3], c: [])
        XCTAssertNoThrow(try SyaiRPNEvaluator.evaluateStatement("V0 V1 ad V2", environment: env))
    }

    func testGlucoseProgramEvaluatesWithDefaults() throws {
        // Structural: the real program + default coeffs must produce a finite
        // number for representative raw channels (no throw, no NaN). With these
        // synthetic inputs the base lands at 1.0 mmol/L = 18.0 mg/dL — below the
        // displayable range, so the clamp is what separates raw from adjusted here.
        let decoder = SyaiGlucoseDecoder()
        let raw = SyaiGlucoseDecoder.RawChannels(v0: 1000, v1: 1200, v2: 43200)
        let cal = Calibration(coefficients: Calibration.appDefaultCoefficientsFixture, k: 1.0, b: 0.0)
        let out = try decoder.glucose(from: raw, calibration: cal)
        XCTAssertTrue(out.rawGlucoseMgDL.isFinite)
        XCTAssertEqual(
            out.rawGlucoseMgDL,
            18.0,
            accuracy: 1E-9,
            "base 1.0 mmol/L × 18.0"
        )
        XCTAssertEqual(out.condition, .belowRange)
        XCTAssertEqual(out.adjustedGlucoseMgDL, SyaiGlucoseDecoder.minDisplayableMgDL)
    }

    func testCalibrationKAndBHaveNoEffect() throws {
        // K/B are not part of computing glucose: calibrationValueK/B's only
        // consumer anywhere in the app is a write TO the sensor, never read back.
        // Varying them here must not change the decoder's output at all.
        let decoder = SyaiGlucoseDecoder()
        let raw = SyaiGlucoseDecoder.RawChannels(v0: 1000, v1: 1200, v2: 43200)
        let identity = Calibration(coefficients: Calibration.appDefaultCoefficientsFixture, k: 1.0, b: 0.0)
        let nonIdentity = Calibration(coefficients: Calibration.appDefaultCoefficientsFixture, k: 3.5, b: -75)
        let outIdentity = try decoder.glucose(from: raw, calibration: identity)
        let outNonIdentity = try decoder.glucose(from: raw, calibration: nonIdentity)
        XCTAssertEqual(outIdentity.adjustedGlucoseMgDL, outNonIdentity.adjustedGlucoseMgDL, accuracy: 1E-9)
    }

    /// Coefficients that collapse the RPN to `round(product, 1)` regardless of
    /// the raw channels: R0=(V1+0)*0+0=0, so R1=V0 dv 0=0 (division-by-zero is
    /// special-cased to 0); R2=0*R1²+0*R1+0=0; R3=0*R2²+0*R2+product=product;
    /// R4=C10-(V2/86400)*0=1; final=round(product*1,1). `product` is the canonical
    /// mmol/L base — the decoder then converts ×18.0, so these tests pin
    /// the clamp/condition logic AND the conversion together.
    private static func constantRPNCoefficients(_ product: Double) -> [Double] {
        var c = [Double](repeating: 0, count: 14)
        c[9] = product // C9
        c[10] = 1 // C10
        // C12 must exceed every V2 these tests use (43200) so statement 5 stays
        // in the "V2 <= C12" branch (le/gt are ternary, and with C12 left at 0
        // the C13 branch — also 0 — would zero the whole result instead of
        // passing C10 through as the intended constant multiplier).
        c[12] = 172_800
        return c
    }

    func testAdjustedGlucoseClampsBelowRangeToLO() throws {
        let decoder = SyaiGlucoseDecoder()
        let raw = SyaiGlucoseDecoder.RawChannels(v0: 1000, v1: 1200, v2: 43200)
        // base 1.0 mmol/L → 18.0 mg/dL < 36 → LO.
        let cal = Calibration(coefficients: Self.constantRPNCoefficients(1.0), k: 1, b: 0)
        let out = try decoder.glucose(from: raw, calibration: cal)
        XCTAssertEqual(out.condition, .belowRange)
        XCTAssertEqual(out.adjustedGlucoseMgDL, SyaiGlucoseDecoder.minDisplayableMgDL)
    }

    func testAdjustedGlucoseClampsAboveRangeToHI() throws {
        let decoder = SyaiGlucoseDecoder()
        let raw = SyaiGlucoseDecoder.RawChannels(v0: 1000, v1: 1200, v2: 43200)
        // base 100 mmol/L → 1800 mg/dL > 450 → HI.
        let cal = Calibration(coefficients: Self.constantRPNCoefficients(100), k: 1, b: 0)
        let out = try decoder.glucose(from: raw, calibration: cal)
        XCTAssertEqual(out.condition, .aboveRange)
        XCTAssertEqual(out.adjustedGlucoseMgDL, SyaiGlucoseDecoder.maxDisplayableMgDL)
    }

    func testAdjustedGlucoseInRangeHasNoCondition() throws {
        let decoder = SyaiGlucoseDecoder()
        let raw = SyaiGlucoseDecoder.RawChannels(v0: 1000, v1: 1200, v2: 43200)
        // base 6.5 mmol/L → 117.0 mg/dL, in range.
        let cal = Calibration(coefficients: Self.constantRPNCoefficients(6.5), k: 1, b: 0)
        let out = try decoder.glucose(from: raw, calibration: cal)
        XCTAssertNil(out.condition)
        XCTAssertEqual(out.adjustedGlucoseMgDL, 117.0, accuracy: 1E-9)
    }

    func testNonFiniteRawChannelThrowsInsteadOfClamping() throws {
        // NaN fails both clamp comparisons, so without the guard it would be
        // forwarded as an ordinary in-range reading — and crash HKQuantity
        // downstream. A non-finite result must be a decode failure.
        let decoder = SyaiGlucoseDecoder()
        let raw = SyaiGlucoseDecoder.RawChannels(v0: .nan, v1: 1200, v2: 43200)
        let cal = Calibration(coefficients: Calibration.appDefaultCoefficientsFixture, k: 1, b: 0)
        XCTAssertThrowsError(try decoder.glucose(from: raw, calibration: cal)) { error in
            XCTAssertEqual(error as? SyaiGlucoseDecoder.DecodeError, .nonFiniteGlucose)
        }
    }

    func testWrongCoefficientCountThrowsInsteadOfTrapping() throws {
        let decoder = SyaiGlucoseDecoder()
        let raw = SyaiGlucoseDecoder.RawChannels(v0: 1000, v1: 1200, v2: 43200)
        let cal = Calibration(coefficients: Array(repeating: 0, count: 13), k: 1, b: 0)
        XCTAssertThrowsError(try decoder.glucose(from: raw, calibration: cal)) { error in
            XCTAssertEqual(error as? SyaiGlucoseDecoder.DecodeError, .wrongCoefficientCount(13))
        }
    }
}
