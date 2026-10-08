//
//  DeviceInfo+Display.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import SyaiKit

extension DeviceInfo {
    var productName: String {
        deviceType == "X1" ? "Syai Ultra" : "Syai Tag"
    }
}
