//
//  HKUnit.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import HealthKit

// LoopKit's HKUnit extensions are internal-scoped, so each plugin redeclares
// the units it needs.
extension HKUnit {
    static let milligramsPerDeciliter = HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
    static let milligramsPerDeciliterPerMinute: HKUnit = milligramsPerDeciliter.unitDivided(by: .minute())
}
