//
//  SyaiApplicatorCodeTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

final class SyaiApplicatorCodeTests: XCTestCase {
    func testPlainMACIsNormalizedToDiscoveryForm() {
        XCTAssertEqual(SyaiApplicatorCode.mac(fromPayload: "AABBCCDDEEFF"), "AABBCCDDEEFF")
        XCTAssertEqual(SyaiApplicatorCode.mac(fromPayload: "aabbccddeeff\n"), "AABBCCDDEEFF")
        XCTAssertEqual(SyaiApplicatorCode.mac(fromPayload: "AA:BB:CC:DD:EE:FF"), "AABBCCDDEEFF")
        XCTAssertEqual(SyaiApplicatorCode.mac(fromPayload: "AA-BB-CC-DD-EE-FF"), "AABBCCDDEEFF")
    }

    func testAnythingElseIsRejected() {
        XCTAssertNil(SyaiApplicatorCode.mac(fromPayload: ""))
        XCTAssertNil(SyaiApplicatorCode.mac(fromPayload: "AABBCCDDEE"))
        XCTAssertNil(SyaiApplicatorCode.mac(fromPayload: "AABBCCDDEEFF00"))
        XCTAssertNil(SyaiApplicatorCode.mac(fromPayload: "AABBCCDDEEFG"))
        XCTAssertNil(SyaiApplicatorCode.mac(fromPayload: "https://example.com/AABBCCDDEEFF"))
    }
}
