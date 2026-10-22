import Foundation
import Testing
@testable import LLMKit

private struct Verdict: Decodable { let verdict: String; let reason: String }
private struct Wrapper: Decodable { struct Quiz: Decodable { let name: String; let cards: [Card] }; struct Card: Decodable { let prompt: String }; let quiz: Quiz }

@Suite("LLMResponseParser")
struct LLMResponseParserTests {
    @Test("plain object")
    func plain() throws {
        let v: Verdict = try LLMResponseParser.decode(#"{"verdict":"correct","reason":"ok"}"#)
        #expect(v.verdict == "correct")
    }

    @Test("fenced with language tag")
    func fencedWithTag() throws {
        let raw = "```json\n{\"verdict\":\"partial\",\"reason\":\"half\"}\n```"
        let v: Verdict = try LLMResponseParser.decode(raw)
        #expect(v.verdict == "partial")
    }

    @Test("fenced without language tag")
    func fencedNoTag() throws {
        let raw = "```\n{\"verdict\":\"wrong\",\"reason\":\"no\"}\n```"
        let v: Verdict = try LLMResponseParser.decode(raw)
        #expect(v.verdict == "wrong")
    }

    @Test("prose around the object")
    func proseAround() throws {
        let raw = "Sure! Here you go:\n{\"verdict\":\"correct\",\"reason\":\"fine\"}\nHope that helps."
        let v: Verdict = try LLMResponseParser.decode(raw)
        #expect(v.reason == "fine")
    }

    @Test("nested braces are balanced")
    func nested() throws {
        let raw = #"{"quiz":{"name":"N","cards":[{"prompt":"p","long_answer":"l"}]}} trailing"#
        let file: Wrapper = try LLMResponseParser.decode(raw)
        #expect(file.quiz.cards.count == 1)
    }

    @Test("braces inside strings do not end the object")
    func bracesInStrings() throws {
        let raw = #"{"verdict":"correct","reason":"uses } and { in text"}"#
        let v: Verdict = try LLMResponseParser.decode(raw)
        #expect(v.reason == "uses } and { in text")
    }

    @Test("escaped quotes inside strings")
    func escapedQuotes() throws {
        let raw = #"{"verdict":"correct","reason":"said \"}\" then stopped"}"#
        let v: Verdict = try LLMResponseParser.decode(raw)
        #expect(v.reason == "said \"}\" then stopped")
    }

    @Test("no object is a parse error")
    func noObject() {
        #expect(throws: LLMResponseParseError.self) {
            let _: Verdict = try LLMResponseParser.decode("nothing here")
        }
    }

    @Test("wrong shape is a parse error with the missing key named")
    func wrongShape() {
        do {
            let _: Verdict = try LLMResponseParser.decode(#"{"verdict":"correct"}"#)
            Issue.record("expected a throw")
        } catch let error as LLMResponseParseError {
            #expect(error.detail.contains("reason"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
