//
//  SyaiApplicatorScannerView.swift
//  SyaiKitUI
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import SwiftUI
import SyaiKit
import VisionKit

/// Reads the sensor MAC from the QR code on the applicator.
struct SyaiApplicatorScannerView: UIViewControllerRepresentable {
    var didScan: (_ mac: String) -> Void

    /// Whether scanning can be offered at all. Requires a device with a camera
    /// and a host app that declares camera usage: asking for camera access
    /// without `NSCameraUsageDescription` terminates the app.
    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
            // No camera here; the scan buttons deliver a fake MAC instead.
            return true
        #else
            return DataScannerViewController.isSupported
                && DataScannerViewController.isAvailable
                && Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
        #endif
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context _: Context) {
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator _: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(didScan: didScan)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let didScan: (String) -> Void
        private var handled = false

        init(didScan: @escaping (String) -> Void) {
            self.didScan = didScan
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems _: [RecognizedItem]) {
            guard !handled else { return }
            for item in addedItems {
                // Other QR codes in view are ignored rather than reported: the
                // scanner keeps looking until it sees a MAC.
                guard case let .barcode(barcode) = item,
                      let payload = barcode.payloadStringValue,
                      let mac = SyaiApplicatorCode.mac(fromPayload: payload)
                else { continue }
                handled = true
                scanner.stopScanning()
                didScan(mac)
                return
            }
        }
    }
}
