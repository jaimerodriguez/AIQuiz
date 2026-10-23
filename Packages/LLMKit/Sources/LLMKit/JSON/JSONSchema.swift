import Foundation

/// A small JSON Schema builder restricted to the subset both Anthropic structured outputs
/// and OpenAI strict mode accept: every object closes with `additionalProperties: false`,
/// every property is listed in `required`, and optional fields are expressed as
/// `anyOf: [T, null]`. No numeric or string-length constraints are emitted (SPEC §8.4).
public indirect enum JSONSchema: Sendable, Hashable {
    case string(description: String? = nil, enumValues: [String]? = nil)
    case integer(description: String? = nil)
    case number(description: String? = nil)
    case boolean(description: String? = nil)
    case array(of: JSONSchema, description: String? = nil)
    case object(properties: [Property], description: String? = nil)
    /// The value may be `null`. The property is still required (strict-mode compatible).
    case nullable(JSONSchema)

    public struct Property: Sendable, Hashable {
        public let name: String
        public let schema: JSONSchema

        public init(_ name: String, _ schema: JSONSchema) {
            self.name = name
            self.schema = schema
        }
    }

    public var jsonValue: JSONValue {
        switch self {
        case .string(let description, let enumValues):
            var o: [String: JSONValue] = ["type": "string"]
            if let enumValues { o["enum"] = .array(enumValues.map { .string($0) }) }
            if let description { o["description"] = .string(description) }
            return .object(o)
        case .integer(let description):
            return Self.leaf("integer", description)
        case .number(let description):
            return Self.leaf("number", description)
        case .boolean(let description):
            return Self.leaf("boolean", description)
        case .array(let items, let description):
            var o: [String: JSONValue] = ["type": "array", "items": items.jsonValue]
            if let description { o["description"] = .string(description) }
            return .object(o)
        case .object(let properties, let description):
            var props: [String: JSONValue] = [:]
            for p in properties { props[p.name] = p.schema.jsonValue }
            var o: [String: JSONValue] = [
                "type": "object",
                "properties": .object(props),
                "required": .array(properties.map { .string($0.name) }),
                "additionalProperties": false
            ]
            if let description { o["description"] = .string(description) }
            return .object(o)
        case .nullable(let inner):
            return ["anyOf": [inner.jsonValue, ["type": "null"]]]
        }
    }

    /// Human-readable schema for prompts on endpoints without native structured output.
    public var promptText: String {
        jsonValue.encodedString(pretty: true)
    }

    private static func leaf(_ type: String, _ description: String?) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string(type)]
        if let description { o["description"] = .string(description) }
        return .object(o)
    }
}
