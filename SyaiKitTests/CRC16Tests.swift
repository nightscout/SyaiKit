//
//  CRC16Tests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

final class CRC16Tests: XCTestCase {
    func testModbusKnownAnswer() {
        // "123456789" → 0x4B37 is the canonical CRC16/Modbus check vector.
        let crc = CRC16.modbus(Array("123456789".utf8))
        XCTAssertEqual(crc, 0x4B37)
    }
}
