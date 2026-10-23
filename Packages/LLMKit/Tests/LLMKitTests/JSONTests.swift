import Foundation
import Testing
@testable import LLMKit

@Suite("JSONValue")
struct JSONValueTests {
    @Test("parses every JSON type")
    func parsesTypes() throws {
        let v = try JSONValue.parse(#"{"s":"x","n":1.5,"i":3,"b":true,"z":null,"a":[1,"two"],"o":{"k":"v"}}"#)
        #expect(v["s"]?.stringValue == "x")
        #expect(v["n"]?.doubleValue == 1.5)
        #expect(v["i"]?.intValue == 3)
        #expect(v["b"]?.boolValue == true)
        #expect(v["z"]?.isNull == true)
        #expect(v["a"]?[1]?.stringValue == "two")
        #expect(v["o"]?["k"]?.stringValue == "v")
        #expect(v["missing"] == nil)
        #expect(v["a"]?[9] == nil)
    }

    @Test("integers encode without a decimal point and keys are sorted")
    func encoding() {
        let v: JSONValue = ["b": 2, "a": 1.5, "c": "https://x/y"]
        #expect(v.encodedString() == #"{"a":1.5,"b":2,"c":"https://x/y"}"#)
    }

    @Test("round trip")
    func roundTrip() throws {
        let v: JSONValue = ["arr": [1, true, nil, "s"], "obj": ["x": -2]]
        #expect(try JSONValue.parse(v.encoded()) == v)
    }
}

@Suite("JSONSchema")
struct JSONSchemaTests {
    let schema = JSONSchema.object(properties: [
        .init("name", .string()),
        .init("verdict", .string(enumValues: ["correct", "wrong"])),
        .init("note", .nullable(.string())),
        .init("items", .array(of: .object(properties: [.init("x", .integer())])))
    ])

    @Test("objects close with additionalProperties false and require every property")
    func strictObjects() {
        let v = schema.jsonValue
        #expect(v["type"]?.stringValue == "object")
        #expect(v["additionalProperties"]?.boolValue == false)
        let required = v["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(required == ["name", "verdict", "note", "items"])
        let inner = v["properties"]?["items"]?["items"]
        #expect(inner?["additionalProperties"]?.boolValue == false)
        #expect(inner?["required"]?.arrayValue?.count == 1)
    }

    @Test("nullable becomes anyOf with null")
    func nullable() {
        let note = schema.jsonValue["properties"]?["note"]
        #expect(note?["anyOf"]?[0]?["type"]?.stringValue == "string")
        #expect(note?["anyOf"]?[1]?["type"]?.stringValue == "null")
    }

    @Test("enum values are emitted")
    func enums() {
        let verdict = schema.jsonValue["properties"]?["verdict"]
        #expect(verdict?["enum"]?.arrayValue?.compactMap(\.stringValue) == ["correct", "wrong"])
    }

    @Test("no unsupported constraint keywords are ever emitted")
    func noConstraints() {
        let text = schema.jsonValue.encodedString()
        for keyword in ["minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems", "pattern"] {
            #expect(!text.contains(keyword))
        }
    }
}
