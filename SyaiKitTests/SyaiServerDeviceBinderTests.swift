//
//  SyaiServerDeviceBinderTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import CryptoKit
@testable import SyaiKit
import XCTest

/// Covers the offline branches of the account-backed device binder. The live
/// `deviceBind/composite/bind` request is LIVE-VERIFY (no request to api.syai.com
/// has been made yet), so these tests exercise only the two paths that short-
/// circuit *before* any network call: the not-configured guard and the empty
/// `deviceVersion` skip.
final class SyaiServerDeviceBinderTests: XCTestCase {
    private func deviceInfo(deviceVersion: String) -> DeviceInfo {
        DeviceInfo(
            mac: "665544332211",
            serialNo: "", batchNo: "", deviceType: "cgm",
            deviceVersion: deviceVersion,
            coefficients: Array(repeating: 0, count: 14),
            k: 1, b: 0,
            produceTime: Date(timeIntervalSince1970: 0),
            activeDuration: 14 * 24 * 3600, preheatDuration: 1800
        )
    }

    /// A logged-out (template) backend has no refresh token, so bind must throw
    /// `notConfigured` without touching the network.
    func testBindThrowsWhenNotConfigured() async {
        let binder = SyaiServerDeviceBinder(backend: .syaiTemplate)
        do {
            _ = try await binder.bind(
                mac: "665544332211",
                deviceInfo: deviceInfo(deviceVersion: "X1"),
                activatedAt: Date()
            )
            XCTFail("expected notConfigured to throw")
        } catch let error as SyaiServerDeviceBinder.BindError {
            guard case .notConfigured = error else { return XCTFail("wrong BindError: \(error)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A configured session but an empty `deviceVersion` (the server would reject it
    /// as HardwareVersion_NotNull) returns the skip sentinel and fires no request.
    func testBindSkipsWhenDeviceVersionEmpty() async throws {
        let configured = SyaiBackend.syaiTemplate.withCredentials(
            SyaiCredentials(refreshToken: "r.token", accessToken: "a.token")
        )
        let binder = SyaiServerDeviceBinder(backend: configured)
        let result = try await binder.bind(
            mac: "665544332211",
            deviceInfo: deviceInfo(deviceVersion: ""),
            activatedAt: Date()
        )
        XCTAssertEqual(result.code, "SKIPPED_NO_VERSION")
        XCTAssertNil(result.methodBlob)
    }

    /// `markDeviceStatus` on a logged-out (template) backend throws
    /// `notConfigured` before delegating to the client — the not-configured
    /// case stays distinguishable.
    func testMarkDeviceStatusThrowsWhenNotConfigured() async {
        let binder = SyaiServerDeviceBinder(backend: .syaiTemplate)
        do {
            try await binder.markDeviceStatus(mac: "665544332211", inProgress: true)
            XCTFail("expected notConfigured to throw")
        } catch let error as SyaiServerDeviceBinder.BindError {
            guard case .notConfigured = error else { return XCTFail("wrong BindError: \(error)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// On a configured backend the call now fires for real (body pinned by
    /// static RE 2026-08-03: `{"mac","state":1|0,"duration":5}` in the standard
    /// cipher envelope). Driven through a stubbed `URLProtocol` — asserts the
    /// request hits `deviceBind/markDeviceStatus` and a `{code:"OK"}` reply is
    /// treated as success (the app itself only checks `status == "OK"`).
    func testMarkDeviceStatusConfiguredFiresEnvelopedPost() async throws {
        BinderStubURLProtocol.reset()
        defer { BinderStubURLProtocol.reset() }
        // markDeviceStatus is an enveloped call, so it opens the secure channel
        // first: answer the exchangeKey handshake with a real server key, then
        // reply OK to the endpoint itself.
        let handshake = Self.handshakeResponse()
        BinderStubURLProtocol.handler = { request, _ in
            if request.url!.path.hasSuffix("security/exchangeKey") {
                return (200, handshake)
            }
            return (200, try! JSONSerialization.data(withJSONObject: ["code": "OK", "data": true]))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BinderStubURLProtocol.self]
        let configured = SyaiBackend.syaiTemplate.withCredentials(
            SyaiCredentials(
                refreshToken: Self.jwt(expiresIn: 86400),
                accessToken: Self.jwt(expiresIn: 1200)
            )
        )
        let binder = SyaiServerDeviceBinder(
            backend: configured,
            session: URLSession(configuration: config)
        )

        try await binder.markDeviceStatus(mac: "665544332211", inProgress: true)

        let sent = try XCTUnwrap(BinderStubURLProtocol.requests.last)
        XCTAssertTrue(
            sent.request.url!.path.hasSuffix("deviceBind/markDeviceStatus"),
            sent.request.url!.path
        )
        XCTAssertEqual(sent.request.httpMethod, "POST")
        // The plaintext rides inside the cipher envelope (asserted shape only —
        // the stub can't hold the ephemeral key to decrypt).
        let bodyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(sent.body)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(bodyJSON.keys),
            ["cipherBodyText", "cipherBodyMac", "cipherBodyNonce", "cipherBodySignature"]
        )
    }

    // MARK: unbind

    /// A logged-out (template) backend has no refresh token, so unbind must
    /// throw before touching the network — same guard as `bind`.
    func testUnbindThrowsWhenNotConfigured() async {
        let binder = SyaiServerDeviceBinder(backend: .syaiTemplate)
        do {
            _ = try await binder.unbind(mac: "665544332211", reason: .endedEarlyDiscardingData)
            XCTFail("expected notConfigured to throw")
        } catch let error as SyaiServerDeviceBinder.BindError {
            guard case .notConfigured = error else { return XCTFail("wrong BindError: \(error)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The wire shape of the end-of-session unbind: a `PUT` to
    /// `deviceBind/unBindDevice` carrying the standard cipher envelope. The verb
    /// matters — this is the only enveloped call that isn't a POST.
    func testUnbindFiresEnvelopedPut() async throws {
        BinderStubURLProtocol.reset()
        defer { BinderStubURLProtocol.reset() }
        let handshake = Self.handshakeResponse()
        BinderStubURLProtocol.handler = { request, _ in
            if request.url!.path.hasSuffix("security/exchangeKey") {
                return (200, handshake)
            }
            return (200, try! JSONSerialization.data(withJSONObject: ["code": "OK", "data": true]))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BinderStubURLProtocol.self]
        let configured = SyaiBackend.syaiTemplate.withCredentials(
            SyaiCredentials(
                refreshToken: Self.jwt(expiresIn: 86400),
                accessToken: Self.jwt(expiresIn: 1200)
            )
        )
        let binder = SyaiServerDeviceBinder(
            backend: configured,
            session: URLSession(configuration: config)
        )

        let code = try await binder.unbind(mac: "665544332211", reason: .endedEarlyDiscardingData)

        XCTAssertEqual(code, "OK")
        let sent = try XCTUnwrap(BinderStubURLProtocol.requests.last)
        XCTAssertTrue(
            sent.request.url!.path.hasSuffix("deviceBind/unBindDevice"),
            sent.request.url!.path
        )
        XCTAssertEqual(sent.request.httpMethod, "PUT")
        let bodyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(sent.body)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(bodyJSON.keys),
            ["cipherBodyText", "cipherBodyMac", "cipherBodyNonce", "cipherBodySignature"]
        )
    }

    /// A business-code rejection comes back as the code, not a throw, so the
    /// caller can tell "server said no" from "the request never landed".
    func testUnbindSurfacesServerBusinessCode() async throws {
        BinderStubURLProtocol.reset()
        defer { BinderStubURLProtocol.reset() }
        let handshake = Self.handshakeResponse()
        BinderStubURLProtocol.handler = { request, _ in
            if request.url!.path.hasSuffix("security/exchangeKey") {
                return (200, handshake)
            }
            return (200, try! JSONSerialization.data(withJSONObject: ["code": "AppDevice_EndUsing"]))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BinderStubURLProtocol.self]
        let configured = SyaiBackend.syaiTemplate.withCredentials(
            SyaiCredentials(
                refreshToken: Self.jwt(expiresIn: 86400),
                accessToken: Self.jwt(expiresIn: 1200)
            )
        )
        let binder = SyaiServerDeviceBinder(
            backend: configured,
            session: URLSession(configuration: config)
        )

        let code = try await binder.unbind(mac: "665544332211", reason: .endedEarlyDiscardingData)
        XCTAssertEqual(code, "AppDevice_EndUsing")
    }

    /// A valid `/security/exchangeKey` reply: a freshly generated server P-256 key
    /// so `deriveSession` succeeds. The derived key is never used here (the
    /// endpoint reply is stubbed unenveloped) — the handshake just has to complete.
    /// Mirrors `SyaiEnvelopedClientTests.handshakeResponse()`.
    private static func handshakeResponse() -> Data {
        let serverKey = P256.KeyAgreement.PrivateKey()
        let raw = serverKey.publicKey.rawRepresentation
        let body: [String: Any] = [
            "code": "OK",
            "data": [
                "serverPubKeyX": raw.prefix(32).base64EncodedString(),
                "serverPubKeyY": raw.suffix(32).base64EncodedString(),
                "secretId": "STUBSECRETID0001",
                "expireTime": Int(Date().addingTimeInterval(3600).timeIntervalSince1970) * 1000
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    /// Minimal unsigned JWT with a future `exp`, so `hasValidAccessToken` holds
    /// and no refresh fires.
    private static func jwt(expiresIn: TimeInterval) -> String {
        func b64url(_ d: Data) -> String {
            d.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
        let payload = b64url(try! JSONSerialization.data(withJSONObject: [
            "sub": "cust-binder",
            "exp": Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970)
        ]))
        return "\(header).\(payload).signature"
    }
}

/// Records requests and replies from `handler` — same pattern as
/// `SyaiEnvelopedClientTests.StubURLProtocol`, file-local so no request ever
/// leaves the machine.
private final class BinderStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest, Data?) -> (Int, Data))?
    static var requests: [(request: URLRequest, body: Data?)] = []

    static func reset() { handler = nil
        requests = [] }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            body = data
        }
        Self.requests.append((request, body))
        let (status, data) = Self.handler?(request, body) ?? (500, Data())
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
