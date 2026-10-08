//
//  SyaiKitPlugin.swift
//  SyaiKitPlugin
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation
import LoopKitUI
import SyaiKit
import SyaiKitUI

public final class SyaiKitPlugin: NSObject, CGMManagerUIPlugin {
    public var pumpManagerType: PumpManagerUI.Type? {
        nil
    }

    public var cgmManagerType: CGMManagerUI.Type? {
        SyaiCGMManager.self
    }

    override public init() { super.init() }
}
