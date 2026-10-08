//
//  SyaiBLEPeripheral.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@preconcurrency import CoreBluetooth
import Foundation

public final class SyaiBLEPeripheral: NSObject, SyaiGATTTransport, @unchecked Sendable {
    private enum PeripheralError: Error, CustomStringConvertible {
        case characteristicNotFound(CBUUID)
        case readFailed(String)
        case writeFailed(String)
        case disconnected
        case timeout
        var description: String {
            switch self {
            case let .characteristicNotFound(u): return "characteristic \(u) not found on sensor"
            case let .readFailed(m): return "GATT read failed: \(m)"
            case let .writeFailed(m): return "GATT write failed: \(m)"
            case .disconnected: return "sensor disconnected"
            case .timeout: return "GATT request timed out waiting on a response"
            }
        }
    }

    private static let defaultTimeout: TimeInterval = 5
    private static let glucoseStreams: Set<CBUUID> = [SyaiGATT.newGlucose, SyaiGATT.glucoseRecord]

    let peripheral: CBPeripheral
    private weak var manager: CBCentralManager?
    private let queue: DispatchQueue
    private let logger = SyaiLogger(category: "SyaiBLEPeripheral")

    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var notifyStreams: [CBUUID: [UUID: AsyncStream<Data>.Continuation]] = [:]
    private var disconnected = false

    private struct PendingRequest<Value> {
        let id: UUID
        let continuation: CheckedContinuation<Value, Error>
        let timeoutItem: DispatchWorkItem
    }

    private var pendingReads: [CBUUID: [PendingRequest<Data>]] = [:]
    private var pendingWrites: [CBUUID: [PendingRequest<Void>]] = [:]

    private var discoveryCompletion: ((Result<Void, Error>) -> Void)?
    private var outstandingServices = 0
    private var discoveryError: Error?

    public var peripheralID: UUID { peripheral.identifier }

    init(peripheral: CBPeripheral, manager: CBCentralManager, queue: DispatchQueue) {
        self.peripheral = peripheral
        self.manager = manager
        self.queue = queue
        super.init()
        peripheral.delegate = self
    }

    func beginDiscovery(completion: @escaping (Result<Void, Error>) -> Void) {
        discoveryCompletion = completion
        peripheral.discoverServices(SyaiGATT.servicesToDiscover)
    }

    private func finishDiscovery(_ result: Result<Void, Error>) {
        guard let completion = discoveryCompletion else { return }
        discoveryCompletion = nil
        completion(result)
    }

    public func read(_ characteristic: CBUUID) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard !self.disconnected else { return cont.resume(throwing: PeripheralError.disconnected) }
                guard let c = self.characteristics[characteristic] else {
                    return cont.resume(throwing: PeripheralError.characteristicNotFound(characteristic))
                }

                let requestId = UUID()

                let timeoutItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    guard var list = self.pendingReads[characteristic],
                          let idx = list.firstIndex(where: { $0.id == requestId }) else { return }
                    let entry = list.remove(at: idx)
                    self.pendingReads[characteristic] = list
                    entry.continuation.resume(throwing: PeripheralError.timeout)
                }

                self.pendingReads[characteristic, default: []]
                    .append(PendingRequest(id: requestId, continuation: cont, timeoutItem: timeoutItem))

                self.peripheral.readValue(for: c)

                self.queue.asyncAfter(deadline: .now() + Self.defaultTimeout, execute: timeoutItem)
            }
        }
    }

    public func write(_ data: Data, to characteristic: CBUUID, withResponse: Bool) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.disconnected else { return cont.resume(throwing: PeripheralError.disconnected) }
                guard let c = self.characteristics[characteristic] else {
                    return cont.resume(throwing: PeripheralError.characteristicNotFound(characteristic))
                }

                self.logger.debug(
                    "GATT write \(SyaiGATT.name(for: characteristic)) "
                        + "[\(withResponse ? "ack" : "no-ack")] \(data.count) B: \(SyaiDiagnostics.hex(data))"
                )
                if !withResponse {
                    self.peripheral.writeValue(data, for: c, type: .withoutResponse)
                    cont.resume()
                    return
                }

                let requestId = UUID()

                let timeoutItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    guard var list = self.pendingWrites[characteristic],
                          let idx = list.firstIndex(where: { $0.id == requestId }) else { return }
                    let entry = list.remove(at: idx)
                    self.pendingWrites[characteristic] = list
                    entry.continuation.resume(throwing: PeripheralError.timeout)
                }

                self.pendingWrites[characteristic, default: []]
                    .append(PendingRequest(id: requestId, continuation: cont, timeoutItem: timeoutItem))

                self.peripheral.writeValue(data, for: c, type: .withResponse)

                self.queue.asyncAfter(deadline: .now() + Self.defaultTimeout, execute: timeoutItem)
            }
        }
    }

    public func notifications(for characteristic: CBUUID) -> AsyncStream<Data> {
        let id = UUID()
        return AsyncStream { continuation in
            // Without termination cleanup a cancelled consumer leaves its
            // continuation registered (and buffering every notify) until the
            // next disconnect. Both the insert and the remove run on the same
            // serial queue, so a termination can never be lost behind the
            // registration.
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    self.notifyStreams[characteristic]?.removeValue(forKey: id)
                }
            }
            queue.async {
                guard !self.disconnected, let c = self.characteristics[characteristic] else {
                    continuation.finish()
                    return
                }
                self.notifyStreams[characteristic, default: [:]][id] = continuation
                self.peripheral.setNotifyValue(true, for: c)
            }
        }
    }

    public func disconnect() {
        queue.async {
            guard !self.disconnected else { return }
            self.manager?.cancelPeripheralConnection(self.peripheral)
        }
    }

    func handleDisconnect() {
        guard !disconnected else { return }
        disconnected = true
        notifyStreams.values.flatMap(\.values).forEach { $0.finish() }
        notifyStreams.removeAll()
        pendingReads.values.flatMap { $0 }.forEach { $0.continuation.resume(throwing: PeripheralError.disconnected) }
        pendingReads.removeAll()
        pendingWrites.values.flatMap { $0 }.forEach { $0.continuation.resume(throwing: PeripheralError.disconnected) }
        pendingWrites.removeAll()
        finishDiscovery(.failure(PeripheralError.disconnected))
    }
}

extension SyaiBLEPeripheral: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { return finishDiscovery(.failure(error)) }
        let services = peripheral.services ?? []
        outstandingServices = services.count
        guard outstandingServices > 0 else { return finishDiscovery(.failure(PeripheralError.disconnected)) }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(
        _: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error { discoveryError = error }
        for c in service.characteristics ?? [] {
            characteristics[c.uuid] = c
        }
        outstandingServices -= 1
        if outstandingServices <= 0 {
            if let e = discoveryError { finishDiscovery(.failure(e)) }
            else { finishDiscovery(.success(())) }
        }
    }

    public func peripheral(
        _: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = characteristic.uuid
        if var waiting = pendingReads[uuid], !waiting.isEmpty {
            let entry = waiting.removeFirst()
            entry.timeoutItem.cancel()
            let cont = entry.continuation

            pendingReads[uuid] = waiting
            if let error { cont.resume(throwing: PeripheralError.readFailed(error.localizedDescription)) }
            else {
                let value = characteristic.value ?? Data()
                logger.debug("GATT read \(SyaiGATT.name(for: uuid)) \(value.count) B: \(SyaiDiagnostics.hex(value))")
                cont.resume(returning: value)
            }
            return
        }
        guard error == nil, let value = characteristic.value else { return }
        // The glucose streams are logged decoded, one line per record, by the
        // monitor; their raw ciphertext is opt-in. Everything else is rare.
        if !Self.glucoseStreams.contains(uuid) || SyaiDiagnostics.verboseBLELogging {
            logger.debug("GATT notify \(SyaiGATT.name(for: uuid)) \(value.count) B: \(SyaiDiagnostics.hex(value))")
        }
        notifyStreams[uuid]?.values.forEach { $0.yield(value) }
    }

    public func peripheral(
        _: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            logger.error(
                "notify enable failed for \(SyaiGATT.name(for: characteristic.uuid)): "
                    + "\(error.localizedDescription); ending the stream so the link recovers via reconnect"
            )
            // The data path is dead either way; finishing the streams takes the
            // standard monitor-disconnect recovery rather than sitting silent
            // until the stale watchdog notices minutes later.
            notifyStreams[characteristic.uuid]?.values.forEach { $0.finish() }
            notifyStreams.removeValue(forKey: characteristic.uuid)
        } else {
            logger.debug(
                "notify \(characteristic.isNotifying ? "enabled" : "disabled") for \(SyaiGATT.name(for: characteristic.uuid))"
            )
        }
    }

    public func peripheral(
        _: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard var waiting = pendingWrites[characteristic.uuid], !waiting.isEmpty else { return }
        let entry = waiting.removeFirst()
        entry.timeoutItem.cancel()
        let cont = entry.continuation

        pendingWrites[characteristic.uuid] = waiting
        if let error { cont.resume(throwing: PeripheralError.writeFailed(error.localizedDescription)) }
        else { cont.resume() }
    }
}
