//
//  SyaiLiveVerifyTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// **LIVE integration test — hits the real `api.syai.com`.** Off by default:
/// `XCTSkipUnless` skips it unless `SYAI_LIVE=1` is in the test-process
/// environment, so it never runs in the normal suite. Drives the production
/// Swift network types end-to-end against the real backend.
///
/// **Burner account ONLY** — logging in with the real account from Swift risks
/// evicting the official app. Creds come from the environment so no secret
/// lands in the repo. Because env vars don't reach the simulator test process
/// directly, pass them Xcode-prefixed, e.g.:
///
///   TEST_RUNNER_SYAI_LIVE=1 \
///   TEST_RUNNER_SYAI_LIVE_EMAIL=<burner> \
///   TEST_RUNNER_SYAI_LIVE_PASSWORD=<pw> \
///   xcodebuild test -workspace Trio.xcworkspace -scheme SyaiKitTests \
///     -destination 'platform=iOS Simulator,name=iPhone 17' \
///     -only-testing:SyaiKitTests/SyaiLiveVerifyTests
///
/// The Mac's own VPN is the sanctioned egress (no proxy needed — the simulator
/// uses the host network stack). Never point this at the real account.
final class SyaiLiveVerifyTests: XCTestCase {
    func test_liveVerify_phase1_and_phase2() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env["SYAI_LIVE"] == "1",
            "live test — set SYAI_LIVE=1 (+ SYAI_LIVE_EMAIL/PASSWORD) to run"
        )
        let email = try XCTUnwrap(env["SYAI_LIVE_EMAIL"], "set SYAI_LIVE_EMAIL (burner)")
        let password = try XCTUnwrap(env["SYAI_LIVE_PASSWORD"], "set SYAI_LIVE_PASSWORD (burner)")
        let endedMAC = env["SYAI_LIVE_ENDED_MAC"] ?? "AABBCCDDEEFF"

        let template = SyaiBackend.syaiTemplate
        print(
            "LIVE identity — deviceId=\(template.deviceId) ua=\(template.userAgent) "
                + "ver=\(template.versionName)/\(template.versionCode) model=\(template.deviceModel)"
        )
        XCTAssertTrue(template.deviceId.hasPrefix("Syai Tag:i:n:"), "iOS-native install deviceId")
        XCTAssertEqual(template.userAgent, "ios")
        XCTAssertEqual(template.versionName, "1.35.0")
        XCTAssertEqual(template.versionCode, "263931")

        let client = SyaiEnvelopedClient(backend: template)

        let login = try await client.login(email: email, password: password)
        XCTAssertFalse(login.credentials.refreshToken.isEmpty, "login returned a refreshToken")
        XCTAssertNotNil(login.credentials.accessToken, "login returned an accessToken")
        XCTAssertNotNil(login.glucoseSecretKey, "login carried glucoseSecretKey")
        print("LIVE 2.1 login OK — accessToken present, glucoseSecretKey present=\(login.glucoseSecretKey != nil)")

        let before = await client.currentCredentials
        try await client.refreshAccessToken()
        let after = await client.currentCredentials
        XCTAssertNotEqual(before.refreshToken, after.refreshToken, "refresh rotated the refresh token")
        XCTAssertNotEqual(before.accessToken, after.accessToken, "refresh rotated the access token")
        print("LIVE 1.2 refresh OK — both tokens rotated")

        let macData = try await client.validateMac(endedMAC)
        let macRoot = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: macData) as? [String: Any],
            "validateMac body was not JSON"
        )
        let macCode = macRoot["code"] as? String
        print("LIVE 1.3 validateMac(\(endedMAC)) code=\(macCode ?? "nil")")
        // The lifecycle refusal is the proof (signature + envelope + Authorization all
        // accepted). Accept either terminal code — both are non-coefficient refusals.
        XCTAssertTrue(
            macCode == "AppDevice_EndUsing" || macCode == "AppDevice_AlreadyUsed",
            "expected an ended/used refusal, got \(macCode ?? "nil")"
        )

        let auth = try await client.authInfo(mac: endedMAC)
        print("LIVE 1.4 authInfo(\(endedMAC)) code=\(auth.code) serverDeviceId=\(auth.serverDeviceId.map(String.init) ?? "nil")")
        XCTAssertEqual(auth.code, "USER_NOT_BIND_DEVICE", "burner never bound this MAC")

        print("LIVE ✅ all phases passed")
    }

    /// Two sub-cases, each attempted ONCE (`LoginOverErrorCount` implies a
    /// server-side failure counter — do not loop):
    ///   (a) unregistered email → expect `EmailNotRegistered`
    ///   (b) wrong password on a real burner → expect `AccountOrPasswordError`
    ///
    /// `login()` must THROW (no tokens persisted); a success here is a test failure.
    func test_liveVerify_loginFailureCodes() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env["SYAI_LIVE"] == "1",
            "live test — set SYAI_LIVE=1 (+ SYAI_LIVE_EMAIL/PASSWORD) to run"
        )
        let burnerEmail = try XCTUnwrap(env["SYAI_LIVE_EMAIL"], "set SYAI_LIVE_EMAIL (burner)")

        // (a) Unregistered email — no inbox needed; this address was never signed up.
        let unregEmail = env["SYAI_LIVE_UNREG_EMAIL"]
            ?? "nobody-\(UUID().uuidString.prefix(8))@web-library.net"
        do {
            let client = SyaiEnvelopedClient(backend: .syaiTemplate)
            _ = try await client.login(email: unregEmail, password: "whatever-not-used")
            XCTFail("LIVE 2.4a expected login to FAIL for unregistered \(unregEmail), but it succeeded")
        } catch {
            print("LIVE 2.4a unregistered-email(\(unregEmail)) → \(error)")
        }

        // (b) Wrong password on the real burner — attempted exactly ONCE.
        do {
            let client = SyaiEnvelopedClient(backend: .syaiTemplate)
            _ = try await client.login(
                email: burnerEmail,
                password: "definitely-the-wrong-password-\(UUID().uuidString.prefix(6))"
            )
            XCTFail("LIVE 2.4b expected login to FAIL for wrong password, but it succeeded")
        } catch {
            print("LIVE 2.4b wrong-password → \(error)")
        }

        print("LIVE ✅ failure-code cases recorded (see verbatim codes above)")
    }

    /// The one genuinely LIVE unknown behind the silent-re-login path: what
    /// `jwt/refreshToken` returns for a DEAD refresh token. The manager-level
    /// orchestration is deterministic and belongs in offline stub tests — this
    /// probe just captures the server's real refusal so `refreshAccessToken`
    /// maps it to `TransportError.sessionRejected(<real code>)` / `isAuthFailure`
    /// correctly.
    ///
    /// Realistic simulation: log in for a genuine refresh token, then TAMPER its
    /// signature segment (payload/`sub` stay valid → `customerId` is still correct, the
    /// token is just cryptographically invalid) and refresh with it.
    func test_liveVerify_deadRefreshToken() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env["SYAI_LIVE"] == "1",
            "live test — set SYAI_LIVE=1 (+ SYAI_LIVE_EMAIL/PASSWORD) to run"
        )
        let email = try XCTUnwrap(env["SYAI_LIVE_EMAIL"], "set SYAI_LIVE_EMAIL (burner)")
        let password = try XCTUnwrap(env["SYAI_LIVE_PASSWORD"], "set SYAI_LIVE_PASSWORD (burner)")

        let loginClient = SyaiEnvelopedClient(backend: .syaiTemplate)
        let good = try await loginClient.login(email: email, password: password)
        let realRefresh = good.credentials.refreshToken

        // Tamper ONLY the signature (3rd JWT segment) — header.payload untouched.
        var segs = realRefresh.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segs.count == 3 else { return XCTFail("refresh token wasn't a 3-part JWT") }
        segs[2] = String(segs[2].reversed()) + "x" // invalid signature, same sub
        let tampered = segs.joined(separator: ".")

        let deadBackend = SyaiBackend.syaiTemplate.withCredentials(
            SyaiCredentials(refreshToken: tampered, accessToken: nil)
        ) // nil access → forces a refresh
        let deadClient = SyaiEnvelopedClient(backend: deadBackend)
        do {
            try await deadClient.refreshAccessToken()
            XCTFail("LIVE 2.2 expected the dead refresh token to be REJECTED, but refresh succeeded")
        } catch {
            let authShaped = (error as? SyaiEnvelopedClient.TransportError)?.isAuthFailure
            print("LIVE 2.2 dead-refresh-token → \(error)  isAuthFailure=\(authShaped.map(String.init) ?? "n/a")")
        }
        print("LIVE ✅ dead-refresh-token response recorded (see above)")
    }

    /// Exercises the real `SyaiEnvelopedClient` telemetry methods against the
    /// live backend under the burner. `uploadGlucose` uses a **bogus `deviceId`**
    /// so no real device's glucose history is touched. Each call succeeding
    /// (no throw) is the assertion.
    func test_liveVerify_telemetry() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env["SYAI_LIVE"] == "1",
            "live test — set SYAI_LIVE=1 (+ SYAI_LIVE_EMAIL/PASSWORD) to run"
        )
        let email = try XCTUnwrap(env["SYAI_LIVE_EMAIL"], "set SYAI_LIVE_EMAIL (burner)")
        let password = try XCTUnwrap(env["SYAI_LIVE_PASSWORD"], "set SYAI_LIVE_PASSWORD (burner)")
        let mac = env["SYAI_LIVE_ENDED_MAC"] ?? "AABBCCDDEEFF"

        let client = SyaiEnvelopedClient(backend: .syaiTemplate)
        _ = try await client.login(email: email, password: password)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        // Channel 1 — updateDeviceConnState (the fixed GET; a POST would 405).
        try await client.updateDeviceConnState(mac: mac)
        print("LIVE T1 updateDeviceConnState(GET) OK")

        // Channel 2 — batchStoreEventTracking (top-level array, tracking.syai.com).
        let event: [String: Any] = [
            "userId": "0", "appName": "Syai Tag", "eventType": "flutter_cgm_event",
            "eventName": "cgm_state",
            "eventInfo": [
                "userId": "0", "mac": mac, "time": 62, "dataNo": 0, "voltage": 31,
                "glucose": 32739, "temperature": 31.85, "adjustGlucose": 17.3,
                "orgGlucose": 17.3, "adjustState": NSNull(), "monitorTime": nowMs,
                "dataStatus": 1, "softVersion": "E2.0.1(V1.7.SH22537.1)",
                "dataTag": "expression", "deviceId": 999_999_999, "eventDiffTime": 2980
            ],
            "eventPlatform": "APP", "appCreateTime": nowMs
        ]
        try await client.batchStoreEventTracking([event])
        print("LIVE T2 batchStoreEventTracking OK")

        // Channel 3 — uploadGlucose via the production body builder, BOGUS deviceId.
        let rec = SyaiUploadRecord(
            runSec: 62, voltage: 31, receivedAtMs: nowMs, frontIdx: 0,
            glucoseMmol: 17.3, current: 32739, temperatureC: 31.85,
            origin: Data([0, 0, 0, 0, 227, 127, 180, 242, 249, 0, 0, 113, 12])
        )
        let body = rec.uploadBody(
            serverDeviceId: 999_999_999,
            embeddedSoftVersion: "E2.0.1(V1.7.SH22537.1)",
            activatedAtMs: nowMs - 62000
        )
        let ack = try await client.uploadGlucose(body)
        print("LIVE T3 uploadGlucose(bogus deviceId) OK — ack=\(ack)")

        print("LIVE ✅ all telemetry channels accepted from Swift")
    }
}
