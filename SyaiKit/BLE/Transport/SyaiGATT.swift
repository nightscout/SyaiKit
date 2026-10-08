//
//  SyaiGATT.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import CoreBluetooth
import Foundation

public enum SyaiGATT {
    public static let deviceInfoService = CBUUID(string: "180A")
    public static let authService = CBUUID(string: "e06e1d43-1319-4ebf-94b0-5b0e5313b1f4")

    /// Also the advertised scan-filter UUID: an awake sensor advertises this
    /// service + its MAC in the manufacturer-specific data.
    public static let cgmService = CBUUID(string: "181F")

    /// Vendor control service, hosts `ctlDevice` + `ctlGluDataIdx`. Omitting it
    /// from `servicesToDiscover` makes `ctlDevice` undiscoverable and fails the
    /// first activation write with `characteristicNotFound`; easy to miss since
    /// every non-activation path lives in the other three services.
    public static let ctlService = CBUUID(string: "84c5b711-655a-460d-89ca-337dbc981857")

    public static let servicesToDiscover: [CBUUID] = [
        deviceInfoService, authService, cgmService, ctlService
    ]

    public static let softVersion = CBUUID(string: "2A28")

    /// "error info" is a routine status channel (`0x77XX` frames on every
    /// connect), so nothing here may latch a blocking fault. Distinguish it from
    /// the auth service's near-identically-named status characteristic
    /// (`cb627922-…5b99`); this one is `…6caa`.
    public static let errorInfo = CBUUID(string: "cb627922-4e79-42e3-b107-a10e816f6caa")

    /// Read for the auth `index`; written during activation.
    public static let currentTime = CBUUID(string: "2A2B")

    /// App-to-device auth parameter blob. `[write]`, 68 B, with response:
    /// `idx(2 LE) ‖ index(2 LE) ‖ pubX(32) ‖ pubY(32)`. `index` is the
    /// currentTime counter itself.
    public static let authHost = CBUUID(string: "1756ef6e-884b-4eb0-b646-f04ab18408f9")

    /// Device-to-app auth parameter blob. `[read]` only, no CCCD. 68 B:
    /// `idx(1) ‖ time(3) ‖ pubX(32) ‖ pubY(32)`, signature verified as
    /// `SHA256(keyGroup[idx] ‖ MAC ‖ pubX ‖ pubY ‖ time)`.
    public static let authDev = CBUUID(string: "86805092-92b5-4d8c-9d73-0785ff6f9147")

    /// Auth signature/flag. `[read,write]`: device sign in, app sign out (32 B).
    /// The preimage encodes currentTime as `00 ‖ wire[0] ‖ wire[1]`; using the raw
    /// 4-byte read gets the session kicked at the 60 s mark.
    public static let authFlag = CBUUID(string: "785022c6-08c0-48af-ad17-684bb889aa83")
    public static let newGlucose = CBUUID(string: "2AA7")
    public static let glucoseRecord = CBUUID(string: "69e4f45f-a180-422c-83c0-324146402112")
    public static let requestByCount = CBUUID(string: "ccecb015-6750-41fd-ba78-3fb77d350574")

    /// Lifecycle command/state channel. `[read,write]`, no notify. Read on every
    /// connect as the sensor's lifecycle state: 0 initialize, 1 self-test,
    /// 2 inactive, 3 activated/healthy, >= 4 latched fault. Byte 0 only; `04` is
    /// what the official app turns into "Reading Error / remove sensor now", and
    /// it never clears.
    public static let cmd = CBUUID(string: "d78d0706-c775-448d-8a78-01215e7c2e11")

    /// Device control. `[write]` under `ctlService`. Coefficient-frame target and
    /// the `08 19 1a 04 06` BLE-interval target. Also carries destructive vendor
    /// opcodes not modelled here — never write an unmodelled opcode.
    public static let ctlDevice = CBUUID(string: "6aa799b6-b374-4148-8f36-6d440c0ec203")
    public static let ctlGluDataIdx = CBUUID(string: "c8693b6f-f850-44cb-b9b4-ac87ed962bac")

    /// Activation duration. `[read,write]`, but under `deviceInfoService`, not the
    /// control service.
    public static let activeDuration = CBUUID(string: "b8fd9848-0ccd-423f-bd34-2419aa7ea004")

    public static func name(for uuid: CBUUID) -> String {
        names[uuid] ?? uuid.uuidString
    }

    private static let names: [CBUUID: String] = [
        softVersion: "softVersion",
        errorInfo: "errorInfo",
        currentTime: "currentTime",
        authHost: "authHost",
        authDev: "authDev",
        authFlag: "authFlag",
        newGlucose: "newGlucose",
        glucoseRecord: "glucoseRecord",
        requestByCount: "requestByCount",
        cmd: "cmd",
        ctlDevice: "ctlDevice",
        ctlGluDataIdx: "ctlGluDataIdx",
        activeDuration: "activeDuration"
    ]
}
