//
//  SyaiCalibrationFixtures.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation
@testable import SyaiKit

/// Test-only fixture data for `Calibration`. Kept in the test target so a
/// product-default coefficient vector cannot be reached from app code: a sensor
/// without its real per-sensor coefficients must not be decoded, and a reachable
/// default makes that one accidental wire-up away from happening.
extension Calibration {
    /// The app's hardcoded default coefficient vector from `_getCalculateGlucose`.
    /// C12 = 172800 s (2 days) is an age threshold in the formula. Verbatim from
    /// the binary, kept for reference/tests only.
    static let appDefaultCoefficientsFixture: [Double] = [
        0.1, 0.5, 18.5, 0.0, -0.0018, 0.5337, -0.0163, 0.015,
        0.95, 1.0, 1.05, 0.025, 172_800.0, 1.0
    ]
}
