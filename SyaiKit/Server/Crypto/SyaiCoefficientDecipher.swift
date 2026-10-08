//
//  SyaiCoefficientDecipher.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// Deciphers the `coefficient` field of a sensor record (bind / getBindDevice response) into C0..C13.
///
/// Wire format:
/// ```
/// key = glucoseSecretKey + last10(coeffUpdateTime) + last6(mac)      // 16 + 10 + 6 = 32 B
/// plaintext = PKCS7-unpad(AES-256-ECB-decrypt(base64Decode(coefficient), key))
/// // plaintext is a CSV of 14 doubles
/// ```
///
/// The same KDF, with `produceTime` instead of `coeffUpdateTime`, unwraps `keyA` into the BLE key group.
public enum SyaiCoefficientDecipher {
    public enum DecipherError: Error, CustomStringConvertible {
        case badBase64
        case notUTF8
        case wrongCount(Int)
        case badValue(String)
        public var description: String {
            switch self {
            case .badBase64: return "coefficient: not valid base64"
            case .notUTF8: return "coefficient: deciphered bytes weren't UTF-8"
            case let .wrongCount(n): return "coefficient: expected 14 values, got \(n)"
            case let .badValue(s): return "coefficient: non-numeric value '\(s)'"
            }
        }
    }

    /// `glucoseSecretKey + last10(coeffUpdateTime) + last6(mac)`. A 16-char account key makes 32 bytes (AES-256).
    public static func deriveKey(glucoseSecretKey: String, coeffUpdateTime: Int64, mac: String) -> String {
        glucoseSecretKey + String(String(coeffUpdateTime).suffix(10)) + String(mac.suffix(6))
    }

    public static func parseCoefficients(_ plaintext: String) throws -> [Double] {
        let parts = plaintext
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 14 else { throw DecipherError.wrongCount(parts.count) }
        return try parts.map { s in
            guard let d = Double(s) else { throw DecipherError.badValue(s) }
            return d
        }
    }

    /// Full decipher: base64 → AES-256-ECB/PKCS7 → UTF-8 CSV → `[C0..C13]`.
    public static func decipher(
        base64Coefficient: String,
        coeffUpdateTime: Int64,
        mac: String,
        glucoseSecretKey: String
    ) throws -> [Double] {
        guard let ct = Data(base64Encoded: base64Coefficient) else { throw DecipherError.badBase64 }
        let key = deriveKey(glucoseSecretKey: glucoseSecretKey, coeffUpdateTime: coeffUpdateTime, mac: mac)
        let plain = try AESECB().decryptECB_PKCS7(ct, keyUTF8: key)
        guard let csv = String(data: plain, encoding: .utf8) else { throw DecipherError.notUTF8 }
        return try parseCoefficients(csv)
    }
}
