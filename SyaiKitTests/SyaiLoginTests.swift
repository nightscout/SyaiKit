//
//  SyaiLoginTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Validates the BYOA login crypto against **independently computed** golden values
/// (openssl AES-256-ECB + a reference MD5), using synthetic non-secret credentials.
/// The signature goldens are pinned to a fixed identity (`appName="Syai Tag"`,
/// `deviceId="Syai Tag:a:n:00…0"`), so they are byte-checkable here. `syaiTemplate`'s
/// live `deviceId` now comes from the Keychain (per-install, iOS-native
/// `Syai Tag:i:n:…`), which can't back a hardcoded golden — so this test builds an
/// otherwise-identical backend with the known deviceId. Only `appName`+`deviceId`
/// enter the signature preimage, so the platform letter is irrelevant to the formula
/// check.
final class SyaiLoginTests: XCTestCase {
    // Pinned deviceId (not `syaiTemplate.deviceId`, which is Keychain-random now).
    private let backend = SyaiBackend(
        baseURL: URL(string: "https://api.syai.com")!,
        pathPrefix: "cgm/security/app/server",
        productModel: "X1",
        credentials: .placeholder,
        appName: "Syai Tag",
        deviceId: "Syai Tag:a:n:00000000-0000-0000-0000-000000000000"
    )
    private let ts = "1783603561915"
    private let apiToken = "11111111-2222-3333-4444-555555555555"
    private let email = "user@example.com"
    private let password = "hunter2"

    func testApiTokenSignature() {
        // md5("Syai Tag" + deviceId + ts + "dy7234…")
        XCTAssertEqual(
            backend.signApiToken(timestamp: ts),
            "dec8ca8e04c6211894a571a12389e8da"
        )
    }

    func testLoginSignature() {
        // md5("Syai Tag" + deviceId + ts + apiToken + email + password + "dy7234…")
        XCTAssertEqual(
            backend.signLogin(
                timestamp: ts,
                apiToken: apiToken,
                email: email,
                password: password
            ),
            "9f44c35c6de49c8e5f7fc27374bf32be"
        )
    }

    func testEncryptInfoGolden() throws {
        // base64(AES-256-ECB/PKCS7({"email":"…","password":"…"})) — vs openssl.
        let info = try SyaiLoginCredentialProvider.encryptInfo(email: email, password: password)
        XCTAssertEqual(
            info,
            "ZwWdFJgWZnHaBqcxHSrOPPoKQvsTUoGaaSdjZVUjT/NQ1dvwZ9djXfwDQoXhaK41Va1Qi+S4o4WbfPfDyDzqig=="
        )
    }

    func testAESECBRoundTrip() throws {
        let aes = AESECB()
        let key = SyaiLoginCredentialProvider.aesKey // 32 bytes
        let plaintext = Data(#"{"email":"a@b.com","password":"p@ss w/ \"quotes\""}"#.utf8)
        let ct = try aes.encryptECB_PKCS7(plaintext, keyUTF8: key)
        let back = try aes.decryptECB_PKCS7(ct, keyUTF8: key)
        XCTAssertEqual(back, plaintext)
    }

    func testEncryptInfoEscapesSpecialCharacters() throws {
        // Backslash + quote must be JSON-escaped so the payload stays valid JSON.
        let info = try SyaiLoginCredentialProvider.encryptInfo(email: "a@b.com", password: #"a"b\c"#)
        let ct = Data(base64Encoded: info)!
        let plain = try AESECB().decryptECB_PKCS7(ct, keyUTF8: SyaiLoginCredentialProvider.aesKey)
        let obj = try JSONSerialization.jsonObject(with: plain) as? [String: String]
        XCTAssertEqual(obj?["email"], "a@b.com")
        XCTAssertEqual(obj?["password"], #"a"b\c"#)
    }
}
