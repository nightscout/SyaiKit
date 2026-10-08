//
//  SyaiAccountSessionTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Covers the BYOA account session: Codable round-trip (as stored in the Keychain),
/// refresh-token expiry decoding from the JWT, and the derived backend.
final class SyaiAccountSessionTests: XCTestCase {
    /// Build a minimal unsigned JWT with the given claims (payload is all we read).
    private func makeJWT(_ claims: [String: Any]) -> String {
        func b64url(_ d: Data) -> String {
            d.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
        let payload = b64url(try! JSONSerialization.data(withJSONObject: claims))
        return "\(header).\(payload).signature"
    }

    func testCodableRoundTrip() throws {
        let session = SyaiAccountSession(
            email: "user@example.com",
            refreshToken: "r.token.value",
            accessToken: "a.token.value",
            glucoseSecretKey: "SECRETKEY0000000",
            userId: "cust-123"
        )
        let data = try JSONEncoder().encode(session)
        let back = try JSONDecoder().decode(SyaiAccountSession.self, from: data)
        XCTAssertEqual(back, session)
    }

    func testRefreshTokenExpiryDecoding() {
        let exp = Date().addingTimeInterval(265 * 86400) // ~265 days out
        let jwt = makeJWT(["sub": "cust-1", "exp": Int(exp.timeIntervalSince1970)])
        let session = SyaiAccountSession(email: "u@e.com", refreshToken: jwt)
        let decoded = session.refreshTokenExpiry
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded!.timeIntervalSince1970, exp.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(session.hasValidSession)
    }

    func testExpiredSessionIsInvalid() {
        let past = Date().addingTimeInterval(-3600)
        let jwt = makeJWT(["sub": "cust-1", "exp": Int(past.timeIntervalSince1970)])
        let session = SyaiAccountSession(email: "u@e.com", refreshToken: jwt)
        XCTAssertFalse(session.hasValidSession)
    }

    func testDerivedBackendCarriesCredentialsAndSecretKey() {
        let jwt = makeJWT(["sub": "cust-9", "exp": Int(Date().addingTimeInterval(1000).timeIntervalSince1970)])
        let session = SyaiAccountSession(
            email: "u@e.com",
            refreshToken: jwt,
            glucoseSecretKey: "gsk-abc",
            userId: "cust-9"
        )
        let backend = session.backend()
        XCTAssertEqual(backend.credentials.refreshToken, jwt)
        XCTAssertEqual(backend.glucoseSecretKey, "gsk-abc")
        XCTAssertEqual(backend.userId, "cust-9") // from the JWT `sub` claim
    }

    func testWithRotatedCredentialsKeepsEmailAndUserId() {
        let original = SyaiAccountSession(
            email: "keep@e.com",
            refreshToken: "r0",
            accessToken: "a0",
            glucoseSecretKey: "gsk0",
            userId: "cust-1"
        )
        let rotated = original.withRotatedCredentials(
            SyaiCredentials(refreshToken: "r1", accessToken: "a1"), glucoseSecretKey: "gsk1"
        )
        XCTAssertEqual(rotated.email, "keep@e.com")
        XCTAssertEqual(rotated.userId, "cust-1")
        XCTAssertEqual(rotated.refreshToken, "r1")
        XCTAssertEqual(rotated.accessToken, "a1")
        XCTAssertEqual(rotated.glucoseSecretKey, "gsk1")
    }

    func testWithRotatedCredentialsFallsBackWhenRefreshEmpty() {
        let original = SyaiAccountSession(email: "u@e.com", refreshToken: "r0", userId: "c1")
        // An empty rotated refresh token must NOT wipe the stored one.
        let rotated = original.withRotatedCredentials(SyaiCredentials(refreshToken: "", accessToken: "a1"))
        XCTAssertEqual(rotated.refreshToken, "r0")
        XCTAssertEqual(rotated.accessToken, "a1")
    }

    func testCodableRoundTripWithPassword() throws {
        let session = SyaiAccountSession(
            email: "user@example.com", refreshToken: "r.token.value",
            userId: "cust-123", password: "s3cret"
        )
        let data = try JSONEncoder().encode(session)
        let back = try JSONDecoder().decode(SyaiAccountSession.self, from: data)
        XCTAssertEqual(back, session)
        XCTAssertEqual(back.password, "s3cret")
    }

    func testLegacyKeychainJSONWithoutPasswordDecodes() throws {
        // Sessions persisted BEFORE the password field existed must still decode
        // (optional fields decode via decodeIfPresent).
        let legacy = Data(#"{"email":"u@e.com","refreshToken":"r0"}"#.utf8)
        let session = try JSONDecoder().decode(SyaiAccountSession.self, from: legacy)
        XCTAssertEqual(session.email, "u@e.com")
        XCTAssertNil(session.password)
    }

    func testWithRotatedCredentialsPreservesPassword() {
        let original = SyaiAccountSession(email: "u@e.com", refreshToken: "r0", password: "pw")
        let rotated = original.withRotatedCredentials(SyaiCredentials(refreshToken: "r1"))
        XCTAssertEqual(rotated.refreshToken, "r1")
        XCTAssertEqual(rotated.password, "pw")
    }

    func testTransportErrorAuthFailureClassification() {
        let auth: [SyaiEnvelopedClient.TransportError] = [
            .http(401, body: ""), .http(403, body: ""), .sessionRejected("TOKEN_INVALID")
        ]
        for e in auth { XCTAssertTrue(e.isAuthFailure, "\(e)") }
        let notAuth: [SyaiEnvelopedClient.TransportError] = [
            .notConfigured, .http(500, body: ""), .http(429, body: ""),
            .http(200, body: ""), .badResponse("nope")
        ]
        for e in notAuth { XCTAssertFalse(e.isAuthFailure, "\(e)") }
    }

    func testInstallDeviceIdFormat() {
        // iOS-native shape: "Syai Tag:i:n:<uuid>" with a v3 version nibble + 10xx variant.
        for _ in 0 ..< 100 {
            let id = SyaiKeychain.makeInstallDeviceId()
            XCTAssertTrue(id.hasPrefix("Syai Tag:i:n:"), id)
            let uuid = String(id.dropFirst("Syai Tag:i:n:".count))
            let groups = uuid.split(separator: "-")
            XCTAssertEqual(groups.map(\.count), [8, 4, 4, 4, 12], uuid)
            XCTAssertTrue(uuid.allSatisfy { $0.isHexDigit || $0 == "-" }, uuid)
            XCTAssertEqual(groups[2].first, "3", "version nibble must be v3: \(uuid)")
            XCTAssertTrue(
                ["8", "9", "a", "b"].contains(groups[3].first?.lowercased() ?? ""),
                "variant must be 10xx: \(uuid)"
            )
        }
        XCTAssertNotEqual(SyaiKeychain.makeInstallDeviceId(), SyaiKeychain.makeInstallDeviceId())
    }
}
