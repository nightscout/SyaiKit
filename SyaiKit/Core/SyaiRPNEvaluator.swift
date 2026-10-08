//
//  SyaiRPNEvaluator.swift
//  SyaiKit
//
//  Copyright (c) 2026 Nightscout Foundation.
//  Licensed under the MIT License. See LICENSE in the project root.
//

import Foundation

struct SyaiRPNEvaluator {
    enum EvalError: Error, CustomStringConvertible {
        case unknownToken(String)
        case stackUnderflow(op: String)
        case emptyStatement
        case unresolvedRegister(String)

        var description: String {
            switch self {
            case let .unknownToken(t): return "RPN: unknown token '\(t)'"
            case let .stackUnderflow(op): return "RPN: stack underflow at '\(op)'"
            case .emptyStatement: return "RPN: empty statement"
            case let .unresolvedRegister(r): return "RPN: reference to unset register '\(r)'"
            }
        }
    }

    struct Environment {
        var values: [String: Double]

        init(v: [Double], c: [Double]) {
            var m: [String: Double] = [:]
            for (i, x) in v.enumerated() { m["V\(i)"] = x }
            for (i, x) in c.enumerated() { m["C\(i)"] = x }
            values = m
        }
    }

    static func evaluateProgram(_ program: String, environment: Environment) throws -> Double {
        let statements = program
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !statements.isEmpty else { throw EvalError.emptyStatement }

        var env = environment
        var last = 0.0
        for (index, statement) in statements.enumerated() {
            let value = try evaluateStatement(statement, environment: env)
            env.values["R\(index)"] = value
            last = value
        }
        return last
    }

    static func evaluateStatement(_ statement: String, environment: Environment) throws -> Double {
        var stack: [Double] = []
        let tokens = statement.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { throw EvalError.emptyStatement }

        for token in tokens {
            if token == "le" || token == "gt" {
                guard stack.count >= 3 else { throw EvalError.stackUnderflow(op: token) }
                let c = stack.removeLast()
                let b = stack.removeLast()
                let a = stack.removeLast()
                let holds = token == "le" ? (a <= b) : (a > b)
                stack.append(holds ? c : 0.0)
            } else if let op = BinaryOp(rawValue: token) {
                guard stack.count >= 2 else { throw EvalError.stackUnderflow(op: token) }
                let b = stack.removeLast()
                let a = stack.removeLast()
                stack.append(op.apply(a, b))
            } else if token == "rd" {
                guard stack.count >= 2 else { throw EvalError.stackUnderflow(op: token) }
                let digits = stack.removeLast()
                let value = stack.removeLast()
                let scale = pow(10.0, digits)
                stack.append((value * scale).rounded() / scale)
            } else if let literal = Double(token) {
                stack.append(literal)
            } else if let named = environment.values[token] {
                stack.append(named)
            } else if token.first == "R" || token.first == "V" || token.first == "C" {
                // Looks like a register/channel/coefficient reference but wasn't
                // in the environment; surface it distinctly so a program that
                // reads an unset register is an obvious bug, not a silent 0.
                throw EvalError.unresolvedRegister(token)
            } else {
                throw EvalError.unknownToken(token)
            }
        }
        guard let first = stack.first else { throw EvalError.emptyStatement }
        return first
    }

    private enum BinaryOp: String {
        case ad
        case ml
        case dv
        case sb
        case pw
        func apply(_ a: Double, _ b: Double) -> Double {
            switch self {
            case .ad: return a + b
            case .ml: return a * b
            case .dv: return b == 0 ? 0 : a / b
            case .sb: return a - b
            case .pw: return pow(a, b)
            }
        }
    }
}
