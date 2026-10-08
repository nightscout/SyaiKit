//
//  Calibration.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

public struct Calibration: Equatable, Sendable {
    /// C0..C13. Must be exactly 14 entries.
    public let coefficients: [Double]

    // Provided by Syai but not used anywhere and so far observed to be K=B=1.
    public let k: Double
    public let b: Double

    public init(coefficients: [Double], k: Double, b: Double) {
        self.coefficients = coefficients
        self.k = k
        self.b = b
    }
}
