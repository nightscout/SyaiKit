//
//  Bundle+HostApp.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

public extension Bundle {
    /// The host app's display name ("Trio", "Loop", ...) for user-facing text.
    /// Named apart from other kits' `bundleDisplayName` so the extensions can't collide.
    var syaiHostAppName: String {
        object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "the app"
    }
}
