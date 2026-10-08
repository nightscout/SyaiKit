//
//  CGMManager+Telemetry.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

public extension SyaiCGMManager {
    var telemetryTier: SyaiTelemetryTier { state.telemetryTier }

    @MainActor func setTelemetryTier(_ tier: SyaiTelemetryTier) {
        var updated = state
        updated.telemetryTier = tier
        setState(updated)
        guard let service = telemetryService else { return }
        Task { await service.applyTierChange(tier) }
    }

    @MainActor func markTelemetryDisclosureShown() {
        var updated = state
        updated.telemetryDisclosureShown = true
        setState(updated)
    }
}
