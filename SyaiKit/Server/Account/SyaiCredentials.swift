//
//  SyaiCredentials.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// JWT session credentials for the BYOA backend, minted by a user's own login.
///
/// The request *signature* uses a hardcoded key (`SyaiBackend.deviceSignKey`);
/// what is account-bound is the JWT session: an `Authorization` access token +
/// `customerId` header on every gated call. Both tokens rotate on each refresh,
/// so the newest refresh token must be persisted.
///
/// `userId` / `deviceId` / `appName` are read from the JWT claims (`sub`,
/// `device_id`, `app_name`) so the session identity always matches the token.
public struct SyaiCredentials: Sendable {
    public var refreshToken: String
    public var accessToken: String?

    public init(refreshToken: String, accessToken: String? = nil) {
        self.refreshToken = refreshToken
        self.accessToken = accessToken
    }

    public static let placeholder = SyaiCredentials(refreshToken: "")

    private var identityToken: String? {
        if let a = accessToken, !a.isEmpty { return a }
        return refreshToken.isEmpty ? nil : refreshToken
    }

    public var userId: String? { identityToken.flatMap { Self.jwtStringClaim("sub", in: $0) } }
    public var deviceIdClaim: String? { identityToken.flatMap { Self.jwtStringClaim("device_id", in: $0) } }
    public var appNameClaim: String? { identityToken.flatMap { Self.jwtStringClaim("app_name", in: $0) } }

    public var accessTokenExpiry: Date? {
        guard let t = accessToken, let exp = Self.jwtNumberClaim("exp", in: t) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    public var refreshTokenExpiry: Date? {
        guard !refreshToken.isEmpty, let exp = Self.jwtNumberClaim("exp", in: refreshToken) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    public var hasValidSession: Bool {
        guard isConfigured else { return false }
        // No `exp` on the token: treat as valid (server is the final arbiter).
        guard let expiry = refreshTokenExpiry else { return true }
        return expiry.timeIntervalSinceNow > 0
    }

    public var hasValidAccessToken: Bool {
        (accessTokenExpiry?.timeIntervalSinceNow ?? -1) > 60
    }

    public var isConfigured: Bool { !refreshToken.isEmpty }

    // The JWT payload is not confidential (RFC 7519) and we only read it for
    // identity; no signature verification here (the server enforces that).
    private static func jwtStringClaim(_ name: String, in jwt: String) -> String? {
        jwtPayload(jwt)?[name] as? String
    }

    private static func jwtNumberClaim(_ name: String, in jwt: String) -> Double? {
        (jwtPayload(jwt)?[name] as? NSNumber)?.doubleValue
    }

    private static func jwtPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2, let data = base64URLDecode(String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func base64URLDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}
