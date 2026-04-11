import XCTest
@testable import ComicDeck

@MainActor
final class ReaderPageTranslationBackendConfigurationTests: XCTestCase {
    func testNormalizedKoharuBaseURLTrimsWhitespaceAndAppendsAPIV1() throws {
        let configuration = ReaderPageTranslationBackendConfiguration(
            kind: .koharu,
            koharuBaseURL: "  https://koharu.example.com/service  ",
            requestTimeoutSeconds: 60
        )

        XCTAssertEqual(
            try configuration.normalizedKoharuAPIBaseURL().absoluteString,
            "https://koharu.example.com/service/api/v1"
        )
    }

    func testServerDefaultModeDropsOverrideFields() {
        let configuration = ReaderPageTranslationBackendConfiguration(
            kind: .koharu,
            koharuBaseURL: "https://koharu.example.com",
            requestTimeoutSeconds: 60,
            koharuLLM: ReaderKoharuLLMConfiguration(
                mode: .serverDefault,
                providerID: " provider ",
                modelID: " model ",
                temperature: 0.7,
                maxTokens: 1024,
                customSystemPrompt: " prompt "
            )
        )

        XCTAssertEqual(
            configuration.koharuLLM,
            ReaderKoharuLLMConfiguration(
                mode: .serverDefault,
                providerID: nil,
                modelID: nil,
                temperature: nil,
                maxTokens: nil,
                customSystemPrompt: nil
            )
        )
    }

    func testLocalModeIgnoresProviderID() {
        let configuration = ReaderPageTranslationBackendConfiguration(
            kind: .koharu,
            koharuBaseURL: "https://koharu.example.com",
            requestTimeoutSeconds: 60,
            koharuLLM: ReaderKoharuLLMConfiguration(
                mode: .local,
                providerID: "provider-a",
                modelID: "local-model",
                temperature: 0.5,
                maxTokens: 2048,
                customSystemPrompt: "Use furigana sparingly"
            )
        )

        XCTAssertEqual(
            configuration.koharuLLM,
            ReaderKoharuLLMConfiguration(
                mode: .local,
                providerID: nil,
                modelID: "local-model",
                temperature: 0.5,
                maxTokens: 2048,
                customSystemPrompt: "Use furigana sparingly"
            )
        )
    }

    func testWhitespaceOnlyOverrideStringsNormalizeToNil() {
        let configuration = ReaderPageTranslationBackendConfiguration(
            kind: .koharu,
            koharuBaseURL: "https://koharu.example.com",
            requestTimeoutSeconds: 60,
            koharuLLM: ReaderKoharuLLMConfiguration(
                mode: .provider,
                providerID: "   \n ",
                modelID: "\t  ",
                temperature: 0.2,
                maxTokens: 512,
                customSystemPrompt: "  "
            )
        )

        XCTAssertEqual(
            configuration.koharuLLM,
            ReaderKoharuLLMConfiguration(
                mode: .provider,
                providerID: nil,
                modelID: nil,
                temperature: 0.2,
                maxTokens: 512,
                customSystemPrompt: nil
            )
        )
    }

    func testEquivalentNormalizedKoharuLLMConfigurationsCompareEqual() {
        let lhs = ReaderPageTranslationBackendConfiguration(
            kind: .koharu,
            koharuBaseURL: "https://koharu.example.com",
            requestTimeoutSeconds: 60,
            koharuLLM: ReaderKoharuLLMConfiguration(
                mode: .provider,
                providerID: " provider-a ",
                modelID: " model-1 ",
                temperature: 0.4,
                maxTokens: 1024,
                customSystemPrompt: " Translate naturally. "
            )
        )
        let rhs = ReaderPageTranslationBackendConfiguration(
            kind: .koharu,
            koharuBaseURL: "https://koharu.example.com",
            requestTimeoutSeconds: 60,
            koharuLLM: ReaderKoharuLLMConfiguration(
                mode: .provider,
                providerID: "provider-a",
                modelID: "model-1",
                temperature: 0.4,
                maxTokens: 1024,
                customSystemPrompt: "Translate naturally."
            )
        )

        XCTAssertEqual(lhs, rhs)
        XCTAssertEqual(lhs.hashValue, rhs.hashValue)
    }

    func testChangingKoharuLLMFieldChangesConfigurationEquality() {
        let baseline = ReaderPageTranslationBackendConfiguration(
            kind: .koharu,
            koharuBaseURL: "https://koharu.example.com",
            requestTimeoutSeconds: 60,
            koharuLLM: ReaderKoharuLLMConfiguration(
                mode: .provider,
                providerID: "provider-a",
                modelID: "model-1",
                temperature: 0.4,
                maxTokens: 1024,
                customSystemPrompt: "Translate naturally."
            )
        )
        let changed = ReaderPageTranslationBackendConfiguration(
            kind: .koharu,
            koharuBaseURL: "https://koharu.example.com",
            requestTimeoutSeconds: 60,
            koharuLLM: ReaderKoharuLLMConfiguration(
                mode: .provider,
                providerID: "provider-a",
                modelID: "model-2",
                temperature: 0.4,
                maxTokens: 1024,
                customSystemPrompt: "Translate naturally."
            )
        )

        XCTAssertNotEqual(baseline, changed)
    }

    func testKoharuLLMCommandForServerDefaultUsesDeleteWithoutBody() throws {
        let command = try XCTUnwrap(
            KoharuLLMCommand.make(
                from: ReaderKoharuLLMConfiguration(mode: .serverDefault)
            )
        )

        XCTAssertEqual(command.method, "DELETE")
        XCTAssertEqual(command.path, "llm")
        XCTAssertNil(command.body)
    }

    func testKoharuLLMCommandForProviderUsesProviderTarget() throws {
        let command = try XCTUnwrap(
            KoharuLLMCommand.make(
                from: ReaderKoharuLLMConfiguration(
                    mode: .provider,
                    providerID: " provider-a ",
                    modelID: " model-1 ",
                    temperature: 0.7,
                    maxTokens: 1024,
                    customSystemPrompt: " Translate naturally. "
                )
            )
        )

        XCTAssertEqual(command.method, "PUT")
        XCTAssertEqual(command.path, "llm")
        XCTAssertEqual(command.body?.target.kind, .provider)
        XCTAssertEqual(command.body?.target.providerID, "provider-a")
        XCTAssertEqual(command.body?.target.modelID, "model-1")
        XCTAssertEqual(command.body?.options?.temperature, 0.7)
        XCTAssertEqual(command.body?.options?.maxTokens, 1024)
        XCTAssertEqual(command.body?.options?.customSystemPrompt, "Translate naturally.")
    }

    func testKoharuLLMCommandForLocalOmitsProviderID() throws {
        let command = try XCTUnwrap(
            KoharuLLMCommand.make(
                from: ReaderKoharuLLMConfiguration(
                    mode: .local,
                    providerID: "provider-a",
                    modelID: " local-model ",
                    temperature: 0.3,
                    maxTokens: 2048,
                    customSystemPrompt: "Keep honorifics."
                )
            )
        )

        XCTAssertEqual(command.method, "PUT")
        XCTAssertEqual(command.body?.target.kind, .local)
        XCTAssertNil(command.body?.target.providerID)
        XCTAssertEqual(command.body?.target.modelID, "local-model")
    }

    func testKoharuLLMCommandOmitsOptionsWhenAllOptionalValuesAreNil() throws {
        let command = try XCTUnwrap(
            KoharuLLMCommand.make(
                from: ReaderKoharuLLMConfiguration(
                    mode: .local,
                    modelID: "local-model",
                    temperature: nil,
                    maxTokens: nil,
                    customSystemPrompt: nil
                )
            )
        )
        let data = try JSONEncoder().encode(command.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(json["options"])
        let target = try XCTUnwrap(json["target"] as? [String: Any])
        XCTAssertEqual(target["kind"] as? String, "local")
        XCTAssertEqual(target["modelId"] as? String, "local-model")
        XCTAssertNil(target["providerId"])
    }

    func testKoharuLLMCommandForProviderRequiresProviderID() {
        XCTAssertThrowsError(
            try KoharuLLMCommand.make(
                from: ReaderKoharuLLMConfiguration(
                    mode: .provider,
                    providerID: nil,
                    modelID: "model-1"
                )
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Koharu provider LLM configuration requires a provider ID.")
        }
    }

    func testKoharuLLMCommandForProviderRequiresModelID() {
        XCTAssertThrowsError(
            try KoharuLLMCommand.make(
                from: ReaderKoharuLLMConfiguration(
                    mode: .provider,
                    providerID: "provider-a",
                    modelID: nil
                )
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Koharu LLM configuration requires a model ID.")
        }
    }

    func testKoharuLLMCommandForLocalRequiresModelID() {
        XCTAssertThrowsError(
            try KoharuLLMCommand.make(
                from: ReaderKoharuLLMConfiguration(
                    mode: .local,
                    modelID: nil
                )
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Koharu LLM configuration requires a model ID.")
        }
    }
}
