//
//  SyaiLoginError.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

public enum SyaiLoginErrorCode: String, Sendable {
    // Username and password related errors
    case invalidParams = "User_InvalidParams"

    // Account errors
    case accountDeleted = "User_Deleted"
    case accountDisabled = "User_Disabled"

    // Retry cooldown
    case failedRetryTimes = "User_FAILED_RETRY_TIMES"

    public var description: String {
        switch self {
        case .invalidParams:
            return String(
                localized: "incorrect username or password entered, please retry",
                comment: "login error: incorrect credentials"
            )
        case .accountDeleted:
            return String(localized: "your account has been deleted", comment: "login error: account deleted")
        case .accountDisabled:
            return String(localized: "your account has been disabled", comment: "login error: account disabled")
        case .failedRetryTimes:
            return String(
                localized: "too many attempts, please retry after 1 hour",
                comment: "login error: too many failed attempts"
            )
        }
    }
}

public extension SyaiEnvelopedClient {
    enum LoginError: Error, CustomStringConvertible {
        case noApiToken
        /// The response was HTTP 200 but response body was not correct.
        case malformedResponseBody(String)

        /// The server rejected the login with a business code
        case serverError(code: String, message: String?)

        /// The request never produced a business response and failed somewhere down the line
        case transportFailure(underlying: String)

        public var description: String {
            switch self {
            case .noApiToken:
                return String(
                    localized: "server returned no apiToken.",
                    comment: "login error: no api token"
                )
            case let .malformedResponseBody(m):
                return String(
                    localized: "server returned a malformed response body: \(m).",
                    comment: "login error: no malformed response body"
                )
            case let .serverError(code, message):
                guard let errorCode = SyaiLoginErrorCode(rawValue: code) else {
                    guard let message = message else {
                        // Server returned an error without a code or message.
                        return String(
                            localized: "please check your connection and try again.",
                            comment: "login error: generic failure"
                        )
                    }

                    // Use error message returned by server
                    return message
                }

                // Use our own localized error message
                return errorCode.description
            case .transportFailure:
                return String(
                    localized: "please check your connection and try again.",
                    comment: "login error: connection failure"
                )
            }
        }
    }
}
