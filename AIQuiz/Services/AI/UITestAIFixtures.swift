import Foundation
import LLMKit
import AIQuizCore

/// UI-test mode AI behaviour (PLAN §1.5, DECISIONS ADR-005): every endpoint, whatever its kind,
/// is served by a `FakeLLMClient` that replays JSON fixtures keyed by the structured task name.
enum UITestAIFixtures {
    static func factory(scenario: AppEnvironment.Scenario) -> AIRouter.ClientFactory {
        { endpoint, _, _ in
            FakeLLMClient(endpoint: endpoint, latency: .milliseconds(300), handler: handler(scenario: scenario))
        }
    }

    static func handler(scenario: AppEnvironment.Scenario) -> FakeLLMClient.Handler {
        { request in
            switch scenario {
            case .endpointError:
                throw LLMError.server(status: 503)
            case .malformedJSON:
                return "{ this is not valid json"
            case .standard, .emptyLibrary, .noEndpoints:
                break
            }
            if request.label == StudyNotesWriter.label {
                return try fixture("notes", ext: "md")
            }
            switch request.responseFormat?.name {
            case "quiz": return try fixture("generation")
            case "judge": return try fixture("grading")
            default: return "OK"
            }
        }
    }

    static func fixture(_ name: String, ext: String = "json") throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "TestFixtures")
                ?? Bundle.main.url(forResource: name, withExtension: ext)
        else {
            throw LLMError.malformedResponse("missing test fixture \(name).\(ext)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
