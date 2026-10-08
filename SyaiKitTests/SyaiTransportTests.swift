//
//  SyaiTransportTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import CoreBluetooth
import CryptoKit
@testable import SyaiKit
import XCTest

/// Unit tests for the pure (radio-free) logic of `SyaiBLE`: the
/// ECDH/key math, keyA→keyGroup unwrap, frame decrypt/split, version dispatch, the
/// dosing-safety seam, and the confirmed GATT constants.
final class SyaiTransportTests: XCTestCase {
    static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i ..< j], radix: 16)!)
            i = j
        }
        return out
    }

    func testSessionKeyIsOddBytesOfSharedSecret() {
        // secretX = 00 01 02 … 1F → odd-indexed bytes {01,03,…,1F} (16 bytes).
        let secretX = Data((0 ..< 32).map { UInt8($0) })
        let key = SyaiBLEAuthV2.sessionKey(fromSharedSecretX: secretX)
        XCTAssertEqual(key.count, 16)
        XCTAssertEqual([UInt8](key), (0 ..< 16).map { UInt8($0 * 2 + 1) })
    }

    func testKeyGroupSlicing() throws {
        // 96-byte group: byte value = 16*keyIndex + offset, so key(i) is all `16*i + j`.
        var raw = Data()
        for i in 0 ..< 6 { for j in 0 ..< 16 { raw.append(UInt8(16 * i + j)) } }
        let group = SyaiKeyGroup(raw: raw)
        let k2 = try SyaiBLEAuthV2.key(2, in: group)
        XCTAssertEqual([UInt8](k2), (0 ..< 16).map { UInt8(32 + $0) })
        // idx wraps mod 6.
        XCTAssertEqual(try SyaiBLEAuthV2.key(8, in: group), try SyaiBLEAuthV2.key(2, in: group))
    }

    func testKeyGroupBadLengthThrows() {
        XCTAssertThrowsError(try SyaiBLEAuthV2.key(0, in: SyaiKeyGroup(raw: Data(count: 32))))
    }

    func testMacBytes() {
        XCTAssertEqual(
            [UInt8](SyaiBLEAuthV2.macBytes("001122334455")),
            [0x00, 0x11, 0x22, 0x33, 0x44, 0x55]
        )
    }

    func testAppSignaturePreimageOrder() {
        // cx ‖ MAC ‖ pubX ‖ pubY ‖ currentTimeRaw — cx first.
        let sig = SyaiBLEAuthV2.appSignature(
            cx: Data([1]), mac: Data([2]), pubX: Data([3]), pubY: Data([4]), currentTimeRaw: Data([5])
        )
        let expected = Data(SHA256.hash(data: Data([1, 2, 3, 4, 5])))
        XCTAssertEqual(sig, expected)
    }

    /// Builds a real AES-256-ECB/PKCS7 `keyA` ciphertext under the same KDF
    /// `parseKeyGroup` derives internally, so these tests exercise the actual
    /// CommonCrypto round-trip rather than an injected fake.
    private func encryptedKeyA(
        plaintext: Data,
        respMac: String,
        produceTimeRaw: Int64,
        glucoseSecretKey: String
    ) throws -> String {
        let key = SyaiCoefficientDecipher.deriveKey(
            glucoseSecretKey: glucoseSecretKey, coeffUpdateTime: produceTimeRaw, mac: respMac
        )
        return try AESECB().encryptECB_PKCS7(plaintext, keyUTF8: key).base64EncodedString()
    }

    func testParseKeyGroupUnwraps96Bytes() throws {
        let ninetySix = Data((0 ..< 96).map { UInt8($0) })
        let keyA = try encryptedKeyA(
            plaintext: ninetySix,
            respMac: "001122334455",
            produceTimeRaw: 1_700_000_000_000,
            glucoseSecretKey: "SECRETKEY0000000"
        )
        let body: [String: Any] = ["keyA": keyA]
        let group = try SyaiServerCalibrationProvider.parseKeyGroup(
            body: body, respMac: "001122334455", produceTimeRaw: 1_700_000_000_000,
            glucoseSecretKey: "SECRETKEY0000000"
        )
        XCTAssertEqual(group.raw, ninetySix)
    }

    /// The decrypted keyA plaintext is a 192-char ASCII hex string of the 96 key bytes,
    /// not raw bytes. The beta run failed here ("keyA plaintext 192B, expected 96")
    /// before this was handled.
    func testParseKeyGroupUnwraps192HexPlaintext() throws {
        let ninetySix = Data((0 ..< 96).map { UInt8($0) })
        let hexString = ninetySix.map { String(format: "%02X", $0) }.joined()
        XCTAssertEqual(hexString.count, 192)
        let keyA = try encryptedKeyA(
            plaintext: Data(hexString.utf8),
            respMac: "001122334455",
            produceTimeRaw: 1_700_000_000_000,
            glucoseSecretKey: "SECRETKEY0000000"
        )
        let body: [String: Any] = ["keyA": keyA]
        let group = try SyaiServerCalibrationProvider.parseKeyGroup(
            body: body, respMac: "001122334455", produceTimeRaw: 1_700_000_000_000,
            glucoseSecretKey: "SECRETKEY0000000"
        )
        XCTAssertEqual(group.raw, ninetySix)
    }

    func testParseKeyGroupRejectsNonHex192Plaintext() throws {
        let keyA = try encryptedKeyA(
            plaintext: Data(repeating: 0x21, count: 192),
            respMac: "001122334455",
            produceTimeRaw: 1_700_000_000_000,
            glucoseSecretKey: "SECRETKEY0000000"
        )
        let body: [String: Any] = ["keyA": keyA]
        XCTAssertThrowsError(try SyaiServerCalibrationProvider.parseKeyGroup(
            body: body, respMac: "001122334455", produceTimeRaw: 1_700_000_000_000,
            glucoseSecretKey: "SECRETKEY0000000"
        ))
    }

    func testParseKeyGroupRejectsWrongLength() throws {
        let keyA = try encryptedKeyA(
            plaintext: Data(count: 80),
            respMac: "001122334455",
            produceTimeRaw: 1_700_000_000_000,
            glucoseSecretKey: "SECRETKEY0000000"
        )
        let body: [String: Any] = ["keyA": keyA]
        XCTAssertThrowsError(try SyaiServerCalibrationProvider.parseKeyGroup(
            body: body, respMac: "001122334455", produceTimeRaw: 1_700_000_000_000,
            glucoseSecretKey: "SECRETKEY0000000"
        ))
    }

    func testRecordLength() {
        XCTAssertEqual(SyaiFrameCipher.recordLength(parseVersion: "V1.7"), 9)
        XCTAssertEqual(SyaiFrameCipher.recordLength(parseVersion: "V1.5"), 8)
    }

    func testSplitProducesFramedRecords() throws {
        // 8-byte header `00 00 00 00 ‖ baseIndex LE16 (=5) ‖ flags(2)`,
        // then two 9-byte records plus an all-zero padding slot, which is skipped.
        var org = Data([0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00])
        org.append(Data((0 ..< 9).map { UInt8($0) }))
        org.append(Data((9 ..< 18).map { UInt8($0) }))
        org.append(Data(repeating: 0x00, count: 9))
        let records = try SyaiFrameCipher.split(org: org, recLen: 9)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].index, 5)
        XCTAssertEqual(records[1].index, 6)
        // framed = [00 00] ‖ index(2 LE) ‖ data(9) = 13 bytes.
        XCTAssertEqual(records[0].framed.count, 13)
        XCTAssertEqual([UInt8](records[0].framed.prefix(4)), [0x00, 0x00, 0x05, 0x00])
        XCTAssertEqual([UInt8](records[0].framed.suffix(9)), (0 ..< 9).map { UInt8($0) })
    }

    func testAESRoundTripRawKey() throws {
        let aes = AESECB()
        let key = Data((0 ..< 16).map { UInt8($0) })
        let block = Data(repeating: 0x5A, count: 16)
        let ct = try aes.encryptECB(block, key: key, padding: false)
        XCTAssertEqual(try aes.decryptECB(ct, key: key, padding: false), block)
        let short = Data([0x06])
        let ctp = try aes.encryptECB(short, key: key, padding: true)
        XCTAssertEqual(try aes.decryptECB(ctp, key: key, padding: true), short)
    }

    func testParseVersionDispatch() {
        XCTAssertEqual(SyaiFrameParser.parseVersion(forDeviceVersion: "E2.0.1(V1.7.SH22537.1)"), "V1.7")
        XCTAssertEqual(SyaiFrameParser.parseVersion(forDeviceVersion: "x V1.6 y"), "V1.6")
        XCTAssertEqual(SyaiFrameParser.parseVersion(forDeviceVersion: "unknown"), "V1.5")
        XCTAssertEqual(SyaiFrameParser.parseVersion(forDeviceVersion: "E2.1.0(V1.8.SH30101.1)"), "V1.7")
        XCTAssertEqual(SyaiFrameParser.parseVersion(forDeviceVersion: "E3.0.0(V2.0.SH30101.1)"), "V1.7")
        XCTAssertEqual(SyaiFrameParser.parseVersion(forDeviceVersion: "E1.0.0(V1.5.SH20101.1)"), "V1.5")
    }

    func testOnlyDecodableVersionsAreVerified() {
        XCTAssertTrue(SyaiFrameParser.isVerified(parseVersion: "V1.7"))
        XCTAssertTrue(SyaiFrameParser.isVerified(parseVersion: "V1.6"))
        XCTAssertFalse(SyaiFrameParser.isVerified(parseVersion: "V1.5"))
    }

    /// Firmware past V1.8/V2.0 has no known profile, so pairing must refuse it.
    func testNewerFirmwareIsNotVerified() {
        for version in ["E2.2.0(V1.9.SH30101.1)", "E3.1.0(V2.1.SH30101.1)", "E4.0.0(V3.0.SH30101.1)"] {
            let parseVersion = SyaiFrameParser.parseVersion(forDeviceVersion: version)
            XCTAssertFalse(SyaiFrameParser.isVerified(parseVersion: parseVersion), version)
        }
    }

    func testUnverifiedParsingIsAHardSeam() {
        // The dosing safety gate: no verified parser → no glucose, ever.
        XCTAssertThrowsError(
            try SyaiUnverifiedFrameParsing().rawChannels(fromFramedRecord: Data(count: 13), parseVersion: "V1.7")
        ) { error in
            guard case SyaiFrameParser.ParseError.notVerified = error else {
                return XCTFail("expected .notVerified, got \(error)")
            }
        }
    }

    func testAdvertisedMACDropsCompanyID() {
        let mfg = Data([0xAB, 0xCD, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55])
        XCTAssertEqual(SyaiBLECentral.advertisedMAC(fromManufacturerData: mfg), "001122334455")
        XCTAssertNil(SyaiBLECentral.advertisedMAC(fromManufacturerData: Data([0x01])))
    }

    func testGATTConstants() {
        XCTAssertEqual(SyaiGATT.cgmService, CBUUID(string: "181F"))
        XCTAssertEqual(SyaiGATT.currentTime, CBUUID(string: "2A2B"))
        XCTAssertEqual(SyaiGATT.ctlDevice, CBUUID(string: "6aa799b6-b374-4148-8f36-6d440c0ec203"))
        XCTAssertEqual(SyaiGATT.cmd, CBUUID(string: "d78d0706-c775-448d-8a78-01215e7c2e11"))
    }

    /// Renders characteristics by name. Pin the ones the auth + activation sequences
    /// touch, plus the fallback.
    func testGATTCharacteristicNames() {
        XCTAssertEqual(SyaiGATT.name(for: SyaiGATT.ctlDevice), "ctlDevice")
        XCTAssertEqual(SyaiGATT.name(for: SyaiGATT.authHost), "authHost")
        XCTAssertEqual(SyaiGATT.name(for: SyaiGATT.authDev), "authDev")
        XCTAssertEqual(SyaiGATT.name(for: SyaiGATT.authFlag), "authFlag")
        XCTAssertEqual(SyaiGATT.name(for: SyaiGATT.cmd), "cmd")
        XCTAssertEqual(SyaiGATT.name(for: SyaiGATT.activeDuration), "activeDuration")
        XCTAssertEqual(SyaiGATT.name(for: SyaiGATT.newGlucose), "newGlucose")
        XCTAssertEqual(
            SyaiGATT.name(for: CBUUID(string: "FFFF")),
            "FFFF",
            "unknown UUIDs fall back to their CBUUID string"
        )
    }

    /// The dump's hex rendering is the lowercase no-separator form, so log lines
    /// diff cleanly against captures.
    func testDiagnosticsHexRendering() {
        XCTAssertEqual(SyaiDiagnostics.hex(Data([0x08, 0x19, 0x1A, 0x04, 0x06])), "08191a0406")
        XCTAssertEqual(SyaiDiagnostics.hex(Data()), "")
    }

    /// Verbose BLE logging is opt-in in every build. Restores the key afterwards —
    /// it's process-wide UserDefaults.
    func testDiagnosticsGates() {
        let defaults = UserDefaults.standard
        let verboseKey = "SyaiDiagnostics.verboseBLELogging"
        let priorVerbose = defaults.object(forKey: verboseKey)
        defer {
            if let priorVerbose { defaults.set(priorVerbose, forKey: verboseKey) }
            else { defaults.removeObject(forKey: verboseKey) }
        }

        defaults.removeObject(forKey: verboseKey)
        XCTAssertFalse(SyaiDiagnostics.verboseBLELogging, "extra BLE/wire chatter is opt-in")
    }
}
