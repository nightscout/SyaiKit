//
//  SyaiEnvelopedClient.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

public actor SyaiEnvelopedClient {
    var backend: SyaiBackend
    private let urlSession: URLSession
    private var session: SyaiSecureChannel.Session?
    private var seq: Int = 0

    public init(backend: SyaiBackend, urlSession: URLSession = .shared) {
        self.backend = backend
        self.urlSession = urlSession
    }

    public enum TransportError: Error, CustomStringConvertible {
        case notConfigured
        case http(Int, body: String)
        case badResponse(String)

        /// HTTP 200 with a non-OK business `code` and no tokens. Defensive handling
        /// for a shape not observed live (the server normally returns 401 for a dead
        /// refresh token); treated as an auth failure either way.
        case sessionRejected(String)

        /// Thrown by `ensureAccessToken` in place of a live network call once a prior
        /// `AuthFailed_LoginElsewhere` has latched (see: `isAccountLoggedInElsewhere`).
        case accountLockedOutElsewhere

        public var description: String {
            switch self {
            case .notConfigured: return "Syai backend not configured (log in first)."
            case let .http(c, b): return "Syai HTTP \(c): \(b)"
            case let .badResponse(m): return "Syai response: \(m)"
            case let .sessionRejected(c): return "Syai session rejected (code \(c)). Re-login required."
            case .accountLockedOutElsewhere:
                return "Syai account is logged in elsewhere (latched; a re-login is required, not a retry)."
            }
        }

        /// Narrow: only dead-session errors may trigger a silent re-login. Network errors,
        /// 5xx, and malformed responses must not burn a login. `AuthFailed_LoginElsewhere` is
        /// excluded on purpose. A silent relogin would just evict whatever else is signed in,
        /// which nothing here should do unprompted; see `isAccountLoggedInElsewhere`.
        public var isAuthFailure: Bool {
            switch self {
            case let .http(code, _) where code == 401 || code == 403: return !isAccountLoggedInElsewhere
            case .sessionRejected: return !isAccountLoggedInElsewhere
            default: return false
            }
        }

        /// True for the specific failure the server returns when this account's session was
        /// invalidated by a login elsewhere (e.g. the official Syai app on another device).
        /// Distinct from a merely dead/expired token: a silent re-login cannot fix this, only
        /// the other session ending (or the user re-authenticating by hand) does.
        public var isAccountLoggedInElsewhere: Bool {
            switch self {
            case let .http(401, body):
                return Self.parsedCode(from: body) == "AuthFailed_LoginElsewhere"
            case let .sessionRejected(code):
                return code == "AuthFailed_LoginElsewhere"
            default:
                return false
            }
        }

        private static func parsedCode(from body: String) -> String? {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
                return nil
            }
            return obj["code"] as? String
        }
    }

    private static var wireLoggingEnabled: Bool { SyaiDiagnostics.verboseBLELogging }
    private let wireLog = SyaiLogger(category: "Wire")

    private func wireLogRequest(
        _ method: String,
        _ path: String,
        _ request: URLRequest,
        plaintext: Data
    ) {
        guard Self.wireLoggingEnabled else { return }
        wireLog.info("> \(method) \(path) | headers=\(Self.redactedHeaders(request)) | plaintext=\(Self.redactedJSON(plaintext))")
    }

    /// Bodies only on opt-in; a response the server answered with a non-OK
    /// `code` is always logged, since that is what a bug report needs.
    private func wireLogResponse(_ path: String, _ response: URLResponse, body: Data) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if Self.wireLoggingEnabled {
            wireLog.info("< \(status) \(path) | body=\(Self.redactedJSON(body))")
        } else if let code = Self.responseCode(body), !Self.isOKCode(code) {
            wireLog.warning("< \(status) \(path) | code=\(code)")
        }
    }

    private func wireLogError(_ path: String, _ error: Error) {
        if case let TransportError.http(status, body) = error {
            wireLog.error("< ERROR \(path) | HTTP \(status) body=\(Self.redactedJSON(Data(body.utf8)))")
        } else {
            wireLog.error("< ERROR \(path) | \(String(describing: error))")
        }
    }

    private static func responseCode(_ body: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return obj["code"] as? String
    }

    private static func isOKCode(_ code: String) -> Bool {
        code == "OK" || code == "SUCCESS"
    }

    static func redactedHeaders(_ request: URLRequest) -> String {
        let headers = (request.allHTTPHeaderFields ?? [:]).map { key, value -> String in
            "\(key)=\(redactEntry(key: key, value: value))"
        }.sorted().joined(separator: ", ")
        return "{\(headers)}"
    }

    static func redactedJSON(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            return String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
        }
        let redacted = redactValue(obj)
        guard JSONSerialization.isValidJSONObject(redacted),
              let out = try? JSONSerialization.data(withJSONObject: redacted),
              let str = String(data: out, encoding: .utf8)
        else {
            return String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
        }
        return str
    }

    /// How a JSON key or header name is treated in wire logs. Secret material is
    /// dropped entirely; credentials and persistent identifiers keep a short prefix
    /// so log lines can still be correlated without carrying a usable value.
    enum Redaction {
        case full
        case truncated
        case none
    }

    static func classify(_ key: String) -> Redaction {
        let k = key.lowercased()
        // Secret key material, password-equivalents (login `signature` is an MD5 over
        // the password), and the per-sensor BLE key group / calibration.
        if k.contains("secret") || k.contains("signature") || k.contains("password")
            || k.contains("encryptinfo") || k == "keya" || k == "coefficient" || k == "apitoken"
        {
            return .full
        }
        // Tokens and persistent account/device identifiers.
        if k.contains("token") || k == "jwt" || k == "authorization"
            || k.contains("userid") || k.contains("customerid") || k.contains("deviceid")
            || k.contains("serialno") || k.contains("batchno")
        {
            return .truncated
        }
        return .none
    }

    static func redactEntry(key: String, value: Any) -> Any {
        // Classification applies to leaf values; containers always recurse so a
        // nested body like `jwtToken: {accessToken: …}` is still covered.
        if value is [String: Any] || value is [Any] {
            return redactValue(value)
        }
        switch classify(key) {
        case .full:
            if let s = value as? String { return "<redacted \(s.count) chars>" }
            return "<redacted>"
        case .truncated:
            // Identifiers arrive as both strings and numbers depending on the endpoint.
            if let s = value as? String { return truncated(s) }
            return "<redacted>"
        case .none:
            if let s = value as? String, key.lowercased().contains("mail"), s.contains("@") {
                return maskedEmail(s)
            }
            if let s = value as? String, key.lowercased().hasSuffix("mac") {
                return SyaiRedact.mac(s)
            }
            return value
        }
    }

    static func redactValue(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.reduce(into: [String: Any]()) { out, pair in
                out[pair.key] = redactEntry(key: pair.key, value: pair.value)
            }
        case let array as [Any]:
            return array.map { redactValue($0) }
        default:
            return value
        }
    }

    /// Never logs a complete value: short opaque tokens keep only half their length.
    static func truncated(_ s: String) -> String {
        let n = min(12, s.count / 2)
        return "\(s.prefix(n))…(\(s.count) chars)"
    }

    static func maskedEmail(_ s: String) -> String {
        s.contains("@") ? SyaiRedact.email(s) : truncated(s)
    }

    private func ensureSession() async throws -> SyaiSecureChannel.Session {
        if let s = session, !s.isExpired { return s }
        let (priv, body) = SyaiSecureChannel.makeExchangeRequest(deviceId: backend.deviceId)

        var request = URLRequest(url: backend.endpoint("security/exchangeKey"))
        request.httpMethod = "POST"
        let bodyJSON = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyJSON
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        backend.applyBaseHeaders(&request)

        wireLogRequest("POST", "security/exchangeKey", request, plaintext: bodyJSON)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
            try Self.checkStatus(response, data)
        } catch {
            wireLogError("security/exchangeKey", error)
            throw error
        }
        wireLogResponse("security/exchangeKey", response, body: data)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TransportError.badResponse("handshake body not JSON")
        }
        let server = (root["data"] as? [String: Any]) ?? root // unwrap {code,data}
        let newSession = try SyaiSecureChannel.deriveSession(
            privateKey: priv,
            response: server,
            deviceId: backend.deviceId
        )
        session = newSession
        seq = 0
        return newSession
    }

    private func nextSeq() -> Int { defer { seq += 1 }
        return seq }

    /// Current credentials after any call; the server rotates both tokens on every refresh.
    public var currentCredentials: SyaiCredentials { backend.credentials }

    /// Current `glucoseSecretKey`; read alongside `currentCredentials` to persist a rotated session.
    public var currentGlucoseSecretKey: String? { backend.glucoseSecretKey }

    /// Set once `refreshAccessToken` observes `AuthFailed_LoginElsewhere`; cleared on the next
    /// successful refresh. There is deliberately no cooldown/expiry on this: a login-elsewhere
    /// event revokes *this* session's tokens server-side, so retrying `jwt/refreshToken` with
    /// the same (now-dead) refresh token can never succeed again on its own.
    private var accountKnownLockedOut = false

    /// Whether the account is currently believed to be locked out by a login elsewhere.
    public var isAccountLockedOutElsewhere: Bool { accountKnownLockedOut }

    /// Ensure a non-expired access token, minting one via `jwt/refreshToken` if needed.

    public func ensureAccessToken(bypassKnownLockout: Bool = false) async throws {
        if backend.credentials.hasValidAccessToken { return }
        if !bypassKnownLockout, accountKnownLockedOut {
            throw TransportError.accountLockedOutElsewhere
        }
        try await refreshAccessToken()
    }

    /// `POST jwt/refreshToken`: empty body (`{}`), but still enveloped because the server
    /// requires the cipher envelope even for an empty body. `Authorization` carries the
    /// possibly-stale access token to match the official app's footprint.
    ///
    /// The response may be flat under `data` or nested under `data.jwtToken` (login shape);
    /// the fallback below handles both. Rotation does not invalidate the previous refresh
    /// token, but the newest one is persisted via `currentCredentials`.
    public func refreshAccessToken() async throws {
        do {
            try await performRefreshAccessToken()
            accountKnownLockedOut = false
        } catch let error as TransportError {
            if error.isAccountLoggedInElsewhere {
                accountKnownLockedOut = true
            }
            throw error
        }
    }

    private func performRefreshAccessToken() async throws {
        guard backend.isConfigured else { throw TransportError.notConfigured }

        var extraHeaders = [
            "customerId": backend.userId ?? "",
            "refreshToken": backend.credentials.refreshToken
        ]
        if let access = backend.credentials.accessToken {
            extraHeaders["accessToken"] = access
        }
        let plaintext = try await envelopedPOST(
            path: "jwt/refreshToken",
            body: [:],
            extraHeaders: extraHeaders
        )

        guard let root = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw TransportError.badResponse("refresh body not JSON")
        }
        let dataObj = (root["data"] as? [String: Any]) ?? root
        let jwt = (dataObj["jwtToken"] as? [String: Any]) ?? dataObj
        guard let newAccess = (jwt["accessToken"] as? String) ?? (dataObj["accessToken"] as? String) else {
            // HTTP 200 + non-OK business code + no tokens means a dead session.
            if let code = root["code"] as? String, code != "OK" {
                throw TransportError.sessionRejected(code)
            }
            throw TransportError.badResponse("refresh response had no accessToken")
        }
        backend.credentials.accessToken = newAccess
        if let newRefresh = (jwt["refreshToken"] as? String) ?? (dataObj["refreshToken"] as? String),
           !newRefresh.isEmpty
        {
            backend.credentials.refreshToken = newRefresh
        }
        // Capture the account's glucoseSecretKey when the response carries it (login-shaped bodies do).
        if let gsk = dataObj["glucoseSecretKey"] as? String, !gsk.isEmpty {
            backend.glucoseSecretKey = gsk
        }
    }

    /// Enveloped GET: `cipherParam*` ride the query string, cipher metadata rides as headers.
    public func envelopedGET(
        path: String,
        body: [String: Any],
        extraHeaders: [String: String] = [:],
        includeProductModel: Bool = false,
        authed: Bool = true
    ) async throws -> Data {
        let session = try await ensureSession()
        let bodyJSON = try JSONSerialization.data(withJSONObject: body)
        let env = try SyaiSecureChannel.encryptRequest(session: session, seq: nextSeq(), bodyJSON: bodyJSON)

        var comps = URLComponents(url: backend.endpoint(path), resolvingAgainstBaseURL: false)!
        // The cipher fields are base64 and contain `+`. URLComponents does not percent-encode
        // `+` in a query value, and the server decodes a literal `+` as a space, corrupting
        // the ciphertext. Percent-encode strictly.
        func q(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
        }
        comps.percentEncodedQueryItems = [
            URLQueryItem(name: "cipherParamText", value: q(env.text)),
            URLQueryItem(name: "cipherParamMac", value: q(env.mac)),
            URLQueryItem(name: "cipherParamNonce", value: q(env.nonce)),
            URLQueryItem(name: "cipherParamSignature", value: q(env.signature))
        ]
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        applyCipherHeaders(&request, env)
        applyAuthHeaders(&request, extraHeaders, includeProductModel: includeProductModel, authed: authed)

        wireLogRequest("GET", path, request, plaintext: bodyJSON)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
            try Self.checkStatus(response, data)
        } catch {
            wireLogError(path, error)
            throw error
        }
        let plaintext = try decryptEnvelopeOrPassthrough(data, session: session)
        wireLogResponse(path, response, body: plaintext)
        return plaintext
    }

    /// Enveloped POST: `cipherBody*` ride in the JSON body. The real body is encrypted;
    /// only cipher fields go on the wire.
    public func envelopedPOST(
        path: String,
        body: [String: Any],
        extraHeaders: [String: String] = [:],
        includeProductModel: Bool = false,
        authed: Bool = true
    ) async throws -> Data {
        try await envelopedPOST(
            url: backend.endpoint(path),
            bodyJSON: try JSONSerialization.data(withJSONObject: body),
            extraHeaders: extraHeaders,
            includeProductModel: includeProductModel,
            authed: authed
        )
    }

    /// Enveloped PUT. Identical envelope to `envelopedPOST`; `deviceBind/unBindDevice` is the only caller.
    public func envelopedPUT(
        path: String,
        body: [String: Any],
        extraHeaders: [String: String] = [:],
        includeProductModel: Bool = false,
        authed: Bool = true
    ) async throws -> Data {
        try await envelopedPOST(
            url: backend.endpoint(path),
            bodyJSON: try JSONSerialization.data(withJSONObject: body),
            extraHeaders: extraHeaders,
            includeProductModel: includeProductModel,
            authed: authed,
            method: "PUT"
        )
    }

    /// Shared enveloped-body core, used by both `envelopedPOST(path:)` and the event tracker
    /// (`tracking.syai.com`), which needs a different host and a top-level JSON array body.
    func envelopedPOST(
        url: URL,
        bodyJSON: Data,
        extraHeaders: [String: String],
        includeProductModel: Bool,
        authed: Bool,
        method: String = "POST"
    ) async throws -> Data {
        let session = try await ensureSession()
        let env = try SyaiSecureChannel.encryptRequest(session: session, seq: nextSeq(), bodyJSON: bodyJSON)

        let cipherBody: [String: String] = [
            "cipherBodyText": env.text,
            "cipherBodyMac": env.mac,
            "cipherBodyNonce": env.nonce,
            "cipherBodySignature": env.signature
        ]
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = try JSONSerialization.data(withJSONObject: cipherBody)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        applyCipherHeaders(&request, env)
        applyAuthHeaders(&request, extraHeaders, includeProductModel: includeProductModel, authed: authed)

        wireLogRequest(method, url.path, request, plaintext: bodyJSON)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
            try Self.checkStatus(response, data)
        } catch {
            wireLogError(url.path, error)
            throw error
        }
        let plaintext = try decryptEnvelopeOrPassthrough(data, session: session)
        wireLogResponse(url.path, response, body: plaintext)
        return plaintext
    }

    private func applyCipherHeaders(_ request: inout URLRequest, _ env: SyaiSecureChannel.Envelope) {
        request.setValue(env.secretId, forHTTPHeaderField: "cipherSecretId")
        request.setValue(String(env.seq), forHTTPHeaderField: "cipherSeq")
        request.setValue(env.nonceId, forHTTPHeaderField: "cipherNonceId")
        request.setValue(String(env.timeNow), forHTTPHeaderField: "cipherTimeNow")
        request.setValue(env.userId, forHTTPHeaderField: "cipherUserId")
    }

    /// When `authed` is false, withhold `Authorization`/`customerId` even if we hold an access
    /// token. `user/apiToken`, `user/mail/login`, and `jwt/refreshToken` must not carry it;
    /// `jwt/refreshToken` passes its own `customerId`/`refreshToken`/`accessToken` headers instead.
    private func applyAuthHeaders(
        _ request: inout URLRequest,
        _ extraHeaders: [String: String],
        includeProductModel: Bool = false,
        authed: Bool = true
    ) {
        backend.applyBaseHeaders(&request, includeProductModel: includeProductModel)
        if authed, let access = backend.credentials.accessToken {
            request.setValue(access, forHTTPHeaderField: "Authorization") // raw JWT, no "Bearer"
            request.setValue(backend.userId ?? "", forHTTPHeaderField: "customerId")
        }
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
    }

    /// Decrypt a response envelope, or pass the body through if it isn't enveloped.
    private func decryptEnvelopeOrPassthrough(
        _ data: Data,
        session: SyaiSecureChannel.Session
    ) throws -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data // not JSON, hand back raw
        }
        let text = (root["cipherText"] ?? root["cipherParamText"] ?? root["cipherBodyText"]) as? String
        let mac = (root["cipherMac"] ?? root["cipherParamMac"] ?? root["cipherBodyMac"]) as? String
        let nonce = (root["cipherNonce"] ?? root["cipherParamNonce"] ?? root["cipherBodyNonce"]) as? String
        guard let text, let mac, let nonce else { return data } // unenveloped, pass through
        return try SyaiSecureChannel.decryptResponse(session: session, textB64: text, macB64: mac, nonceB64: nonce)
    }

    private static func checkStatus(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw TransportError.http(http.statusCode, body: String(data: data, encoding: .utf8) ?? "<binary>")
        }
    }
}
