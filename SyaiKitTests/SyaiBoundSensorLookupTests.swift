//
//  SyaiBoundSensorLookupTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Synthetic `getBindDevice` payloads shaped after `CgmBindDeviceModel.fromJson`
/// in the official app (field names and types from the disassembly). Not a
/// captured response: the first real one should be checked against these.
final class SyaiBoundSensorLookupTests: XCTestCase {
    private let mac = "AABBCCDDEEFF"
    private let gsk = "SECRETKEY0000000"
    private let produceTime: Int64 = 1_765_756_800_000
    private let coeffUpdateTime: Int64 = 1_770_346_120_828
    private let activeTime: Int64 = 1_785_496_001_466
    private let batchCSV = "0.1,0.5,18.5,0.0000,-0.0014,0.5212,-0.2606,0.015,0.95,0.8,1.1,0.05,172800,1"

    private func encrypt(_ plaintext: String, time: Int64) throws -> String {
        let key = SyaiCoefficientDecipher.deriveKey(glucoseSecretKey: gsk, coeffUpdateTime: time, mac: mac)
        return try AESECB().encryptECB_PKCS7(Data(plaintext.utf8), keyUTF8: key).base64EncodedString()
    }

    private func response(_ data: [String: Any]?, code: String = "OK") throws -> Data {
        var root: [String: Any] = ["code": code]
        root["data"] = data
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func boundBody(includeCoefficient: Bool) throws -> [String: Any] {
        var body: [String: Any] = [
            "id": 11_994_938,
            "mac": mac,
            "serialNo": mac,
            "deviceType": "cgm",
            "deviceVersion": "V1.6.SH22523.3",
            "produceTime": produceTime,
            "activeTime": activeTime,
            "activeExpireTime": 1_209_600_000,
            "preheatPeriodTime": 1_800_000,
            "keyA": try encrypt(String(repeating: "0f", count: 96), time: produceTime),
            "state": 3,
            "calibrationValueK": 1.0,
            "calibrationValueB": 1.0
        ]
        if includeCoefficient {
            body["coefficient"] = try encrypt(batchCSV, time: coeffUpdateTime)
            body["coeffUpdateTime"] = coeffUpdateTime
        }
        return body
    }

    func testNothingBoundIsNil() throws {
        XCTAssertNil(try SyaiBoundSensorLookup.boundDeviceBody(response(nil)))
        XCTAssertNil(try SyaiBoundSensorLookup.boundDeviceBody(response([:])))
    }

    func testNonOKCodeIsAnError() {
        XCTAssertThrowsError(try SyaiBoundSensorLookup.boundDeviceBody(response(nil, code: "AuthFailed_TokenInvalid")))
    }

    func testBoundRecordParsesWithItsOwnCoefficients() throws {
        let body = try XCTUnwrap(SyaiBoundSensorLookup.boundDeviceBody(response(boundBody(includeCoefficient: true))))
        XCTAssertFalse(SyaiBoundSensorLookup.missingForAdoption(body))
        let sensor = try SyaiBoundSensorLookup.parse(body: body, glucoseSecretKey: gsk)

        XCTAssertEqual(sensor.mac, mac)
        XCTAssertEqual(sensor.deviceInfo.coefficients[5], 0.5212)
        XCTAssertEqual(sensor.keyGroup.raw, Data(repeating: 0x0F, count: 96))
        XCTAssertEqual(sensor.deviceInfo.activeDuration, 1_209_600)
        XCTAssertEqual(sensor.deviceInfo.preheatDuration, 1_800)
        XCTAssertEqual(sensor.activatedAt, Date(timeIntervalSince1970: Double(activeTime) / 1000))
    }

    func testMissingCoefficientsRefusesTakeover() throws {
        let body = try boundBody(includeCoefficient: false)
        XCTAssertThrowsError(try SyaiBoundSensorLookup.parse(body: body, glucoseSecretKey: gsk)) { error in
            guard case SyaiBoundSensorLookup.LookupError.noCalibration = error else {
                return XCTFail("expected noCalibration, got \(error)")
            }
        }
    }

    func testUndecipherableCoefficientsRefuseTakeover() throws {
        var body = try boundBody(includeCoefficient: true)
        body["coeffUpdateTime"] = coeffUpdateTime + 1 // wrong KDF input, so the blob won't decrypt
        XCTAssertThrowsError(try SyaiBoundSensorLookup.parse(body: body, glucoseSecretKey: gsk))
    }

    func testMissingKeyGroupAsksForAuthInfo() throws {
        var body = try boundBody(includeCoefficient: false)
        body["keyA"] = nil
        XCTAssertTrue(SyaiBoundSensorLookup.missingForAdoption(body))
        XCTAssertThrowsError(try SyaiBoundSensorLookup.parse(body: body, glucoseSecretKey: gsk))
    }

    func testAuthInfoFillsKeysWithoutErasingBoundValues() throws {
        var bound = try boundBody(includeCoefficient: true)
        bound["keyA"] = nil
        bound["activeExpireTime"] = nil
        let keyA = try encrypt(String(repeating: "0f", count: 96), time: produceTime)
        let authInfo = try response([
            "id": 11_994_938, "mac": mac, "keyA": keyA, "produceTime": produceTime,
            "activeExpireTime": 1_814_400_000, "preheatPeriodTime": 1_800_000,
            "activeTime": NSNull()
        ])
        let merged = SyaiBoundSensorLookup.merged(bound: bound, authInfo: authInfo)
        XCTAssertFalse(SyaiBoundSensorLookup.missingForAdoption(merged))

        let sensor = try SyaiBoundSensorLookup.parse(body: merged, glucoseSecretKey: gsk)
        XCTAssertEqual(sensor.deviceInfo.activeDuration, 1_814_400)
        XCTAssertEqual(sensor.activatedAt, Date(timeIntervalSince1970: Double(activeTime) / 1000))
        XCTAssertEqual(sensor.deviceInfo.deviceVersion, "V1.6.SH22523.3")
    }
}
