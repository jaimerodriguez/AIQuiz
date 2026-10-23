import XCTest
import LLMKit
@testable import AIQuiz

final class APIKeyCheckTests: XCTestCase {
    func testNormalizeStripsPasteDebris() {
        XCTAssertEqual(APIKeyCheck.normalize("  sk-ant-abc123\n"), "sk-ant-abc123")
        XCTAssertEqual(APIKeyCheck.normalize("\"sk-ant-abc123\""), "sk-ant-abc123")
        XCTAssertEqual(APIKeyCheck.normalize("“sk-ant-abc123”"), "sk-ant-abc123")
        XCTAssertEqual(APIKeyCheck.normalize("sk-ant-\u{200B}abc123\u{FEFF}"), "sk-ant-abc123")
        XCTAssertEqual(APIKeyCheck.normalize(""), "")
    }

    func testWarnings() {
        let openAI = URL(string: "https://api.openai.com/v1")
        let local = URL(string: "http://10.0.0.2:11434/v1")
        XCTAssertNil(APIKeyCheck.warning(for: "sk-ant-api03-xyz", kind: .anthropic, baseURL: nil))
        XCTAssertNotNil(APIKeyCheck.warning(for: "sk-proj-xyz", kind: .anthropic, baseURL: nil), "an OpenAI key pasted into Anthropic")
        XCTAssertNotNil(APIKeyCheck.warning(for: "sk-ant-api03 xyz", kind: .anthropic, baseURL: nil), "inner space")
        XCTAssertNil(APIKeyCheck.warning(for: "sk-proj-xyz", kind: .openAICompatible, baseURL: openAI))
        XCTAssertNotNil(APIKeyCheck.warning(for: "abc", kind: .openAICompatible, baseURL: openAI))
        XCTAssertNil(APIKeyCheck.warning(for: "anything", kind: .openAICompatible, baseURL: local), "local servers accept any token")
        XCTAssertNil(APIKeyCheck.warning(for: "", kind: .anthropic, baseURL: nil))
    }

    func testMasked() {
        XCTAssertEqual(APIKeyCheck.masked("sk-ant-api03-ABCDEFGHIJKLMNOP-wxyz"), "sk-ant-api…wxyz")
        XCTAssertEqual(APIKeyCheck.masked("short"), "sho…")
    }
}
