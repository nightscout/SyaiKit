//
//  AESECB.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

#if canImport(CommonCrypto)
    import CommonCrypto

    /// AES-256-ECB / PKCS7 via CommonCrypto, used to unwrap the server's
    /// `coefficient` and `keyA` blobs. CryptoKit has no ECB, so this uses `CCCrypt`
    /// directly.
    ///
    /// ECB is safe *here* only because each payload block is distinct random-looking
    /// data and the scheme is fixed by the server; do not reuse this for anything new.
    public struct AESECB {
        public init() {}

        public enum AESError: Error, CustomStringConvertible {
            case badKeyLength(Int)
            case ccError(Int32)
            public var description: String {
                switch self {
                case let .badKeyLength(n): return "AES-ECB: key must be 16/24/32 bytes, got \(n)"
                case let .ccError(s): return "AES-ECB: CCCrypt failed (status \(s))"
                }
            }
        }

        public func decryptECB_PKCS7(_ ciphertext: Data, keyUTF8: String) throws -> Data {
            let keyData = Data(keyUTF8.utf8)
            switch keyData.count {
            case kCCKeySizeAES128,
                 kCCKeySizeAES192,
                 kCCKeySizeAES256: break
            default: throw AESError.badKeyLength(keyData.count)
            }

            var out = Data(count: ciphertext.count + kCCBlockSizeAES128)
            var moved = 0
            let status = out.withUnsafeMutableBytes { outPtr in
                ciphertext.withUnsafeBytes { ctPtr in
                    keyData.withUnsafeBytes { keyPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                            keyPtr.baseAddress, keyData.count,
                            nil, // ECB: no IV
                            ctPtr.baseAddress, ciphertext.count,
                            outPtr.baseAddress, outPtr.count,
                            &moved
                        )
                    }
                }
            }
            guard status == kCCSuccess else { throw AESError.ccError(status) }
            out.removeSubrange(moved ..< out.count)
            return out
        }

        /// AES-256-ECB / PKCS7 encrypt, the inverse of `decryptECB_PKCS7`, used to
        /// build the login `encryptInfo` payload. Same ECB caveat applies.
        public func encryptECB_PKCS7(_ plaintext: Data, keyUTF8: String) throws -> Data {
            let keyData = Data(keyUTF8.utf8)
            switch keyData.count {
            case kCCKeySizeAES128,
                 kCCKeySizeAES192,
                 kCCKeySizeAES256: break
            default: throw AESError.badKeyLength(keyData.count)
            }

            var out = Data(count: plaintext.count + kCCBlockSizeAES128)
            var moved = 0
            let status = out.withUnsafeMutableBytes { outPtr in
                plaintext.withUnsafeBytes { ptPtr in
                    keyData.withUnsafeBytes { keyPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                            keyPtr.baseAddress, keyData.count,
                            nil, // ECB: no IV
                            ptPtr.baseAddress, plaintext.count,
                            outPtr.baseAddress, outPtr.count,
                            &moved
                        )
                    }
                }
            }
            guard status == kCCSuccess else { throw AESError.ccError(status) }
            out.removeSubrange(moved ..< out.count)
            return out
        }

        /// Raw-key AES-ECB encrypt. `padding: false` requires 16-byte-aligned input,
        /// used by BLE notify frames and zero-padded activation writes; `padding: true`
        /// applies PKCS7 for HTTPS/login payloads.
        public func encryptECB(_ plaintext: Data, key: Data, padding: Bool) throws -> Data {
            try crypt(plaintext, key: key, operation: CCOperation(kCCEncrypt), padding: padding)
        }

        /// Raw-key AES-ECB decrypt. `padding: false` returns raw block-aligned BLE
        /// frames; `padding: true` strips PKCS7.
        public func decryptECB(_ ciphertext: Data, key: Data, padding: Bool) throws -> Data {
            try crypt(ciphertext, key: key, operation: CCOperation(kCCDecrypt), padding: padding)
        }

        private func crypt(_ input: Data, key: Data, operation: CCOperation, padding: Bool) throws -> Data {
            switch key.count {
            case kCCKeySizeAES128,
                 kCCKeySizeAES192,
                 kCCKeySizeAES256: break
            default: throw AESError.badKeyLength(key.count)
            }
            var options = CCOptions(kCCOptionECBMode)
            if padding { options |= CCOptions(kCCOptionPKCS7Padding) }

            var out = Data(count: input.count + kCCBlockSizeAES128)
            var moved = 0
            let status = out.withUnsafeMutableBytes { outPtr in
                input.withUnsafeBytes { inPtr in
                    key.withUnsafeBytes { keyPtr in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            options,
                            keyPtr.baseAddress, key.count,
                            nil, // ECB: no IV
                            inPtr.baseAddress, input.count,
                            outPtr.baseAddress, outPtr.count,
                            &moved
                        )
                    }
                }
            }
            guard status == kCCSuccess else { throw AESError.ccError(status) }
            out.removeSubrange(moved ..< out.count)
            return out
        }
    }
#endif
