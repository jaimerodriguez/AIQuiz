import Foundation
import Testing
@testable import AIQuizCore

@Suite("JudgeJSON")
struct JudgeVerdictTests {
    @Test("verdict mapping is case-insensitive and defaults to wrong")
    func verdictMapping() {
        #expect(JudgeJSON(verdict: "Correct", reason: "").toVerdict().verdict == .correct)
        #expect(JudgeJSON(verdict: " PARTIAL ", reason: "").toVerdict().verdict == .partial)
        #expect(JudgeJSON(verdict: "unknown", reason: "").toVerdict().verdict == .wrong)
    }
}
