//
//  SyaiApplicatorCode.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// The QR code on a sensor applicator, which carries the sensor's MAC as plain
/// text.
public enum SyaiApplicatorCode {
    /// The MAC in the same form BLE discovery reports it (12 uppercase hex
    /// digits), or nil when the payload isn't a MAC, so a stray QR code is
    /// never mistaken for a sensor.
    public static func mac(fromPayload payload: String) -> String? {
        let stripped = payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0 != ":" && $0 != "-" }
        guard stripped.count == 12, stripped.allSatisfy(\.isHexDigit) else { return nil }
        return stripped.uppercased()
    }
}
