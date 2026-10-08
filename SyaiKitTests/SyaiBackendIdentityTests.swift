//
//  SyaiBackendIdentityTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Guards the network identity SyaiKit presents to Syai's backend:
/// `ua: ios` and `deviceModel` as a real "iPhone15,2"-style handset id.
/// The one place this can silently regress is the simulator, where `hw.machine`
/// reports the host Mac's arch — an instant fingerprint on a live run.
/// `deviceHardwareModel` resolves `SIMULATOR_MODEL_IDENTIFIER` there instead;
/// this test pins that behavior.
final class SyaiBackendIdentityTests: XCTestCase {
    /// `deviceModel` must always look like a real handset, never the simulator's or
    /// host's CPU arch.
    func testDeviceHardwareModelIsNeverTheHostArch() {
        let model = SyaiBackend.deviceHardwareModel
        XCTAssertFalse(model.isEmpty, "deviceModel must never be empty")
        for leak in ["arm64", "x86_64", "i386", "Simulator", "unknown"] {
            XCTAssertNotEqual(
                model,
                leak,
                "deviceModel leaked the host/simulator arch: \(model)"
            )
        }
        // Real Apple handset identifiers are "<Family><major>,<minor>", e.g.
        // "iPhone15,2" / "iPad13,1". Assert that shape so an arch-style value
        // ("arm64") or a bare marketing name can't slip through.
        let handsetPattern = "^[A-Za-z]+[0-9]+,[0-9]+$"
        XCTAssertNotNil(
            model.range(of: handsetPattern, options: .regularExpression),
            "deviceModel \(model) does not look like a real Apple device id"
        )
    }

    /// The template's user agent is hardcoded to `"ios"`; sending "android"
    /// would give us away.
    func testUserAgentIsIOS() {
        XCTAssertEqual(SyaiBackend.syaiTemplate.userAgent, "ios")
    }

    func testTemplateDeviceModelMatchesHardwareModel() {
        XCTAssertEqual(SyaiBackend.syaiTemplate.deviceModel, SyaiBackend.deviceHardwareModel)
    }
}
