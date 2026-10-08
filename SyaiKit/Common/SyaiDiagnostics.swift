//
//  SyaiDiagnostics.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

public enum SyaiDiagnostics {
    private static let verboseKey = "SyaiDiagnostics.verboseBLELogging"

    /// Opt-in extra chatter on top of what is always logged: the per-minute
    /// glucose notify ciphertext and full (redacted) server request/response
    /// bodies. Decoded frames, all other GATT traffic, the auth handshake and
    /// server status lines are logged regardless, so bug reports carry what's
    /// needed without this.
    public static var verboseBLELogging: Bool {
        get { UserDefaults.standard.object(forKey: verboseKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: verboseKey) }
    }

    public static var appVersionStamp: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

/// Masks identifiers before they reach the log file, which users attach to
/// public bug reports.
public enum SyaiRedact {
    /// Keeps the last two bytes, enough to tell sensors apart in one log.
    public static func mac(_ mac: String?) -> String {
        guard let mac, !mac.isEmpty else { return "nil" }
        let hex = mac.filter(\.isHexDigit)
        guard hex.count > 4 else { return "…" }
        return "…" + hex.suffix(4).uppercased()
    }

    public static func email(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@"), at > email.startIndex else { return "<redacted>" }
        return "\(email[email.startIndex])***\(email[at...])"
    }
}
