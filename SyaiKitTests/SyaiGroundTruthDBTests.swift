//
//  SyaiGroundTruthDBTests.swift
//  SyaiKitTests
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

@testable import SyaiKit
import XCTest

/// Ground-truth regression: replays the official app's persisted glucose history
/// (a live SQLCipher DB pull for V1.6 and HTTP-upload captures for V1.7) through
/// the real Swift `SyaiFrameParser`/`SyaiGlucoseDecoder`.
///
/// The fixtures are a dense binary dump (see `readFixture` below), not the raw
/// capture: only the fields this test actually checks are kept (dataNo/frontIdx,
/// elapsed time, raw channel, temperature, computed glucose, raw frame bytes) —
/// no device MAC, no absolute timestamp, no other per-row metadata from the
/// original capture.
final class SyaiGroundTruthDBTests: XCTestCase {
    private static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    private struct FixtureRecord {
        let id: Int
        let elapsed: Int
        let raw: Int
        let temperature: Double
        let cgmGlucose: Double
        let origin: [UInt8]
    }

    private enum FixtureFormatError: Error, CustomStringConvertible {
        case badMagic
        case truncated
        var description: String {
            switch self {
            case .badMagic: return "fixture header magic mismatch"
            case .truncated: return "fixture file truncated"
            }
        }
    }

    /// Reads the dense binary ground-truth format: 4-byte magic, 1-byte format
    /// version, little-endian `UInt32` record count, then fixed-size records of
    /// `id:UInt16, elapsed:UInt32, raw:UInt32, temperature:Float32,
    /// cgmGlucose:Float32, origin:[UInt8]` (origin length fixed per fixture).
    private func readFixture(_ data: Data, magic: String, originLength: Int) throws -> [FixtureRecord] {
        let bytes = [UInt8](data)
        guard bytes.count >= 9, Array(bytes[0 ..< 4]) == Array(magic.utf8) else {
            throw FixtureFormatError.badMagic
        }
        let count = Int(bytes[5]) | Int(bytes[6]) << 8 | Int(bytes[7]) << 16 | Int(bytes[8]) << 24
        let recordSize = 2 + 4 + 4 + 4 + 4 + originLength
        guard bytes.count == 9 + count * recordSize else { throw FixtureFormatError.truncated }

        var records: [FixtureRecord] = []
        records.reserveCapacity(count)
        var offset = 9
        for _ in 0 ..< count {
            let id = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            let elapsed = Int(bytes[offset + 2]) | Int(bytes[offset + 3]) << 8
                | Int(bytes[offset + 4]) << 16 | Int(bytes[offset + 5]) << 24
            let raw = Int(bytes[offset + 6]) | Int(bytes[offset + 7]) << 8
                | Int(bytes[offset + 8]) << 16 | Int(bytes[offset + 9]) << 24
            let temperatureBits = UInt32(bytes[offset + 10]) | UInt32(bytes[offset + 11]) << 8
                | UInt32(bytes[offset + 12]) << 16 | UInt32(bytes[offset + 13]) << 24
            let cgmGlucoseBits = UInt32(bytes[offset + 14]) | UInt32(bytes[offset + 15]) << 8
                | UInt32(bytes[offset + 16]) << 16 | UInt32(bytes[offset + 17]) << 24
            let origin = Array(bytes[(offset + 18) ..< (offset + 18 + originLength)])
            records.append(FixtureRecord(
                id: id, elapsed: elapsed, raw: raw,
                temperature: Double(Float(bitPattern: temperatureBits)),
                cgmGlucose: Double(Float(bitPattern: cgmGlucoseBits)),
                origin: origin
            ))
            offset += recordSize
        }
        return records
    }

    private static let coefficientsV16: [Double] = [
        0.1,
        0.5,
        18.5,
        0.0,
        -0.0016,
        0.5053,
        0.1458,
        0.015,
        1.05,
        0.8,
        1.05,
        0.025,
        172_800.0,
        1.0
    ]
    private var calibrationV16: Calibration {
        Calibration(coefficients: Self.coefficientsV16, k: 1.0, b: 1.0)
    }

    func testV16FullSensorLifeAgainstLiveDBPull() throws {
        let url = Self.fixtureDir.appendingPathComponent("syai_glucose_dump_v16.bin")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("fixture not present locally: \(url.path)")
        }
        let records = try readFixture(data, magic: "SYV6", originLength: 12)
        XCTAssertGreaterThan(records.count, 1000, "sanity: expected the full multi-day pull")

        let parser = SyaiV16FrameParsing()
        let decoder = SyaiGlucoseDecoder()
        var checked = 0
        var mismatches: [(dataNo: Int, v2: Double, got: Double, want: Double)] = []

        for record in records {
            let raw = try parser.rawChannels(fromFramedRecord: Data(record.origin), parseVersion: "V1.6")
            XCTAssertEqual(raw.v0, Double(record.raw), accuracy: 1E-9, "dataNo \(record.id) v0")
            XCTAssertEqual(raw.v2, Double(record.elapsed), accuracy: 1E-9, "dataNo \(record.id) v2")

            let out = try decoder.glucose(from: raw, calibration: calibrationV16)
            checked += 1
            let wantMgDL = record.cgmGlucose * 18.0
            if abs(out.rawGlucoseMgDL - wantMgDL) > 0.051 * 18.0 {
                mismatches.append((record.id, Double(record.elapsed), out.rawGlucoseMgDL, wantMgDL))
            }
        }

        if !mismatches.isEmpty {
            let sample = mismatches.prefix(10).map {
                "dataNo=\($0.dataNo) v2=\($0.v2) got=\($0.got) want=\($0.want)"
            }.joined(separator: "; ")
            XCTFail("\(mismatches.count)/\(checked) V1.6 records mismatched: \(sample)")
        }
        print(
            "V1.6: \(checked - mismatches.count)/\(checked) exact "
                + "(real SyaiV16FrameParsing + SyaiGlucoseDecoder, not the Python port)"
        )
    }

    private static let coefficientsV17: [Double] = [
        0.1,
        0.5,
        18.5,
        0.0,
        -0.0014,
        0.5212,
        -0.2606,
        0.015,
        0.95,
        0.8,
        1.1,
        0.05,
        172_800.0,
        1.0
    ]
    private var calibrationV17: Calibration {
        Calibration(coefficients: Self.coefficientsV17, k: 1.0, b: 1.0)
    }

    func testV17ConsolidatedLogCapturesAgainstRealDecoder() throws {
        let url = Self.fixtureDir.appendingPathComponent("v17_consolidated.bin")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("V1.7 fixture not present locally: \(url.path)")
        }
        let records = try readFixture(data, magic: "SYV7", originLength: 13)
        XCTAssertGreaterThan(records.count, 100, "sanity: expected the consolidated multi-session set")

        let parser = SyaiV17FrameParsing()
        let decoder = SyaiGlucoseDecoder()
        var checked = 0
        var mismatches: [(frontIdx: Int, v2: Double, got: Double, want: Double)] = []

        for record in records.dropFirst() { // idx 0 is a warmup spike
            let raw = try parser.rawChannels(fromFramedRecord: Data(record.origin), parseVersion: "V1.7")
            XCTAssertEqual(raw.v0, Double(record.raw), accuracy: 1E-9, "frontIdx \(record.id) v0")
            XCTAssertEqual(raw.v2, Double(record.elapsed), accuracy: 1E-9, "frontIdx \(record.id) v2")

            let out = try decoder.glucose(from: raw, calibration: calibrationV17)
            checked += 1
            let wantMgDL = record.cgmGlucose * 18.0
            if abs(out.rawGlucoseMgDL - wantMgDL) > 0.051 * 18.0 {
                mismatches.append((record.id, Double(record.elapsed), out.rawGlucoseMgDL, wantMgDL))
            }
        }

        if !mismatches.isEmpty {
            let sample = mismatches.prefix(10).map {
                "frontIdx=\($0.frontIdx) v2=\($0.v2) got=\($0.got) want=\($0.want)"
            }.joined(separator: "; ")
            XCTFail("\(mismatches.count)/\(checked) V1.7 records mismatched: \(sample)")
        }
        print(
            "V1.7: \(checked - mismatches.count)/\(checked) exact "
                + "(real SyaiV17FrameParsing + SyaiGlucoseDecoder, not the Python port). "
                + "Max runSec in this set never reaches the 48h/C12 boundary."
        )
    }
}
