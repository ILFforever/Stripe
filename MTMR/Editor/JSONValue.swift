//
//  JSONValue.swift
//  Stripe
//
//  A loss-free JSON value for the editor. The editor works on raw JSON rather
//  than the parsed BarItemDefinition types, so keys it has no UI for survive a
//  round trip untouched.
//

import Foundation

enum JSONValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    // MARK: Accessors

    var string: String? {
        if case let .string(v) = self { return v }
        return nil
    }

    var number: Double? {
        if case let .number(v) = self { return v }
        return nil
    }

    var bool: Bool? {
        if case let .bool(v) = self { return v }
        return nil
    }

    var array: [JSONValue]? {
        if case let .array(v) = self { return v }
        return nil
    }

    var object: [String: JSONValue]? {
        if case let .object(v) = self { return v }
        return nil
    }

    // MARK: Parsing

    /// Parses JSON, allowing the // and /* */ comments that presets may contain.
    static func parse(_ text: String) throws -> JSONValue {
        let data = Data(text.stripComments().utf8)
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(any: object)
    }

    init(any value: Any) {
        switch value {
        case let n as NSNumber:
            // JSONSerialization returns booleans as NSNumber too; tell them apart.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map(JSONValue.init(any:)))
        case let o as [String: Any]:
            self = .object(o.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    // MARK: Printing

    /// Keys printed first, in this order, so saved presets read naturally.
    static let preferredKeyOrder = [
        "stripe", "bar", "type", "title", "align", "width", "symbol", "image", "style", "background", "bordered",
        "iconColor", "textColor", "fontSize", "fontWeight", "monospacedDigits", "cornerRadius",
        "source", "refreshInterval", "items", "actions", "when",
    ]

    func pretty(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case let .string(s):
            return JSONValue.quote(s)
        case let .number(n):
            if n.rounded() == n, abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
        case let .bool(b):
            return b ? "true" : "false"
        case .null:
            return "null"
        case let .array(values):
            if values.isEmpty { return "[]" }
            // Short arrays of scalars stay on one line, e.g. ["-c", "echo hi"].
            if values.allSatisfy({ $0.isScalar }) {
                let line = "[" + values.map { $0.pretty() }.joined(separator: ", ") + "]"
                if line.count <= 80 { return line }
            }
            return "[\n" + values.map { inner + $0.pretty(indent: indent + 1) }.joined(separator: ",\n") + "\n" + pad + "]"
        case let .object(dict):
            if dict.isEmpty { return "{}" }
            let body = JSONValue.orderedKeys(dict).map { key in
                inner + JSONValue.quote(key) + ": " + dict[key]!.pretty(indent: indent + 1)
            }
            return "{\n" + body.joined(separator: ",\n") + "\n" + pad + "}"
        }
    }

    private var isScalar: Bool {
        switch self {
        case .array, .object: return false
        default: return true
        }
    }

    static func orderedKeys(_ dict: [String: JSONValue]) -> [String] {
        let preferred = preferredKeyOrder.filter { dict[$0] != nil }
        let rest = dict.keys.filter { !preferredKeyOrder.contains($0) }.sorted()
        return preferred + rest
    }

    private static func quote(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
        let wrapped = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(wrapped.dropFirst().dropLast()) // strip the [ ] around the single element
    }
}

// MARK: Dotted-path access, e.g. "source.inline" or "when.script"

extension Dictionary where Key == String, Value == JSONValue {
    subscript(path path: String) -> JSONValue? {
        get {
            let parts = path.split(separator: ".").map(String.init)
            var current: JSONValue? = .object(self)
            for part in parts {
                current = current?.object?[part]
            }
            return current
        }
        set {
            self = Dictionary.setting(self, parts: path.split(separator: ".").map(String.init)[...], to: newValue)
        }
    }

    private static func setting(_ dict: [String: JSONValue], parts: ArraySlice<String>, to value: JSONValue?) -> [String: JSONValue] {
        guard let key = parts.first else { return dict }
        var dict = dict
        if parts.count == 1 {
            dict[key] = value
        } else {
            let child = dict[key]?.object ?? [:]
            let updated = setting(child, parts: parts.dropFirst(), to: value)
            // Drop containers that become empty, e.g. "when": {} after clearing its last field.
            dict[key] = updated.isEmpty ? nil : .object(updated)
        }
        return dict
    }
}
