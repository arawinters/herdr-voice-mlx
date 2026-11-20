import Foundation

/// A JSON value that can cross actors. Tool schemas and wire messages arrive as JSON and go back out as JSON.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Converts a `JSONSerialization` result. Anything else is rejected rather than guessed at.
    public init(_ any: Any) throws {
        switch any {
        case is NSNull: self = .null
        case let number as NSNumber:
            // JSONSerialization returns booleans as NSNumber too; only CFBoolean is a real true/false.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
            else { self = .number(number.doubleValue) }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(try array.map(JSONValue.init))
        case let object as [String: Any]: self = .object(try object.mapValues(JSONValue.init))
        default: throw JSONError.unsupported
        }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONValue(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// A `JSONSerialization`-ready value.
    public var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value
        case .string(let value): value
        case .array(let values): values.map(\.any)
        case .object(let values): values.mapValues(\.any)
        }
    }

    public func data(sortedKeys: Bool = false) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        if sortedKeys { options.insert(.sortedKeys) }
        return try JSONSerialization.data(withJSONObject: any, options: options)
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let values) = self { return values[key] }
        return nil
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var array: [JSONValue]? { if case .array(let values) = self { values } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let values) = self { values } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }

    /// A JSON number that is a whole number a JavaScript client could send exactly (`Number.isSafeInteger`).
    public var safeInteger: Int? {
        guard case .number(let value) = self, value.rounded() == value, abs(value) <= 9_007_199_254_740_991 else { return nil }
        return Int(value)
    }

    public var number: Double? { if case .number(let value) = self { value } else { nil } }
}

public enum JSONError: Error { case unsupported }

/// Serializes a wire event. Events are built from literals, so a failure here is a programming error.
public func jsonLine(_ object: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
}
