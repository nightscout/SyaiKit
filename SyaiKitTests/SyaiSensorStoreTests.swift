//
//  SyaiSensorStoreTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Covers the consolidated sensor store: `DeviceInfo`/`SyaiKeyGroup`/
/// `SyaiSensorRecord`/`SyaiSensorStore` rawState round-trips, and the
/// `adopt`/retire/history-cap semantics that back the "Sensor History" screen
/// and cross-relaunch reconnect.
final class SyaiSensorStoreTests: XCTestCase {
    private func makeDevice(mac: String, serial: String = "SER1") -> DeviceInfo {
        DeviceInfo(
            mac: mac, serialNo: serial, batchNo: "BATCH", deviceType: "X1",
            deviceVersion: "E2.0.1", coefficients: Calibration.appDefaultCoefficientsFixture,
            k: 1.25, b: -3.5, produceTime: Date(timeIntervalSince1970: 1_700_000_000),
            activeDuration: 14 * 24 * 3600, preheatDuration: 1800
        )
    }

    private func makeKeys(_ mac: String) -> SyaiKeyGroup {
        SyaiKeyGroup(raw: Data("keys-\(mac)".utf8))
    }

    func testKeyGroupBase64RoundTrip() {
        let keys = SyaiKeyGroup(raw: Data([0x00, 0x01, 0xFE, 0xFF, 0x42]))
        let restored = SyaiKeyGroup(rawValue: keys.rawValue)
        XCTAssertEqual(restored, keys)
        XCTAssertNil(SyaiKeyGroup(rawValue: "not base64!!"))
    }

    func testDeviceInfoRoundTrip() {
        let device = makeDevice(mac: "001122334455")
        let restored = DeviceInfo(rawValue: device.rawValue)
        XCTAssertEqual(restored, device)
    }

    func testDeviceInfoRejectsIncompleteRaw() {
        XCTAssertNil(DeviceInfo(rawValue: ["mac": "ABC"])) // no coefficients/k/b
    }

    func testRecordRoundTripWithKeysAndLifecycle() {
        var record = SyaiSensorRecord(
            deviceInfo: makeDevice(mac: "AA11BB22CC33"),
            keyGroup: makeKeys("AA11BB22CC33"),
            activatedAt: Date(timeIntervalSince1970: 1_710_000_000),
            retiredAt: Date(timeIntervalSince1970: 1_711_000_000),
            peripheralID: UUID()
        )
        let restored = SyaiSensorRecord(rawValue: record.rawValue)
        XCTAssertEqual(restored, record)

        record.retiredAt = nil
        record.peripheralID = nil
        XCTAssertEqual(SyaiSensorRecord(rawValue: record.rawValue), record)
    }

    /// `records` no longer lives in rawValue - only the index (`activeMAC`)
    /// does. Records are hydrated separately via `mergeHistory` from
    /// `SyaiSensorHistoryStore`'s file.
    func testStoreRawValueRoundTripsIndexOnly() {
        var store = SyaiSensorStore()
        store.adopt(
            makeDevice(mac: "AAA"),
            keyGroup: makeKeys("AAA"),
            peripheralID: UUID(),
            activatedAt: Date()
        )
        store.adopt(
            makeDevice(mac: "BBB"),
            keyGroup: makeKeys("BBB"),
            peripheralID: UUID(),
            activatedAt: Date()
        )
        let restored = SyaiSensorStore(rawValue: store.rawValue)
        XCTAssertEqual(restored?.activeMAC, store.activeMAC)
        XCTAssertEqual(restored?.records, [], "records live only in SyaiSensorHistoryStore now")
    }

    func testAdoptSetsActiveAndKeepsKeys() {
        var store = SyaiSensorStore()
        let keys = makeKeys("AAA")
        store.adopt(makeDevice(mac: "AAA"), keyGroup: keys, peripheralID: nil, activatedAt: nil)
        XCTAssertEqual(store.activeMAC, "AAA")
        XCTAssertEqual(store.current()?.keyGroup, keys)
        XCTAssertNil(store.current()?.retiredAt)
    }

    func testAdoptRetiresPreviousActive() {
        var store = SyaiSensorStore()
        store.adopt(makeDevice(mac: "AAA"), keyGroup: makeKeys("AAA"), peripheralID: nil, activatedAt: nil)
        store.adopt(makeDevice(mac: "BBB"), keyGroup: makeKeys("BBB"), peripheralID: nil, activatedAt: nil)

        XCTAssertEqual(store.activeMAC, "BBB")
        XCTAssertEqual(store.history().first?.mac, "BBB") // newest-first
        let retired = store.history().first { $0.mac == "AAA" }
        XCTAssertNotNil(retired?.retiredAt)
        XCTAssertNil(store.current()?.retiredAt)
    }

    func testReAdoptingSameMACRefreshesNotDuplicates() {
        var store = SyaiSensorStore()
        store.adopt(makeDevice(mac: "AAA", serial: "OLD"), keyGroup: makeKeys("AAA"), peripheralID: nil, activatedAt: nil)
        store.adopt(makeDevice(mac: "BBB"), keyGroup: makeKeys("BBB"), peripheralID: nil, activatedAt: nil)
        store.adopt(makeDevice(mac: "AAA", serial: "NEW"), keyGroup: makeKeys("AAA"), peripheralID: nil, activatedAt: nil)

        XCTAssertEqual(store.history().filter { $0.mac == "AAA" }.count, 1)
        XCTAssertEqual(store.current()?.deviceInfo.serialNo, "NEW")
        XCTAssertNil(store.current()?.retiredAt)
    }

    func testDiscardActiveKeepsInHistory() {
        var store = SyaiSensorStore()
        store.adopt(makeDevice(mac: "AAA"), keyGroup: makeKeys("AAA"), peripheralID: nil, activatedAt: nil)
        store.discardActive()
        XCTAssertNil(store.activeMAC)
        XCTAssertNil(store.current())
        XCTAssertEqual(store.history().count, 1) // retained for diagnostics
        XCTAssertNotNil(store.history().first?.retiredAt)
    }

    func testSetActivatedAtUpdatesActiveRecord() {
        var store = SyaiSensorStore()
        store.adopt(makeDevice(mac: "AAA"), keyGroup: makeKeys("AAA"), peripheralID: nil, activatedAt: nil)
        let t = Date(timeIntervalSince1970: 1_720_000_000)
        store.setActivatedAt(t)
        XCTAssertEqual(store.current()?.activatedAt, t)
    }

    func testUpdateActiveCalibrationRewritesCoeffsKB() {
        var store = SyaiSensorStore()
        store.adopt(makeDevice(mac: "AAA"), keyGroup: makeKeys("AAA"), peripheralID: nil, activatedAt: nil)
        let cal = Calibration(coefficients: Calibration.appDefaultCoefficientsFixture, k: 9.0, b: 8.0)
        store.updateActiveCalibration(cal)
        XCTAssertEqual(store.current()?.deviceInfo.k, 9.0)
        XCTAssertEqual(store.current()?.deviceInfo.b, 8.0)
        XCTAssertEqual(store.current()?.deviceInfo.serialNo, "SER1")
    }

    func testHistoryCapTrimsOldest() {
        var store = SyaiSensorStore()
        let total = SyaiSensorStore.historyCap + 5
        for i in 0 ..< total {
            store.adopt(
                makeDevice(mac: "MAC\(i)"),
                keyGroup: makeKeys("MAC\(i)"),
                peripheralID: nil,
                activatedAt: nil
            )
        }
        XCTAssertEqual(store.history().count, SyaiSensorStore.historyCap)
        XCTAssertEqual(store.activeMAC, "MAC\(total - 1)")
        XCTAssertEqual(store.history().first?.mac, "MAC\(total - 1)")
        XCTAssertFalse(store.history().contains { $0.mac == "MAC0" })
    }

    /// `CGMManagerState.rawValue` alone only round-trips the index
    /// (`activeMAC`) - `peripheralID`/`activatedAt` are computed
    /// pass-throughs over the active *record*, and records no longer live in
    /// rawState (see `SyaiSensorStore.rawValue`). A bare round trip is
    /// therefore intentionally incomplete; `SyaiCGMManager` always follows it
    /// with `mergeHistory` from the file-backed mirror.
    func testStateRawStateRoundTripPreservesIndexOnly() {
        var state = CGMManagerState()
        state.sensors.adopt(
            makeDevice(mac: "001122334455"),
            keyGroup: makeKeys("001122334455"),
            peripheralID: UUID(),
            activatedAt: Date(timeIntervalSince1970: 1_720_000_000)
        )
        state.lastGridSequence = 42

        let restored = CGMManagerState(rawValue: state.rawValue)
        XCTAssertEqual(restored?.mac, "001122334455") // the index survives
        XCTAssertNil(restored?.peripheralID, "records aren't in rawState anymore")
        XCTAssertNil(restored?.activatedAt, "records aren't in rawState anymore")
        XCTAssertEqual(restored?.lastGridSequence, 42) // unrelated field, unaffected
    }

    /// The realistic path: a bare rawValue round trip followed by merging in
    /// the file-backed records (what `SyaiCGMManager.init?(rawState:)`
    /// always does) fully restores the active sensor.
    func testStateRawStateRoundTripPlusHistoryMergeRestoresActiveSensor() throws {
        var state = CGMManagerState()
        state.sensors.adopt(
            makeDevice(mac: "001122334455"),
            keyGroup: makeKeys("001122334455"),
            peripheralID: UUID(),
            activatedAt: Date(timeIntervalSince1970: 1_720_000_000)
        )

        var restored = try XCTUnwrap(CGMManagerState(rawValue: state.rawValue))
        restored.sensors.mergeHistory(state.sensors.history())
        XCTAssertEqual(restored.peripheralID, state.peripheralID)
        XCTAssertEqual(restored.activatedAt, state.activatedAt)
        XCTAssertEqual(restored.sensors, state.sensors)
    }

    /// Records persisted before this field existed decode it as nil (absent
    /// key); a present blob round-trips verbatim through a real plist.
    func testRecordMethodBlobRoundTrip() throws {
        var record = SyaiSensorRecord(
            deviceInfo: makeDevice(mac: "AA11BB22CC33"), keyGroup: makeKeys("AA11BB22CC33")
        )
        let legacy = try XCTUnwrap(SyaiSensorRecord(rawValue: record.rawValue))
        XCTAssertNil(legacy.methodBlob)

        record.methodBlob = "QUJDQUJD"
        let data = try PropertyListSerialization.data(
            fromPropertyList: record.rawValue, format: .binary, options: 0
        )
        let raw = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let restored = try XCTUnwrap(SyaiSensorRecord(rawValue: raw))
        XCTAssertEqual(restored.methodBlob, "QUJDQUJD")
        XCTAssertEqual(restored, record)
    }

    /// `setMethodBlob` writes the active record only (the applyAttachOutcome
    /// path right after `adopt`).
    func testSetMethodBlobUpdatesActiveRecord() {
        var store = SyaiSensorStore()
        store.adopt(makeDevice(mac: "AAA"), keyGroup: makeKeys("AAA"), peripheralID: nil, activatedAt: nil)
        store.setMethodBlob("QUJD")
        XCTAssertEqual(store.current()?.methodBlob, "QUJD")
        store.discardActive()
        store.setMethodBlob("IGNORED")
        XCTAssertEqual(store.history().first?.methodBlob, "QUJD", "no active record ⇒ no write")
    }

    private func makePending(_ mac: String) -> SyaiPendingBind {
        SyaiPendingBind(mac: mac, deviceVersion: "V1.7.SH22601.3", activatedAt: Date(timeIntervalSince1970: 1_791_400_000))
    }

    func testSetPendingBindLookupAndReplace() {
        var store = SyaiSensorStore()
        XCTAssertNil(store.pendingBind)
        XCTAssertNil(store.pendingBind(forMAC: "AAA"))

        store.setPendingBind(makePending("AAA"))
        XCTAssertEqual(store.pendingBind, makePending("AAA"))
        XCTAssertEqual(store.pendingBind(forMAC: "AAA"), makePending("AAA"))
        XCTAssertNil(store.pendingBind(forMAC: "BBB"), "MAC-gated lookup")

        store.setPendingBind(makePending("BBB"))
        XCTAssertEqual(store.pendingBind, makePending("BBB"), "the next activation replaces it")
        XCTAssertNil(store.pendingBind(forMAC: "AAA"))
    }

    /// Adopting the pending MAC means its bind completed: the marker is discharged.
    func testAdoptClearsMatchingPendingBind() {
        var store = SyaiSensorStore()
        store.setPendingBind(makePending("AAA"))
        store.adopt(makeDevice(mac: "AAA"), keyGroup: makeKeys("AAA"), peripheralID: nil, activatedAt: nil)
        XCTAssertNil(store.pendingBind)
        XCTAssertEqual(store.activeMAC, "AAA")
    }

    /// Adopting a different MAC leaves the marker parked, so the activated
    /// sensor can still be bound later.
    func testAdoptOfOtherMACKeepsPendingBind() {
        var store = SyaiSensorStore()
        store.setPendingBind(makePending("AAA"))
        store.adopt(makeDevice(mac: "BBB"), keyGroup: makeKeys("BBB"), peripheralID: nil, activatedAt: nil)
        XCTAssertEqual(store.pendingBind(forMAC: "AAA"), makePending("AAA"))
    }

    /// `mergeHistory` backs `SyaiSensorHistoryStore`'s file-mirror fold-in on
    /// manager construction: it must add retired sensors a fresh/rehydrated
    /// manager doesn't already know about, without duplicating or displacing
    /// the live in-memory record for a MAC both sides share.
    func testMergeHistoryAddsUnknownRecords() {
        var store = SyaiSensorStore()
        store.adopt(
            makeDevice(mac: "AAA"),
            keyGroup: makeKeys("AAA"),
            peripheralID: nil,
            activatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let external = [
            SyaiSensorRecord(
                deviceInfo: makeDevice(mac: "BBB"),
                keyGroup: makeKeys("BBB"),
                activatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                retiredAt: Date(timeIntervalSince1970: 1_700_000_050)
            )
        ]
        store.mergeHistory(external)
        XCTAssertEqual(store.activeMAC, "AAA", "merge never changes what's active")
        XCTAssertEqual(Set(store.history().map(\.mac)), ["AAA", "BBB"])
        XCTAssertEqual(store.history().first?.mac, "AAA", "newest-first by activated/retired date")
    }

    func testMergeHistoryPrefersInMemoryOnCollision() {
        var store = SyaiSensorStore()
        store.adopt(
            makeDevice(mac: "AAA", serial: "LIVE"),
            keyGroup: makeKeys("AAA"),
            peripheralID: nil,
            activatedAt: nil
        )
        let stale = [
            SyaiSensorRecord(deviceInfo: makeDevice(mac: "AAA", serial: "STALE"), keyGroup: makeKeys("AAA"))
        ]
        store.mergeHistory(stale)
        XCTAssertEqual(store.history().filter { $0.mac == "AAA" }.count, 1)
        XCTAssertEqual(store.current()?.deviceInfo.serialNo, "LIVE")
    }

    func testMergeHistoryRespectsCap() {
        var store = SyaiSensorStore()
        let external = (0 ..< (SyaiSensorStore.historyCap + 5)).map { i in
            SyaiSensorRecord(
                deviceInfo: makeDevice(mac: "MAC\(i)"),
                keyGroup: makeKeys("MAC\(i)"),
                retiredAt: Date(timeIntervalSince1970: TimeInterval(i))
            )
        }
        store.mergeHistory(external)
        XCTAssertEqual(store.history().count, SyaiSensorStore.historyCap)
    }

    /// A record with no `retiredAt` was still active when its (now-deleted)
    /// CGM manager was torn down - deletion never retires anything. A fresh
    /// manager with no active sensor of its own should resume it, since
    /// re-pairing would fail server-side anyway.
    func testMergeHistoryResumesStillAliveUnretiredSensor() {
        var store = SyaiSensorStore()
        let stillAlive = SyaiSensorRecord(
            deviceInfo: makeDevice(mac: "AAA"), keyGroup: makeKeys("AAA"), activatedAt: Date()
        )
        store.mergeHistory([stillAlive])
        XCTAssertEqual(store.activeMAC, "AAA")
        XCTAssertEqual(store.current()?.mac, "AAA")
    }

    /// An unretired record whose wear window already ended shouldn't be
    /// silently resumed - there's nothing left to reconnect to.
    func testMergeHistoryDoesNotResumeExpiredSensor() {
        var store = SyaiSensorStore()
        let expired = SyaiSensorRecord(
            deviceInfo: makeDevice(mac: "AAA"), keyGroup: makeKeys("AAA"),
            activatedAt: Date(timeIntervalSince1970: 0)
        )
        store.mergeHistory([expired])
        XCTAssertNil(store.activeMAC)
    }

    /// A record with `retiredAt` set was explicitly ended (End Sensor /
    /// discardActive) - never auto-resumed regardless of wear window.
    func testMergeHistoryDoesNotResumeExplicitlyRetiredSensor() {
        var store = SyaiSensorStore()
        let retired = SyaiSensorRecord(
            deviceInfo: makeDevice(mac: "AAA"), keyGroup: makeKeys("AAA"),
            activatedAt: Date(), retiredAt: Date()
        )
        store.mergeHistory([retired])
        XCTAssertNil(store.activeMAC)
    }

    /// A manager that already has its own active sensor never has it displaced
    /// by a merge.
    func testMergeHistoryNeverOverridesExistingActive() {
        var store = SyaiSensorStore()
        store.adopt(makeDevice(mac: "LIVE"), keyGroup: makeKeys("LIVE"), peripheralID: nil, activatedAt: Date())
        let external = [
            SyaiSensorRecord(deviceInfo: makeDevice(mac: "OTHER"), keyGroup: makeKeys("OTHER"), activatedAt: Date())
        ]
        store.mergeHistory(external)
        XCTAssertEqual(store.activeMAC, "LIVE")
    }

    /// The pending-bind marker round-trips through rawState, and state
    /// persisted without the slot decodes it as nil.
    func testPendingBindRawStateRoundTrip() throws {
        var store = SyaiSensorStore()
        XCTAssertNil(
            SyaiSensorStore(rawValue: store.rawValue)?.pendingBind,
            "rawValue without the key decodes nil"
        )

        store.setPendingBind(makePending("AAA"))
        let data = try PropertyListSerialization.data(
            fromPropertyList: store.rawValue, format: .binary, options: 0
        )
        let raw = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let restored = try XCTUnwrap(SyaiSensorStore(rawValue: raw))
        XCTAssertEqual(restored.pendingBind, store.pendingBind)
        XCTAssertEqual(restored, store)
    }
}
