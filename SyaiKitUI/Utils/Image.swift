//
//  Image.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import SwiftUI

extension Image {
    init(imageName: String) {
        let bundle = Bundle(for: SyaiUIController.self)
        if UIImage(named: imageName, in: bundle, compatibleWith: nil) != nil {
            self.init(imageName, bundle: bundle)
        } else {
            self.init(systemName: "sensor.tag.radiowaves.forward")
        }
    }
}
