//
//  SyaiTelemetryService+ConnState.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

public extension SyaiTelemetryService {
    /// Report one link transition via `GET device/updateDeviceConnState`. Body is exactly
    /// `{"mac": …}` with no state field; the transition is conveyed by the endpoint itself.
    /// Also buffers a `cgm_connect`/`cgm_disconnect` event. Fire-and-forget: no-op when opted
    /// out or there is no active sensor; failures are log-only.
    func reportConnState(connected: Bool) {
        guard tier().reportsSensorHealth else { return }
        guard let mac = sensorContext()?.mac else { return }
        if let account = accountContext() {
            bufferEvent(
                eventType: "flutter_cgm_event",
                eventName: connected ? "cgm_connect" : "cgm_disconnect",
                eventInfo: Self.connEventInfo(mac: mac, connected: connected),
                account: account
            )
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sendConnState(mac)
                self.logger.debug("conn-state reported (mac=\(SyaiRedact.mac(mac)))")
            } catch {
                self.logger.warning("conn-state report failed (ignored): \(String(describing: error))")
            }
            // Re-persist any token rotation the send triggered, same
            // contract as the uploader, success or failure.
            await self.forwardSessionRotation()
        }
    }
}

public extension SyaiEnvelopedClient {
    /// GET `device/updateDeviceConnState`, the conn-state beacon. Body is exactly `{"mac": …}`;
    /// the transition is conveyed by the endpoint, not the payload. It's a GET, not a POST:
    /// a POST returns `{"code":"Error","data":"MethodNotAllowed"}`.
    func updateDeviceConnState(mac: String) async throws {
        guard backend.isConfigured else { throw TransportError.notConfigured }
        try await ensureAccessToken() // gated call: needs a live Authorization token
        _ = try await envelopedGET(path: "device/updateDeviceConnState", body: ["mac": mac])
    }
}
