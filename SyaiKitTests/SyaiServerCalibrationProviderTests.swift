//
//  SyaiServerCalibrationProviderTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Covers `SyaiServerCalibrationProvider.ServerError.describeBusiness` — the
/// user-facing mapping for the lifecycle business codes
/// `validateDeviceByMacV2` can return.
final class SyaiServerCalibrationProviderTests: XCTestCase {
    /// The one-way-door codes must say so plainly — a user scanning an
    /// already-activated sensor needs "can't be paired again", not a code.
    func testLifecycleCodesGetSpecificMessages() {
        typealias E = SyaiServerCalibrationProvider.ServerError
        let already = E.business(code: "AppDevice_AlreadyUsed").description
        XCTAssertTrue(already.contains("already activated"), already)
        XCTAssertTrue(already.contains("can't be paired again"), already)

        let ended = E.business(code: "AppDevice_EndUsing").description
        XCTAssertTrue(ended.contains("session has ended"), ended)

        XCTAssertTrue(E.business(code: "AppDevice_NotExist").description.contains("doesn't know"))
        XCTAssertTrue(E.business(code: "AppDevice_TypeError").description.contains("isn't a supported"))
        XCTAssertTrue(E.business(code: "AppDevice_UserNuBind").description.contains("isn't bound"))
        XCTAssertTrue(E.business(code: "AppDevice_OutOfProduceTime").description.contains("shelf life"))
    }

    /// Unmapped `AppDevice_*` codes — and anything new the server adds — fail
    /// closed to a generic message that still names the code verbatim, so users
    /// see the raw code rather than a crash or a silently wrong specific message.
    func testUnknownCodeFallsBackNamingTheCode() {
        typealias E = SyaiServerCalibrationProvider.ServerError
        for code in [
            "AppDevice_Marked_To_Other_User",
            "AppDevice_Sale_EndUse",
            "AppDevice_Upgrade_Version",
            "AppDevice_Abnormal_EndUse",
            "AppDevice_Delay_Active_Failed",
            "AppDevice_Delay_Config_Existent",
            "SomethingNew_ServerAdded"
        ] {
            let text = E.business(code: code).description
            XCTAssertTrue(text.contains(code), "\(code) must be named in: \(text)")
        }
    }
}
