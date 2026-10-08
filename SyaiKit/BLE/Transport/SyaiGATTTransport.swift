//
//  SyaiGATTTransport.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import CoreBluetooth
import Foundation

public protocol SyaiGATTTransport: AnyObject {
    var peripheralID: UUID { get }

    func read(_ characteristic: CBUUID) async throws -> Data

    func write(_ data: Data, to characteristic: CBUUID, withResponse: Bool) async throws

    func notifications(for characteristic: CBUUID) -> AsyncStream<Data>

    func disconnect()
}
