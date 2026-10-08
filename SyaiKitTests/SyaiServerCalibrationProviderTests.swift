//
//  SyaiServerCalibrationProviderTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Covers the server side of activation: the user-facing mapping for the
/// lifecycle business codes `validateDeviceByMacV3` can return, and the
/// parsers for the V3 validate answer, the `cgmAuth/verify` answer and the
/// bound sensor record. Payloads are synthetic, shaped after the official
/// app's models (`CgmBindDeviceModel`, `CgmAuthServiceModel`).
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

    // MARK: parsers

    private let mac = "AABBCCDDEEFF"
    private let gsk = "SECRETKEY0000000"
    private let produceTime: Int64 = 1_765_756_800_000
    private let coeffUpdateTime: Int64 = 1_770_346_120_828
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

    private func deviceBody() throws -> [String: Any] {
        [
            "mac": mac,
            "deviceType": "cgm",
            "deviceVersion": "V1.7.SH22601.3",
            "produceTime": produceTime,
            "activeExpireTime": 1_209_600_000,
            "preheatPeriodTime": 1_800_000,
            "keyA": try encrypt(String(repeating: "0f", count: 96), time: produceTime),
            "coefficient": try encrypt(batchCSV, time: coeffUpdateTime),
            "coeffUpdateTime": coeffUpdateTime
        ]
    }

    func testValidationNeedsOnlyTheCode() throws {
        let validation = try SyaiServerCalibrationProvider.parseValidation(
            response(["mac": mac, "deviceVersion": "V1.7.SH22601.3"]), mac: mac, glucoseSecretKey: gsk
        )
        XCTAssertEqual(validation.deviceVersion, "V1.7.SH22601.3")
        XCTAssertNil(validation.coefficients)
    }

    func testValidationKeepsCoefficientsWhenPresent() throws {
        let validation = try SyaiServerCalibrationProvider.parseValidation(
            response(deviceBody()), mac: mac, glucoseSecretKey: gsk
        )
        XCTAssertEqual(validation.coefficients?[5], 0.5212)
    }

    func testValidationSurfacesBusinessCode() {
        XCTAssertThrowsError(try SyaiServerCalibrationProvider.parseValidation(
            response(nil, code: "AppDevice_AlreadyUsed"), mac: mac, glucoseSecretKey: gsk
        )) { error in
            guard case let .business(code) = error as? SyaiServerCalibrationProvider.ServerError else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(code, "AppDevice_AlreadyUsed")
        }
    }

    func testRemoteActivationMapsEveryField() throws {
        let activation = try SyaiServerCalibrationProvider.parseRemoteActivation(
            response(["mac": mac, "auth": "0A0B", "shaInfo": "0c0d", "cf": "01", "d": "02", "c": "03", "kb": "FF"]),
            mac: mac
        )
        XCTAssertEqual(activation.authHost, Data([0x0A, 0x0B]))
        XCTAssertEqual(activation.authFlag, Data([0x0C, 0x0D]))
        XCTAssertEqual(activation.coefficientFrame, Data([0x01]))
        XCTAssertEqual(activation.durationFrame, Data([0x02]))
        XCTAssertEqual(activation.activateFrame, Data([0x03]))
    }

    func testRemoteActivationRefusesAnotherSensorsAnswer() {
        XCTAssertThrowsError(try SyaiServerCalibrationProvider.parseRemoteActivation(
            response(["mac": "112233445566", "auth": "00", "shaInfo": "00"]), mac: mac
        ))
    }

    func testRemoteActivationNeedsTheAuthAnswer() {
        XCTAssertThrowsError(try SyaiServerCalibrationProvider.parseRemoteActivation(
            response(["mac": mac, "shaInfo": "00"]), mac: mac
        ))
        XCTAssertThrowsError(try SyaiServerCalibrationProvider.parseRemoteActivation(
            response(["mac": mac, "auth": "zz", "shaInfo": "00"]), mac: mac
        ), "non-hex must not be written to the sensor")
    }

    func testBoundRecordYieldsItsOwnCoefficientsAndKeys() throws {
        let provisioning = try SyaiServerCalibrationProvider.provisioning(
            fromDeviceBody: deviceBody(), mac: mac, glucoseSecretKey: gsk
        )
        XCTAssertEqual(provisioning.deviceInfo.coefficients[5], 0.5212)
        XCTAssertEqual(provisioning.keyGroup.raw, Data(repeating: 0x0F, count: 96))
        XCTAssertEqual(provisioning.deviceInfo.activeDuration, 1_209_600)
        XCTAssertEqual(provisioning.deviceInfo.preheatDuration, 1_800)
    }

    /// No default fallback: a record missing anything the decode depends on is refused.
    func testIncompleteBoundRecordIsRefused() throws {
        for key in ["coefficient", "coeffUpdateTime", "keyA", "activeExpireTime", "preheatPeriodTime"] {
            var body = try deviceBody()
            body.removeValue(forKey: key)
            XCTAssertThrowsError(
                try SyaiServerCalibrationProvider.provisioning(fromDeviceBody: body, mac: mac, glucoseSecretKey: gsk),
                "missing \(key) must refuse"
            )
        }
        var other = try deviceBody()
        other["mac"] = "112233445566"
        XCTAssertThrowsError(
            try SyaiServerCalibrationProvider.provisioning(fromDeviceBody: other, mac: mac, glucoseSecretKey: gsk)
        )
    }

    func testCgmAuthVerifySignatureRecipe() {
        let backend = SyaiBackend.syaiTemplate
        let sign = backend.signCgmAuthVerify(
            mac: mac, authDevHex: "AB", authFlagHex: "CD", timestamp: "1791436947086"
        )
        XCTAssertEqual(
            sign,
            backend.md5Hex(backend.appName + backend.deviceId + mac + "AB" + "CD" + "1791436947086" + SyaiBackend.deviceSignKey)
        )
    }

    func testChallengeHexIsUppercase() {
        XCTAssertEqual(SyaiEnvelopedClient.upperHex(Data([0x0A, 0xFF, 0x00])), "0AFF00")
    }
}
