import SwiftUI

@MainActor
struct TranslationSettingsView: View {
    @AppStorage("Translation.enabled") private var translationEnabled = false
    @AppStorage("Translation.backend") private var translationBackendRaw = ReaderTranslationBackendKind.builtIn.rawValue
    @AppStorage("Translation.koharuBaseURL") private var translationKoharuBaseURL = ""
    @AppStorage("Translation.requestTimeoutSeconds") private var translationRequestTimeoutSeconds = 60
    @AppStorage("Translation.koharuLLMMode") private var translationKoharuLLMModeRaw = ReaderKoharuLLMMode.serverDefault.rawValue
    @AppStorage("Translation.koharuLLMProviderID") private var translationKoharuLLMProviderID = ""
    @AppStorage("Translation.koharuLLMModelID") private var translationKoharuLLMModelID = ""
    @AppStorage("Translation.koharuLLMTemperature") private var translationKoharuLLMTemperatureRaw = ""
    @AppStorage("Translation.koharuLLMMaxTokens") private var translationKoharuLLMMaxTokensRaw = ""
    @AppStorage("Translation.koharuLLMSystemPrompt") private var translationKoharuLLMSystemPrompt = ""
    @AppStorage("Translation.sourceLanguage") private var translationSourceLanguageRaw = ""
    @AppStorage("Translation.targetLanguage") private var translationTargetLanguageRaw = ReaderTranslationLanguage.chineseSimplified.rawValue

    private let autoDetectSourceLanguageTag = "settings.translation.source.auto"

    private var translationBackendKind: ReaderTranslationBackendKind {
        get { currentTranslationPreferences.backendConfiguration.kind }
        nonmutating set { translationBackendRaw = newValue.rawValue }
    }

    private var translationKoharuLLMMode: ReaderKoharuLLMMode {
        get { currentTranslationPreferences.backendConfiguration.koharuLLM.mode }
        nonmutating set { translationKoharuLLMModeRaw = newValue.rawValue }
    }

    private var translationKoharuLLMConfiguration: ReaderKoharuLLMConfiguration {
        currentTranslationPreferences.backendConfiguration.koharuLLM
    }

    private var translationSourceLanguage: ReaderTranslationLanguage? {
        get { currentTranslationPreferences.sourceLanguage }
        nonmutating set { translationSourceLanguageRaw = newValue?.rawValue ?? "" }
    }

    private var translationTargetLanguage: ReaderTranslationLanguage {
        get { currentTranslationPreferences.targetLanguage }
        nonmutating set { translationTargetLanguageRaw = newValue.rawValue }
    }

    private var currentTranslationPreferences: ReaderTranslationPreferences {
        ReaderTranslationPreferences.fromStorage(
            enabled: translationEnabled,
            backendRaw: translationBackendRaw,
            koharuBaseURL: translationKoharuBaseURL,
            requestTimeoutSeconds: translationRequestTimeoutSeconds,
            koharuLLMModeRaw: translationKoharuLLMModeRaw,
            koharuLLMProviderID: translationKoharuLLMProviderID,
            koharuLLMModelID: translationKoharuLLMModelID,
            koharuLLMTemperatureRaw: translationKoharuLLMTemperatureRaw,
            koharuLLMMaxTokensRaw: translationKoharuLLMMaxTokensRaw,
            koharuLLMSystemPrompt: translationKoharuLLMSystemPrompt,
            sourceLanguageRaw: translationSourceLanguageRaw,
            targetLanguageRaw: translationTargetLanguageRaw
        )
    }

    private var translationTimeoutBinding: Binding<Int> {
        Binding(
            get: { ReaderPageTranslationBackendConfiguration.clampedRequestTimeoutSeconds(translationRequestTimeoutSeconds) },
            set: { translationRequestTimeoutSeconds = ReaderPageTranslationBackendConfiguration.clampedRequestTimeoutSeconds($0) }
        )
    }

    var body: some View {
        List {
            Section(AppLocalization.text("settings.translation.general_section", "General")) {
                Toggle(AppLocalization.text("reader.translation.settings.enabled", "Enable page translation"), isOn: $translationEnabled)

                Stepper(value: translationTimeoutBinding, in: ReaderPageTranslationBackendConfiguration.minRequestTimeoutSeconds...ReaderPageTranslationBackendConfiguration.maxRequestTimeoutSeconds, step: 5) {
                    Text(
                        AppLocalization.format(
                            "settings.translation.timeout",
                            "Request timeout: %lld sec",
                            Int64(translationTimeoutBinding.wrappedValue)
                        )
                    )
                }
            }

            Section(AppLocalization.text("settings.translation.backend_section", "Backend")) {
                Picker(
                    AppLocalization.text("reader.translation.settings.backend", "Translation backend"),
                    selection: Binding(
                        get: { translationBackendKind },
                        set: { translationBackendKind = $0 }
                    )
                ) {
                    ForEach(ReaderTranslationBackendKind.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
            }

            if translationBackendKind == .koharu {
                Section(AppLocalization.text("settings.translation.koharu_section", "Koharu")) {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(AppLocalization.text("reader.translation.settings.koharu_url", "Koharu server URL"))
                            .font(.subheadline.weight(.semibold))
                        TextField(
                            AppLocalization.text("reader.translation.settings.koharu_url.placeholder", "http://127.0.0.1:8080"),
                            text: $translationKoharuBaseURL
                        )
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textContentType(.URL)

                        Picker(
                            AppLocalization.text("reader.translation.settings.koharu_llm.mode", "Koharu LLM mode"),
                            selection: Binding(
                                get: { translationKoharuLLMMode },
                                set: { translationKoharuLLMMode = $0 }
                            )
                        ) {
                            Text(AppLocalization.text("reader.translation.settings.koharu_llm.mode.server_default", "Server default"))
                                .tag(ReaderKoharuLLMMode.serverDefault)
                            Text(AppLocalization.text("reader.translation.settings.koharu_llm.mode.provider", "Provider"))
                                .tag(ReaderKoharuLLMMode.provider)
                            Text(AppLocalization.text("reader.translation.settings.koharu_llm.mode.local", "Local"))
                                .tag(ReaderKoharuLLMMode.local)
                        }

                        if translationKoharuLLMConfiguration.mode == .provider {
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                Text(AppLocalization.text("reader.translation.settings.koharu_llm.provider_id", "Provider ID"))
                                    .font(.subheadline.weight(.semibold))
                                TextField(
                                    AppLocalization.text("reader.translation.settings.koharu_llm.provider_id.placeholder", "openai"),
                                    text: $translationKoharuLLMProviderID
                                )
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            }
                        }

                        if translationKoharuLLMConfiguration.mode != .serverDefault {
                            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                Text(AppLocalization.text("reader.translation.settings.koharu_llm.model_id", "Model ID"))
                                    .font(.subheadline.weight(.semibold))
                                TextField(
                                    AppLocalization.text("reader.translation.settings.koharu_llm.model_id.placeholder", "gpt-4.1-mini"),
                                    text: $translationKoharuLLMModelID
                                )
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                                Text(AppLocalization.text("reader.translation.settings.koharu_llm.temperature", "Temperature"))
                                    .font(.subheadline.weight(.semibold))
                                TextField(
                                    AppLocalization.text("reader.translation.settings.koharu_llm.temperature.placeholder", "0.4"),
                                    text: $translationKoharuLLMTemperatureRaw
                                )
                                .keyboardType(.decimalPad)

                                Text(AppLocalization.text("reader.translation.settings.koharu_llm.max_tokens", "Max tokens"))
                                    .font(.subheadline.weight(.semibold))
                                TextField(
                                    AppLocalization.text("reader.translation.settings.koharu_llm.max_tokens.placeholder", "1024"),
                                    text: $translationKoharuLLMMaxTokensRaw
                                )
                                .keyboardType(.numberPad)

                                Text(AppLocalization.text("reader.translation.settings.koharu_llm.system_prompt", "Custom system prompt"))
                                    .font(.subheadline.weight(.semibold))
                                TextField(
                                    AppLocalization.text("reader.translation.settings.koharu_llm.system_prompt.placeholder", "Translate naturally while preserving tone."),
                                    text: $translationKoharuLLMSystemPrompt,
                                    axis: .vertical
                                )
                                .lineLimit(3...6)
                            }
                        }

                        Text(AppLocalization.text("reader.translation.settings.koharu_llm.warning", "Changing Koharu LLM settings clears cached page translation state for new reader sessions using Koharu."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(AppLocalization.text("settings.translation.languages_section", "Languages")) {
                Picker(
                    AppLocalization.text("reader.translation.settings.source_language", "Comic language"),
                    selection: Binding(
                        get: { translationSourceLanguage?.rawValue ?? autoDetectSourceLanguageTag },
                        set: { rawValue in
                            translationSourceLanguage = rawValue == autoDetectSourceLanguageTag ? nil : ReaderTranslationLanguage(rawValue: rawValue)
                        }
                    )
                ) {
                    Text(AppLocalization.text("reader.translation.settings.source_language.auto", "Auto detect"))
                        .tag(autoDetectSourceLanguageTag)
                    ForEach(ReaderTranslationLanguage.allCases) { language in
                        Text(language.title).tag(language.rawValue)
                    }
                }

                Picker(
                    AppLocalization.text("reader.translation.settings.language", "Target language"),
                    selection: Binding(
                        get: { translationTargetLanguage },
                        set: { translationTargetLanguage = $0 }
                    )
                ) {
                    ForEach(ReaderTranslationLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
            }
        }
        .navigationTitle(AppLocalization.text("settings.translation.title", "Translation"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
