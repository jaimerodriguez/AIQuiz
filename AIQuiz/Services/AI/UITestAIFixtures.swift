import Foundation
import LLMKit

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
            switch request.responseFormat?.name {
            case "quiz": return try fixture("generation")
            case "judge": return try fixture("grading")
            default: return "OK"
            }
        }
    }

    static func fixture(_ name: String) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "TestFixtures")
                ?? Bundle.main.url(forResource: name, withExtension: "json")
        else {
            throw LLMError.malformedResponse("missing test fixture \(name).json")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
