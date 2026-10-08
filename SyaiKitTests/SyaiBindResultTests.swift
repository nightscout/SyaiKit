//
//  SyaiBindResultTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Offline tests for `SyaiBindResult` parsing and the `markDeviceStatus` stub.
/// Everything here is driven by fabricated decrypted response bodies — nothing touches the network.
final class SyaiBindResultTests: XCTestCase {
    private func responseData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// A full bind response: the method fields parse through, and the
    /// (unused) `coefficients` array alongside them is tolerated, not fatal.
    func testParsesMethodBlobFromFullResponse() throws {
        let data = try responseData([
            "code": "OK",
            "data": [
                "cgmDeviceMethodVO": [
                    "methodId": 7,
                    "methodUpdateTime": 1_785_344_459_355,
                    "method": "QUJDQUJD", // encrypted RPN program, base64
                    "coefficients": ["0.1", "0.5"] // tolerated, never read
                ]
            ]
        ])
        let result = SyaiBindResult.parse(decryptedResponse: data)
        XCTAssertEqual(result.code, "OK")
        XCTAssertEqual(result.methodId, 7)
        XCTAssertEqual(result.methodUpdateTime, 1_785_344_459_355)
        XCTAssertEqual(result.methodBlob, "QUJDQUJD")
    }

    /// Older/slimmer responses: no `cgmDeviceMethodVO` (or a JSON null, as the
    /// app sees pre-activation) ⇒ nil method fields, code preserved, no throw.
    func testMissingMethodVOYieldsNilFields() throws {
        for dataValue: [String: Any] in [
            ["code": "OK", "data": ["someOtherField": 1]],
            ["code": "OK", "data": ["cgmDeviceMethodVO": NSNull()]],
            ["code": "OK"]
        ] {
            let result = SyaiBindResult.parse(decryptedResponse: try responseData(dataValue))
            XCTAssertEqual(result.code, "OK")
            XCTAssertNil(result.methodId)
            XCTAssertNil(result.methodUpdateTime)
            XCTAssertNil(result.methodBlob)
        }
    }

    /// A business rejection keeps its code and carries no method fields.
    func testBusinessCodePreserved() throws {
        let result = SyaiBindResult.parse(
            decryptedResponse: try responseData(["code": "AppDevice_EndUsing"])
        )
        XCTAssertEqual(result.code, "AppDevice_EndUsing")
        XCTAssertNil(result.methodBlob)
    }

    /// A non-JSON body degrades to the default (`code: "OK"`) instead of throwing —
    /// the bind's success path must not depend on the new parse.
    func testNonJSONDegradesToDefaultCode() {
        let result = SyaiBindResult.parse(decryptedResponse: Data("not json".utf8))
        XCTAssertEqual(result, SyaiBindResult(code: "OK"))
    }

    /// On a logged-out (template) backend the call throws
    /// `TransportError.notConfigured` before any network work — the pairing
    /// bracket relies on this being a cheap, tolerable throw.
    func testMarkDeviceStatusThrowsWhenNotConfigured() async {
        let client = SyaiEnvelopedClient(backend: .syaiTemplate)
        do {
            try await client.markDeviceStatus(mac: "AABBCCDDEEFF", inProgress: true)
            XCTFail("expected TransportError.notConfigured")
        } catch let error as SyaiEnvelopedClient.TransportError {
            guard case .notConfigured = error else {
                return XCTFail("wrong TransportError: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
