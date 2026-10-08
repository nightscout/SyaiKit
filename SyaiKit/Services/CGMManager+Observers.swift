//
//  CGMManager+Observers.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

public protocol SyaiStateObserver: AnyObject {
    func syaiCGMManager(
        _ manager: SyaiCGMManager,
        didUpdate state: CGMManagerState,
        latestSample: GlucoseSample?
    )
}

public extension SyaiCGMManager {
    func addStateObserver(_ observer: SyaiStateObserver) { stateObservers.add(observer) }
    func removeStateObserver(_ observer: SyaiStateObserver) { stateObservers.remove(observer) }

    internal func notifyStateObservers() {
        Task { @MainActor in self.evaluateAlerts() }
        stateObservers.notify { [weak self] observer in
            guard let self else { return }
            observer.syaiCGMManager(self, didUpdate: self.state, latestSample: self.latestSample)
        }
    }
}

final class SyaiWeakObserverSet<Observer> {
    private let lock = NSLock()
    private var observers: [WeakBox] = []
    private struct WeakBox { weak var ref: AnyObject? }

    func add(_ observer: Observer) {
        let ref = observer as AnyObject
        lock.lock()
        observers.removeAll { $0.ref === ref || $0.ref == nil }
        observers.append(WeakBox(ref: ref))
        lock.unlock()
    }

    fileprivate func remove(_ observer: Observer) {
        let ref = observer as AnyObject
        lock.lock()
        observers.removeAll { $0.ref === ref || $0.ref == nil }
        lock.unlock()
    }

    func notify(_ body: @escaping (Observer) -> Void) {
        lock.lock()
        let snapshot = observers.compactMap { $0.ref as? Observer }
        observers.removeAll { $0.ref == nil }
        lock.unlock()
        DispatchQueue.main.async { for obs in snapshot { body(obs) } }
    }
}
