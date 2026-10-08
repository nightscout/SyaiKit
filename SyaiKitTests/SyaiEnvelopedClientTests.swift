//
//  SyaiEnvelopedClientTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import CryptoKit
@testable import SyaiKit
import XCTest

/// Wire-shape tests for `SyaiEnvelopedClient`, driven through a stubbed `URLProtocol`
/// so no request ever leaves the machine.
///
/// The point of interest is `jwt/refreshToken`: the original Swift port sent
/// **headers only, with no cipher envelope**. The confirmed shape routes an empty
/// body through the same envelope every other gated call uses, with the token pair
/// as explicit headers.
///
/// Responses are stubbed **unenveloped**: `decryptEnvelopeOrPassthrough` passes a
/// body with no `cipherText`/`cipherMac`/`cipherNonce` through untouched, which is
/// the same path a plaintext server error takes. That lets a test assert request
/// shape without holding the client's ephemeral private key.
final class SyaiEnvelopedClientTests: XCTestCase {
    final class StubURLProtocol: URLProtocol {
        static var handler: ((URLRequest, Data?) -> (Int, Data))?
        static var requests: [(request: URLRequest, body: Data?)] = []

        static func reset() { handler = nil
            requests = [] }

        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            // URLSession moves `httpBody` into `httpBodyStream` by the time it reaches
            // a URLProtocol, so read the stream rather than `request.httpBody`.
            let body = Self.readBody(of: request)
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

        private static func readBody(of request: URLRequest) -> Data? {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    private func makeStubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    /// A minimal unsigned JWT — only the payload claims are ever read.
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

    private func jwt(sub: String, expiresIn: TimeInterval) -> String {
        makeJWT(["sub": sub, "exp": Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970)])
    }

    /// A valid `/security/exchangeKey` reply: a freshly generated server P-256 key so
    /// `deriveSession` succeeds. The derived key is never used here (responses are
    /// stubbed unenveloped) — the handshake just has to complete.
    private func handshakeResponse() -> Data {
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

    private func backend(credentials: SyaiCredentials) -> SyaiBackend {
        var backend = SyaiBackend.syaiTemplate
        backend.credentials = credentials
        return backend
    }

    func testRefreshSendsCipherEnvelopeAndAdoptsRotatedTokens() async throws {
        let oldRefresh = jwt(sub: "cust-42", expiresIn: 265 * 86400)
        let oldAccess = jwt(sub: "cust-42", expiresIn: -60) // expired ⇒ a refresh is due
        let newAccess = jwt(sub: "cust-42", expiresIn: 20 * 60)
        let newRefresh = jwt(sub: "cust-42", expiresIn: 265 * 86400)

        let handshake = handshakeResponse()
        StubURLProtocol.handler = { request, _ in
            if request.url!.path.hasSuffix("security/exchangeKey") {
                return (200, handshake)
            }
            // The refresh reply is flat (`data.{accessToken,refreshToken,…}`), unlike
            // login's nested `data.jwtToken` shape.
            let body: [String: Any] = ["code": "OK", "data": [
                "accessToken": newAccess,
                "refreshToken": newRefresh,
                "glucoseSecretKey": "SECRETKEY0000000"
            ]]
            return (200, try! JSONSerialization.data(withJSONObject: body))
        }

        let client = SyaiEnvelopedClient(
            backend: backend(credentials: SyaiCredentials(
                refreshToken: oldRefresh,
                accessToken: oldAccess
            )),
            urlSession: makeStubbedSession()
        )
        try await client.refreshAccessToken()

        let refreshRequests = StubURLProtocol.requests.filter {
            $0.request.url!.path.hasSuffix("jwt/refreshToken")
        }
        XCTAssertEqual(refreshRequests.count, 1)
        let sent = try XCTUnwrap(refreshRequests.first)
        XCTAssertEqual(sent.request.httpMethod, "POST")

        // A cipher envelope, not an empty body: the four `cipherBody*` fields are the
        // entire body; the real (empty) payload rides encrypted inside them.
        let rawBody = try XCTUnwrap(sent.body)
        let bodyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rawBody) as? [String: Any]
        )
        XCTAssertEqual(
            Set(bodyJSON.keys),
            ["cipherBodyText", "cipherBodyMac", "cipherBodyNonce", "cipherBodySignature"]
        )
        for key in bodyJSON.keys {
            XCTAssertFalse((bodyJSON[key] as? String ?? "").isEmpty, "\(key) must be populated")
        }

        let headers = sent.request.allHTTPHeaderFields ?? [:]
        for key in ["cipherSecretId", "cipherNonceId", "cipherTimeNow", "cipherUserId", "cipherSeq"] {
            XCTAssertNotNil(headers[key], "missing cipher header \(key)")
        }

        // The token pair rides as explicit headers alongside the usual
        // `Authorization`, even when the access token is expired.
        XCTAssertEqual(headers["customerId"], "cust-42")
        XCTAssertEqual(headers["refreshToken"], oldRefresh)
        XCTAssertEqual(headers["accessToken"], oldAccess)
        XCTAssertEqual(
            headers["Authorization"],
            oldAccess,
            "the app sends Authorization on jwt/refreshToken even when expired"
        )
        // No `productModel` on this call.
        XCTAssertNil(headers["productModel"])

        let credentials = await client.currentCredentials
        XCTAssertEqual(credentials.accessToken, newAccess)
        XCTAssertEqual(credentials.refreshToken, newRefresh, "the rotated refresh token must be adopted")
        let gsk = await client.currentGlucoseSecretKey
        XCTAssertEqual(gsk, "SECRETKEY0000000")
    }

    /// The nested `data.jwtToken` shape (login's) is still accepted — the parser keeps
    /// both fallbacks for robustness.
    func testRefreshAcceptsNestedJwtTokenShape() async throws {
        let newAccess = jwt(sub: "cust-7", expiresIn: 20 * 60)
        let newRefresh = jwt(sub: "cust-7", expiresIn: 265 * 86400)

        let handshake = handshakeResponse()
        StubURLProtocol.handler = { request, _ in
            if request.url!.path.hasSuffix("security/exchangeKey") {
                return (200, handshake)
            }
            let body: [String: Any] = ["code": "OK", "data": [
                "accessToken": NSNull(),
                "jwtToken": ["accessToken": newAccess, "refreshToken": newRefresh]
            ]]
            return (200, try! JSONSerialization.data(withJSONObject: body))
        }

        let client = SyaiEnvelopedClient(
            backend: backend(credentials: SyaiCredentials(refreshToken: jwt(sub: "cust-7", expiresIn: 86400))),
            urlSession: makeStubbedSession()
        )
        try await client.refreshAccessToken()

        let credentials = await client.currentCredentials
        XCTAssertEqual(credentials.accessToken, newAccess)
        XCTAssertEqual(credentials.refreshToken, newRefresh)
    }

    func testRefreshWithoutCredentialsThrowsBeforeAnyRequest() async {
        StubURLProtocol.handler = { _, _ in (200, Data()) }
        let client = SyaiEnvelopedClient(
            backend: backend(credentials: .placeholder),
            urlSession: makeStubbedSession()
        )
        do {
            try await client.refreshAccessToken()
            XCTFail("expected .notConfigured")
        } catch {
            XCTAssertTrue(StubURLProtocol.requests.isEmpty, "no request should have been sent")
        }
    }

    /// The base header set must match the official app's. SyaiKit used to send only
    /// `productModel`/`appName`/`deviceId`, which both stands out and risks a
    /// server-side requirement we hadn't hit.
    func testEveryRequestCarriesTheAppsBaseHeaderSet() async throws {
        let handshake = handshakeResponse()
        StubURLProtocol.handler = { request, _ in
            if request.url!.path.hasSuffix("security/exchangeKey") { return (200, handshake) }
            let body: [String: Any] = ["code": "OK", "data": [
                "accessToken": self.jwt(sub: "cust-3", expiresIn: 1200)
            ]]
            return (200, try! JSONSerialization.data(withJSONObject: body))
        }

        let client = SyaiEnvelopedClient(
            backend: backend(credentials: SyaiCredentials(refreshToken: jwt(sub: "cust-3", expiresIn: 86400))),
            urlSession: makeStubbedSession()
        )
        try await client.refreshAccessToken()

        let sent = try XCTUnwrap(StubURLProtocol.requests.last(where: {
            $0.request.url!.path.hasSuffix("jwt/refreshToken")
        }))
        let headers = sent.request.allHTTPHeaderFields ?? [:]
        for key in [
            "timestamp",
            "traceId",
            "appName",
            "packageName",
            "versionName",
            "versionCode",
            "ua",
            "timeZoneName",
            "timezone",
            "language",
            "country",
            "region",
            "deviceId",
            "unit",
            "deviceModel"
        ] {
            let value = headers[key] ?? ""
            XCTAssertFalse(value.isEmpty, "base header \(key) missing or empty")
        }
        // Values must match the real app, not the host platform.
        XCTAssertEqual(headers["ua"], "ios", "the app is iOS; 'android' would give us away")
        XCTAssertEqual(headers["packageName"], "com.syai.tag")
        // deviceModel must be a real handset identifier ("iPhone15,2"-style), never the
        // simulator's host arch — those never appear on a real iPhone and would
        // fingerprint a live run. On the simulator deviceHardwareModel resolves
        // SIMULATOR_MODEL_IDENTIFIER to a real device id; on device, sysctl hw.machine.
        let deviceModel = headers["deviceModel"] ?? ""
        for leak in ["arm64", "x86_64", "i386", "Simulator"] {
            XCTAssertNotEqual(
                deviceModel,
                leak,
                "deviceModel leaked the host/simulator arch (\(deviceModel))"
            )
        }
    }

    /// `productModel` rides `validateDeviceByMacV2` and nothing else, so it is opt-in.
    /// This asserts the default direction — a new call site gets no `productModel`
    /// unless it asks, rather than leaking one by inheriting a permissive default.
    func testProductModelIsOptInPerCall() async throws {
        let handshake = handshakeResponse()
        StubURLProtocol.handler = { request, _ in
            if request.url!.path.hasSuffix("security/exchangeKey") { return (200, handshake) }
            let body: [String: Any] = ["code": "OK", "data": ["ok": true]]
            return (200, try! JSONSerialization.data(withJSONObject: body))
        }
        let client = SyaiEnvelopedClient(
            backend: backend(credentials: SyaiCredentials(
                refreshToken: jwt(sub: "cust-4", expiresIn: 86400),
                accessToken: jwt(sub: "cust-4", expiresIn: 1200)
            )),
            urlSession: makeStubbedSession()
        )

        _ = try await client.envelopedPOST(path: "some/other/call", body: [:])
        let plain = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertNil((plain.request.allHTTPHeaderFields ?? [:])["productModel"])

        _ = try await client.validateMac("112233445566")
        let validate = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual((validate.request.allHTTPHeaderFields ?? [:])["productModel"], "X1")
    }

    /// `user/apiToken` and `user/mail/login` are unauthenticated; a stale access token
    /// held from a previous session must not leak onto them as `Authorization`.
    func testLoginDoesNotSendAuthorizationHeader() async throws {
        let staleAccess = jwt(sub: "cust-1", expiresIn: 20 * 60)
        let loginAccess = jwt(sub: "cust-2", expiresIn: 20 * 60)
        let loginRefresh = jwt(sub: "cust-2", expiresIn: 265 * 86400)

        let handshake = handshakeResponse()
        StubURLProtocol.handler = { request, _ in
            let path = request.url!.path
            if path.hasSuffix("security/exchangeKey") { return (200, handshake) }
            if path.hasSuffix("user/apiToken") {
                let body: [String: Any] = ["code": "OK", "data": "11111111-2222-3333-4444-555555555555"]
                return (200, try! JSONSerialization.data(withJSONObject: body))
            }
            let body: [String: Any] = ["code": "OK", "data": [
                "userId": "cust-2",
                "glucoseSecretKey": "SECRETKEY0000000",
                "jwtToken": ["accessToken": loginAccess, "refreshToken": loginRefresh]
            ]]
            return (200, try! JSONSerialization.data(withJSONObject: body))
        }

        let client = SyaiEnvelopedClient(
            backend: backend(credentials: SyaiCredentials(
                refreshToken: jwt(sub: "cust-1", expiresIn: 86400),
                accessToken: staleAccess
            )),
            urlSession: makeStubbedSession()
        )
        let result = try await client.login(email: "user@example.com", password: "hunter2")
        XCTAssertEqual(result.credentials.accessToken, loginAccess)
        XCTAssertEqual(result.credentials.refreshToken, loginRefresh)

        for sent in StubURLProtocol.requests {
            let headers = sent.request.allHTTPHeaderFields ?? [:]
            XCTAssertNil(
                headers["Authorization"],
                "\(sent.request.url!.path) must not carry Authorization"
            )
            XCTAssertNil(
                headers["productModel"],
                "\(sent.request.url!.path) must not carry productModel"
            )
        }
    }

    // MARK: - AuthFailed_LoginElsewhere

    func testIsAccountLoggedInElsewhereDetectsTheSpecificCodeOnly() {
        let loginElsewhere = SyaiEnvelopedClient.TransportError.http(
            401, body: #"{"code":"AuthFailed_LoginElsewhere","msg":"account logged in elsewhere"}"#
        )
        XCTAssertTrue(loginElsewhere.isAccountLoggedInElsewhere)
        XCTAssertFalse(loginElsewhere.isAuthFailure, "must not trigger a silent relogin")

        let deadToken = SyaiEnvelopedClient.TransportError.http(
            401, body: #"{"code":"AuthFailed_TokenInvalid","msg":"dead token"}"#
        )
        XCTAssertFalse(deadToken.isAccountLoggedInElsewhere)
        XCTAssertTrue(deadToken.isAuthFailure, "a genuinely dead token must still trigger silent relogin")

        let rejected = SyaiEnvelopedClient.TransportError.sessionRejected("AuthFailed_LoginElsewhere")
        XCTAssertTrue(rejected.isAccountLoggedInElsewhere)
        XCTAssertFalse(rejected.isAuthFailure)

        let otherRejected = SyaiEnvelopedClient.TransportError.sessionRejected("SomethingElse")
        XCTAssertFalse(otherRejected.isAccountLoggedInElsewhere)
        XCTAssertTrue(otherRejected.isAuthFailure)
    }

    /// `refreshAccessToken` records the lockout on `AuthFailed_LoginElsewhere`; `ensureAccessToken`
    /// then skips the network round trip for cooldown-respecting callers (telemetry) — permanently,
    /// not just temporarily, since retrying the same refresh token can never succeed without a
    /// fresh login. A caller that passes `bypassKnownLockout: true` (pairing) always gets a real
    /// attempt regardless, for an accurate error, but that attempt is just as doomed.
    func testEnsureAccessTokenShortCircuitsDuringLockoutButBypassAlwaysRetries() async throws {
        let handshake = handshakeResponse()
        StubURLProtocol.handler = { request, _ in
            if request.url!.path.hasSuffix("security/exchangeKey") { return (200, handshake) }
            let body: [String: Any] = ["code": "AuthFailed_LoginElsewhere", "msg": "account logged in elsewhere"]
            return (401, try! JSONSerialization.data(withJSONObject: body))
        }

        let client = SyaiEnvelopedClient(
            backend: backend(credentials: SyaiCredentials(
                refreshToken: jwt(sub: "cust-9", expiresIn: 86400),
                accessToken: jwt(sub: "cust-9", expiresIn: -60) // expired ⇒ a refresh is due
            )),
            urlSession: makeStubbedSession()
        )

        func refreshCallCount() -> Int {
            StubURLProtocol.requests.filter { $0.request.url!.path.hasSuffix("jwt/refreshToken") }.count
        }

        do {
            try await client.ensureAccessToken()
            XCTFail("expected the 401 to propagate")
        } catch let error as SyaiEnvelopedClient.TransportError {
            XCTAssertTrue(error.isAccountLoggedInElsewhere)
        }
        var lockedOut = await client.isAccountLockedOutElsewhere
        XCTAssertTrue(lockedOut)
        XCTAssertEqual(refreshCallCount(), 1)

        // A second cooldown-respecting call must not hit the network again.
        do {
            try await client.ensureAccessToken()
            XCTFail("expected the cached lockout to short-circuit")
        } catch let error as SyaiEnvelopedClient.TransportError {
            guard case .accountLockedOutElsewhere = error else {
                XCTFail("expected .accountLockedOutElsewhere, got \(error)")
                return
            }
        }
        XCTAssertEqual(refreshCallCount(), 1, "the cached lockout must skip a second network round trip")

        // A caller that bypasses the known lockout (pairing) always gets a real attempt.
        do {
            try await client.ensureAccessToken(bypassKnownLockout: true)
            XCTFail("expected the bypassed call to still fail (server still rejects)")
        } catch {}
        XCTAssertEqual(refreshCallCount(), 2, "bypassKnownLockout must always attempt a real network call")

        lockedOut = await client.isAccountLockedOutElsewhere
        XCTAssertTrue(lockedOut, "still locked out; the server never actually recovered")

        // The latch does not expire on its own: a later cooldown-respecting call still
        // short-circuits, since nothing about retrying the same dead token could ever change.
        do {
            try await client.ensureAccessToken()
            XCTFail("expected the lockout to still short-circuit")
        } catch let error as SyaiEnvelopedClient.TransportError {
            guard case .accountLockedOutElsewhere = error else {
                XCTFail("expected .accountLockedOutElsewhere, got \(error)")
                return
            }
        }
        XCTAssertEqual(refreshCallCount(), 2, "the latch must not silently expire and retry on its own")
    }

    func testSuccessfulRefreshClearsAPreviouslyRecordedLockout() async throws {
        let handshake = handshakeResponse()
        let shouldFail = LockedBool(true)
        let newAccess = jwt(sub: "cust-10", expiresIn: 20 * 60)
        StubURLProtocol.handler = { request, _ in
            if request.url!.path.hasSuffix("security/exchangeKey") { return (200, handshake) }
            if shouldFail.value {
                let body: [String: Any] = ["code": "AuthFailed_LoginElsewhere", "msg": "account logged in elsewhere"]
                return (401, try! JSONSerialization.data(withJSONObject: body))
            }
            let body: [String: Any] = ["code": "OK", "data": ["accessToken": newAccess]]
            return (200, try! JSONSerialization.data(withJSONObject: body))
        }

        let client = SyaiEnvelopedClient(
            backend: backend(credentials: SyaiCredentials(
                refreshToken: jwt(sub: "cust-10", expiresIn: 86400),
                accessToken: jwt(sub: "cust-10", expiresIn: -60)
            )),
            urlSession: makeStubbedSession()
        )

        do { try await client.refreshAccessToken() } catch {}
        var lockedOut = await client.isAccountLockedOutElsewhere
        XCTAssertTrue(lockedOut)

        shouldFail.value = false
        try await client.refreshAccessToken()
        lockedOut = await client.isAccountLockedOutElsewhere
        XCTAssertFalse(lockedOut, "a successful refresh must clear the lockout")
    }

    /// Lock-protected mutable `Bool` so a @Sendable stub handler closure can flip it.
    private final class LockedBool: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool
        init(_ initial: Bool) { stored = initial }
        var value: Bool {
            get { lock.lock()
                defer { lock.unlock() }
                return stored }
            set { lock.lock()
                stored = newValue
                lock.unlock() }
        }
    }

    /// A failed login (HTTP 200, business code — e.g. wrong password) throws
    /// `.serverError` carrying the code and the server's human-readable `msg`,
    /// and adopts no tokens. The fixture matches the live capture: both a wrong
    /// password and an unregistered email return `User_InvalidParams`.
    func testFailedLoginSurfacesCodeAndMessage() async throws {
        let handshake = handshakeResponse()
        StubURLProtocol.handler = { request, _ in
            let path = request.url!.path
            if path.hasSuffix("security/exchangeKey") { return (200, handshake) }
            if path.hasSuffix("user/apiToken") {
                let body: [String: Any] = ["code": "OK", "data": "11111111-2222-3333-4444-555555555555"]
                return (200, try! JSONSerialization.data(withJSONObject: body))
            }
            let body: [String: Any] = [
                "code": "User_InvalidParams",
                "msg": "Incorrect account or password entered.",
                "data": NSNull()
            ]
            return (200, try! JSONSerialization.data(withJSONObject: body))
        }

        let client = SyaiEnvelopedClient(
            backend: backend(credentials: SyaiCredentials(refreshToken: "r", accessToken: "a")),
            urlSession: makeStubbedSession()
        )
        do {
            _ = try await client.login(email: "user@example.com", password: "wrong")
            XCTFail("a non-OK login code must throw")
        } catch let error as SyaiEnvelopedClient.LoginError {
            guard case let .serverError(code, message) = error else {
                return XCTFail("expected .serverError, got \(error)")
            }
            XCTAssertEqual(code, "User_InvalidParams")
            XCTAssertEqual(message, "Incorrect account or password entered.")
            // A mapped code's description is our own localized text.
            XCTAssertEqual(error.description, SyaiLoginErrorCode.invalidParams.description)
        }
    }

    /// A login failure whose code isn't in the known set keeps the raw code and
    /// the server's `msg` — that msg is the fallback display text.
    func testFailedLoginWithUnmappedCodeKeepsRawCodeAndMessage() async throws {
        let handshake = handshakeResponse()
        StubURLProtocol.handler = { request, _ in
            let path = request.url!.path
            if path.hasSuffix("security/exchangeKey") { return (200, handshake) }
            if path.hasSuffix("user/apiToken") {
                let body: [String: Any] = ["code": "OK", "data": "11111111-2222-3333-4444-555555555555"]
                return (200, try! JSONSerialization.data(withJSONObject: body))
            }
            let body: [String: Any] = [
                "code": "User_SomethingNew",
                "msg": "Some new failure the app doesn't map.",
                "data": NSNull()
            ]
            return (200, try! JSONSerialization.data(withJSONObject: body))
        }

        let client = SyaiEnvelopedClient(
            backend: backend(credentials: SyaiCredentials(refreshToken: "r", accessToken: "a")),
            urlSession: makeStubbedSession()
        )
        do {
            _ = try await client.login(email: "user@example.com", password: "wrong")
            XCTFail("a non-OK login code must throw")
        } catch let error as SyaiEnvelopedClient.LoginError {
            guard case let .serverError(code, message) = error else {
                return XCTFail("expected .serverError, got \(error)")
            }
            XCTAssertEqual(code, "User_SomethingNew")
            XCTAssertEqual(message, "Some new failure the app doesn't map.")
            // An unmapped code's description is the server's own msg.
            XCTAssertEqual(error.description, "Some new failure the app doesn't map.")
        }
    }

    /// A transport-level failure (here: HTTP 500 on the key-exchange handshake)
    /// reaches the caller only as `LoginError.transportFailure` — `login()`
    /// never leaks `TransportError`, `URLError`, or crypto errors.
    func testLoginWrapsTransportFailures() async throws {
        StubURLProtocol.handler = { _, _ in (500, Data("boom".utf8)) }

        let client = SyaiEnvelopedClient(
            backend: backend(credentials: SyaiCredentials(refreshToken: "r", accessToken: "a")),
            urlSession: makeStubbedSession()
        )
        do {
            _ = try await client.login(email: "user@example.com", password: "whatever")
            XCTFail("a transport failure must throw")
        } catch let error as SyaiEnvelopedClient.LoginError {
            guard case let .transportFailure(underlying) = error else {
                return XCTFail("expected .transportFailure, got \(error)")
            }
            XCTAssertFalse(underlying.isEmpty)
        } catch {
            XCTFail("login() must only throw LoginError, got \(error)")
        }
    }
}
