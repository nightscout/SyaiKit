//
//  SyaiCoefficientDecipherTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Validates the coefficient decipher pipeline end-to-end. Uses a synthetic
/// account key (the real `glucoseSecretKey` is a secret). The AES-256-ECB math
/// itself is proven separately (Python reference over the real ciphertext).
final class SyaiCoefficientDecipherTests: XCTestCase {
    /// The deciphered CSV plaintext observed on both real sensors.
    private let realCSV = "0.1,0.5,18.5,0.0000,-0.0014,0.5212,-0.2606,0.015,0.95,0.8,1.1,0.05,172800,1"
    private let expectedCoefficients: [Double] =
        [0.1, 0.5, 18.5, 0.0, -0.0014, 0.5212, -0.2606, 0.015, 0.95, 0.8, 1.1, 0.05, 172_800, 1.0]

    func testKeyDerivationFormat() {
        // key = glucoseSecretKey + last10(coeffUpdateTime) + last6(mac).
        let key = SyaiCoefficientDecipher.deriveKey(
            glucoseSecretKey: "SECRETKEY0000000", coeffUpdateTime: 1_770_346_120_828, mac: "001122334455"
        )
        XCTAssertEqual(key, "SECRETKEY00000000346120828334455")
        XCTAssertEqual(key.count, 32) // 16 + 10 + 6 → AES-256
    }

    func testParseRealCSV() throws {
        let coeffs = try SyaiCoefficientDecipher.parseCoefficients(realCSV)
        XCTAssertEqual(coeffs.count, 14)
        for (got, want) in zip(coeffs, expectedCoefficients) {
            XCTAssertEqual(got, want, accuracy: 1E-9)
        }
        XCTAssertEqual(coeffs[12], 172_800) // C12 = 2-day age threshold
    }

    func testParseRejectsWrongCount() {
        XCTAssertThrowsError(try SyaiCoefficientDecipher.parseCoefficients("1,2,3"))
    }

    func testParseRejectsNonNumeric() {
        let bad = "0.1,0.5,18.5,x,-0.0014,0.5212,-0.2606,0.015,0.95,0.8,1.1,0.05,172800,1"
        XCTAssertThrowsError(try SyaiCoefficientDecipher.parseCoefficients(bad))
    }

    func testFullDecipherPipelineRoundTrip() throws {
        let coeffUpdateTime: Int64 = 1_770_346_120_828
        let mac = "001122334455"
        let glucoseSecretKey = "SECRETKEY0000000"
        let key = SyaiCoefficientDecipher.deriveKey(
            glucoseSecretKey: glucoseSecretKey, coeffUpdateTime: coeffUpdateTime, mac: mac
        )
        let ciphertext = try AESECB().encryptECB_PKCS7(Data(realCSV.utf8), keyUTF8: key)
        let coeffs = try SyaiCoefficientDecipher.decipher(
            base64Coefficient: ciphertext.base64EncodedString(),
            coeffUpdateTime: coeffUpdateTime,
            mac: mac,
            glucoseSecretKey: glucoseSecretKey
        )
        XCTAssertEqual(coeffs, expectedCoefficients)
    }
}
