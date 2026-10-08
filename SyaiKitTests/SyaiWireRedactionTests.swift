//
//  SyaiWireRedactionTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// The wire logger writes decrypted request/response plaintext to the
/// user-exportable log file. These tests pin the redaction contract: no secret,
/// token, or persistent identifier from the real endpoint shapes may survive.
final class SyaiWireRedactionTests: XCTestCase {
    private func redacted(_ json: String) -> String {
        SyaiEnvelopedClient.redactedJSON(Data(json.utf8))
    }

    func testLoginRequestRedactsEncryptInfoApiTokenAndSignature() {
        let out = redacted("""
        {"encryptInfo":"AESBLOBOFTHEPASSWORD","apiToken":"APITOKENVALUE","signature":"md5overpassword0123456789"}
        """)
        XCTAssertFalse(out.contains("AESBLOBOFTHEPASSWORD"))
        XCTAssertFalse(out.contains("APITOKENVALUE"))
        XCTAssertFalse(out.contains("md5overpassword0123456789"))
    }

    func testSensorMACKeepsOnlyLastTwoBytes() {
        let out = redacted("""
        {"mac":"A1B2C3D4E5F6","deviceMac":"A1:B2:C3:D4:E5:F6"}
        """)
        XCTAssertFalse(out.contains("A1B2C3"))
        XCTAssertFalse(out.contains("A1:B2"))
        XCTAssertTrue(out.contains("E5F6"))
    }

    func testLoginResponseRedactsTokensSecretKeyUserIdAndEmail() {
        let out = redacted("""
        {"code":"OK","data":{"glucoseSecretKey":"GLUCOSESECRET123","userId":"12345678",\
        "mail":"abc@example.com","jwtToken":{"accessToken":"ACCESSTOKENVALUE","refreshToken":"REFRESHTOKENVALUE"}}}
        """)
        XCTAssertFalse(out.contains("GLUCOSESECRET123"))
        XCTAssertFalse(out.contains("12345678"))
        XCTAssertFalse(out.contains("ACCESSTOKENVALUE"))
        XCTAssertFalse(out.contains("REFRESHTOKENVALUE"))
        XCTAssertFalse(out.contains("abc@"))
        XCTAssertTrue(out.contains("@example.com"))
    }

    func testValidateDeviceResponseRedactsKeyACoefficientsAndSerial() {
        let out = redacted("""
        {"code":"OK","data":{"keyA":"KEYABASE64BLOB","coefficient":"1,2,3,4,5,6,7,8,9,10,11,12,13,14",\
        "serialNo":"SERIALNUMBER","batchNo":"BATCHNO","produceTime":1700000000000,"mac":"AABBCCDDEEFF"}}
        """)
        XCTAssertFalse(out.contains("KEYABASE64BLOB"))
        XCTAssertFalse(out.contains("1,2,3,4,5,6,7,8,9,10,11,12,13,14"))
        XCTAssertFalse(out.contains("SERIALNUMBER"))
        XCTAssertFalse(out.contains("BATCHNO"))
        // MAC and produceTime are not secrets on their own; keep them for debugging.
        XCTAssertTrue(out.contains("AABBCCDDEEFF"))
    }

    func testNumericUserIdIsRedacted() {
        let out = redacted("""
        {"code":"OK","data":{"userId":12345678,"customerId":12345678}}
        """)
        XCTAssertFalse(out.contains("12345678"))
    }

    func testShortOpaqueTokenIsNeverLoggedInFull() {
        let out = redacted("""
        {"data":{"accessToken":"TOK12345"}}
        """)
        XCTAssertFalse(out.contains("TOK12345"))
    }

    func testExchangeKeyHandshakeRedactsSignaturesAndSecretId() {
        let out = redacted("""
        {"code":"OK","data":{"secretId":"SECRETIDHEX","serverSignature":"SERVERSIGHEX",\
        "serverPubKeyX":"PUBKEYX","iv":"IVVALUE","ciphertext":"CIPHERTEXTBLOB"}}
        """)
        XCTAssertFalse(out.contains("SECRETIDHEX"))
        XCTAssertFalse(out.contains("SERVERSIGHEX"))
        // Ephemeral public keys and envelope ciphertext are not secret.
        XCTAssertTrue(out.contains("PUBKEYX"))
        XCTAssertTrue(out.contains("CIPHERTEXTBLOB"))
    }

    func testHeadersRedactCredentialsAndPersistentIdentifiers() {
        var request = URLRequest(url: URL(string: "https://example.com/x")!)
        request.setValue("FULLACCESSTOKENJWT", forHTTPHeaderField: "Authorization")
        request.setValue("FULLREFRESHTOKEN", forHTTPHeaderField: "refreshToken")
        request.setValue("12345678", forHTTPHeaderField: "customerId")
        request.setValue("Syai Tag:i:n:11111111-1111-1111-1111-111111111111", forHTTPHeaderField: "deviceId")
        request.setValue("Syai Tag:i:n:22222222-2222-2222-2222-222222222222", forHTTPHeaderField: "cipherUserId")
        request.setValue("SECRETIDHEX", forHTTPHeaderField: "cipherSecretId")
        request.setValue("33333333-3333-3333-3333-333333333333", forHTTPHeaderField: "traceId")

        let out = SyaiEnvelopedClient.redactedHeaders(request)
        XCTAssertFalse(out.contains("FULLACCESSTOKENJWT"))
        XCTAssertFalse(out.contains("FULLREFRESHTOKEN"))
        XCTAssertFalse(out.contains("12345678"))
        XCTAssertFalse(out.contains("11111111-1111-1111-1111-111111111111"))
        XCTAssertFalse(out.contains("22222222-2222-2222-2222-222222222222"))
        XCTAssertFalse(out.contains("SECRETIDHEX"))
        // Per-request correlation IDs stay.
        XCTAssertTrue(out.contains("33333333-3333-3333-3333-333333333333"))
    }
}
