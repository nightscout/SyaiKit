//
//  SyaiSessionRetrying.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

/// Shared auth-failure recovery + token-rotation persistence policy for
/// account-backed clients. Telemetry doesn't retry synchronously (it queues and
/// backs off instead), so it only ever needs `forwardRotation`.
struct SyaiSessionRetrying: Sendable {
    let session: URLSession
    let onSessionRotated: (@Sendable(SyaiCredentials, String?) -> Void)?
    let recoverSession: (@Sendable() async -> SyaiBackend?)?
    let onAccountLockoutChanged: (@Sendable(Bool) -> Void)?

    init(
        session: URLSession,
        onSessionRotated: (@Sendable(SyaiCredentials, String?) -> Void)?,
        recoverSession: (@Sendable() async -> SyaiBackend?)?,
        onAccountLockoutChanged: (@Sendable(Bool) -> Void)? = nil
    ) {
        self.session = session
        self.onSessionRotated = onSessionRotated
        self.recoverSession = recoverSession
        self.onAccountLockoutChanged = onAccountLockoutChanged
    }

    /// Runs `work`. On `TransportError.isAuthFailure`, recovers one fresh session
    /// via `recoverSession` and retries once; any other error, or a failed/
    /// absent recovery, rethrows. Forwards token rotation and account-lockout
    /// state after every call, success or failure. `AuthFailed_LoginElsewhere`
    /// no longer qualifies as `isAuthFailure` (see `TransportError`), so it must
    /// still be reported here even though it skips the recovery attempt below.
    func run<T>(
        client: SyaiEnvelopedClient, backend: SyaiBackend,
        _ work: (SyaiEnvelopedClient, SyaiBackend) async throws -> T
    ) async throws -> T {
        do {
            let result = try await work(client, backend)
            await Self.forwardRotation(
                client, onSessionRotated: onSessionRotated, onAccountLockoutChanged: onAccountLockoutChanged
            )
            return result
        } catch let error as SyaiEnvelopedClient.TransportError {
            await Self.forwardRotation(
                client, onSessionRotated: onSessionRotated, onAccountLockoutChanged: onAccountLockoutChanged
            )
            guard error.isAuthFailure, let recoverSession, let freshBackend = await recoverSession() else {
                throw error
            }
            let freshClient = SyaiEnvelopedClient(backend: freshBackend, urlSession: session)
            let result = try await work(freshClient, freshBackend)
            await Self.forwardRotation(
                freshClient, onSessionRotated: onSessionRotated, onAccountLockoutChanged: onAccountLockoutChanged
            )
            return result
        }
    }

    /// Re-persist any token rotation and account-lockout state that changed during a client call.
    static func forwardRotation(
        _ client: SyaiEnvelopedClient,
        onSessionRotated: (@Sendable(SyaiCredentials, String?) -> Void)?,
        onAccountLockoutChanged: (@Sendable(Bool) -> Void)? = nil
    ) async {
        if let onSessionRotated {
            let rotated = await client.currentCredentials
            let gsk = await client.currentGlucoseSecretKey
            onSessionRotated(rotated, gsk)
        }
        if let onAccountLockoutChanged {
            onAccountLockoutChanged(await client.isAccountLockedOutElsewhere)
        }
    }
}
