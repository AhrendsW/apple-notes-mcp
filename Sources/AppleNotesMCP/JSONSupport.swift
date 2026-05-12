import Foundation
import MCP

typealias MCPValue = Value

struct ToolError: Codable, Sendable {
    let code: String
    let message: String
    let details: [String: String]
}

enum NotesError: Error, Sendable {
    case typed(code: String, message: String, details: [String: String] = [:])

    var code: String {
        switch self {
        case .typed(let code, _, _): code
        }
    }

    var message: String {
        switch self {
        case .typed(_, let message, _): message
        }
    }

    var details: [String: String] {
        switch self {
        case .typed(_, _, let details): details
        }
    }
}

extension NotesError: LocalizedError {
    var errorDescription: String? { message }
}

func okValue(_ data: MCPValue, warnings: [String] = []) -> MCPValue {
    var object: [String: MCPValue] = [
        "ok": .bool(true),
        "data": data
    ]
    if !warnings.isEmpty {
        object["warnings"] = .array(warnings.map { .string($0) })
    }
    return .object(object)
}

func errorValue(code: String, message: String, details: [String: String] = [:]) -> MCPValue {
    .object([
        "ok": .bool(false),
        "error": .object([
            "code": .string(code),
            "message": .string(message),
            "details": .object(details.mapValues { .string($0) })
        ])
    ])
}

func valueToJSONString(_ value: MCPValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value),
          let string = String(data: data, encoding: .utf8)
    else { return "{}" }
    return string
}

extension Dictionary where Key == String, Value == MCPValue {
    func string(_ key: String) -> String? {
        self[key]?.stringValue
    }

    func requiredString(_ key: String, allowEmpty: Bool = false) throws -> String {
        guard let value = string(key), allowEmpty || !value.isEmpty else {
            throw NotesError.typed(
                code: "invalid_params",
                message: "Missing required string parameter: \(key)"
            )
        }
        return value
    }

    func bool(_ key: String, default defaultValue: Bool) -> Bool {
        self[key]?.boolValue ?? defaultValue
    }

    func int(_ key: String, default defaultValue: Int) -> Int {
        self[key]?.intValue ?? defaultValue
    }

    func double(_ key: String, default defaultValue: Double) -> Double {
        if let double = self[key]?.doubleValue { return double }
        if let int = self[key]?.intValue { return Double(int) }
        return defaultValue
    }
}

extension Array where Element == String {
    var mcpValue: MCPValue { .array(map { .string($0) }) }
}

func truncatedId(_ id: String?) -> String {
    guard let id else { return "" }
    return String(id.prefix(12))
}
