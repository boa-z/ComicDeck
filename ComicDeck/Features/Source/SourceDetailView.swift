import SwiftUI
import Observation

@MainActor
struct SourceDetailView: View {
    @Bindable var vm: ReaderViewModel
    @Bindable var sourceManager: SourceManagerViewModel
    @Bindable var login: LoginViewModel
    let source: InstalledSource

    @Environment(\.openURL) private var openURL
    @State private var model = SourceDetailScreenModel()
    @State private var textSettingDrafts: [String: String] = [:]

    private var updateVersion: String? {
        sourceManager.availableSourceUpdates[source.key]
    }

    private var supportItems: [(title: String, systemImage: String, enabled: Bool)] {
        [
            ("Explore", "sparkles.rectangle.stack", model.capabilityProfile.hasExplore),
            ("Category", "square.grid.3x3.topleft.filled", model.capabilityProfile.hasCategory),
            ("Search", "magnifyingglass", model.capabilityProfile.hasSearch),
            ("Favorites", "heart", model.capabilityProfile.hasFavorites),
            ("Comments", "bubble.left.and.bubble.right", model.capabilityProfile.hasComments),
            ("Account", "person.text.rectangle", model.capabilityProfile.hasAccountLogin),
            ("Web", "globe", model.capabilityProfile.hasWebLogin),
            ("Cookies", "key.horizontal", model.capabilityProfile.hasCookieLogin),
            ("Settings", "slider.horizontal.3", model.capabilityProfile.hasSettings)
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                overviewCard
                supportCard
                authenticationCard
                settingsCard
            }
            .padding(.horizontal, AppSpacing.screen)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(AppSurface.grouped.ignoresSafeArea())
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: source.key) {
            await model.load(source: source, using: vm)
            seedTextDrafts()
        }
    }

    private var overviewCard: some View {
        ComicDetailSectionCard(title: source.name, subtitle: "\(source.key) · v\(source.version)") {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                HStack(spacing: 8) {
                    if sourceManager.selectedSourceKey == source.key {
                        statusBadge("Selected", tint: AppTint.accent)
                    }
                    if let updateVersion {
                        statusBadge("Update v\(updateVersion)", tint: AppTint.warning)
                    }
                    if model.capabilityProfile.hasSettings {
                        statusBadge("\(model.capabilityProfile.settingCount) settings", tint: AppTint.success)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        sourceManager.selectSource(source)
                    } label: {
                        Label(
                            sourceManager.selectedSourceKey == source.key ? "Selected" : "Use Source",
                            systemImage: sourceManager.selectedSourceKey == source.key ? "checkmark.circle.fill" : "checkmark.circle"
                        )
                    }
                    .modifier(PrimarySelectionButtonStyleModifier(isSelected: sourceManager.selectedSourceKey == source.key))
                    .disabled(sourceManager.selectedSourceKey == source.key)

                    if updateVersion != nil {
                        Button {
                            Task { await sourceManager.updateSource(source) }
                        } label: {
                            Label(sourceManager.isOperating(on: source.key) ? "Updating..." : "Update", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .disabled(sourceManager.isOperating(on: source.key))
                    }

                    Spacer(minLength: 0)

                    Button(role: .destructive) {
                        Task { await sourceManager.uninstallSource(source) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(sourceManager.isOperating(on: source.key))
                }

                if !model.status.isEmpty || !sourceManager.status.isEmpty {
                    Text(model.status.isEmpty ? sourceManager.status : model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var supportCard: some View {
        ComicDetailSectionCard(title: "Support", subtitle: "Capabilities detected from the installed source script") {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(supportItems, id: \.title) { item in
                        supportPill(title: item.title, systemImage: item.systemImage, enabled: item.enabled)
                    }
                }

                if !model.capabilityProfile.availableSearchMethods.isEmpty {
                    Text("Search methods: \(model.capabilityProfile.availableSearchMethods.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var authenticationCard: some View {
        ComicDetailSectionCard(title: "Authentication", subtitle: "Login flows and session state for this source") {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                HStack {
                    Label("Session", systemImage: "person.badge.key")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(login.currentSourceLoginStateLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(loginStatusColor)
                }

                Button("Refresh Login Status") {
                    Task { await login.refreshCurrentSourceLoginState(for: source) }
                }
                .buttonStyle(.bordered)

                if model.capabilityProfile.hasAccountLogin {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Account Login")
                            .font(.subheadline.weight(.semibold))

                        TextField("Account", text: $login.loginAccount)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))

                        SecureField("Password", text: $login.loginPassword)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))

                        Button("Login With Account") {
                            Task { await login.loginWithAccount(for: source) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if model.capabilityProfile.hasCookieLogin {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Cookie Login")
                            .font(.subheadline.weight(.semibold))

                        ForEach(Array(login.cookieLoginFields.enumerated()), id: \.offset) { index, field in
                            TextField(
                                field,
                                text: Binding(
                                    get: {
                                        login.cookieLoginValues.indices.contains(index) ? login.cookieLoginValues[index] : ""
                                    },
                                    set: { login.updateCookieField(at: index, value: $0) }
                                )
                            )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                        }

                        Button("Validate Cookies") {
                            Task { await login.loginWithCookies(for: source) }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if model.capabilityProfile.hasWebLogin {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Web Login")
                            .font(.subheadline.weight(.semibold))

                        if !login.loginURL.isEmpty {
                            Text(login.loginURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        Button("Open Web Login") {
                            Task { await login.openWebLogin(for: source) }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if !login.registerURL.isEmpty {
                    Link(destination: URL(string: login.registerURL)!) {
                        Label("Open Register Page", systemImage: "arrow.up.right.square")
                    }
                    .font(.footnote)
                }
            }
        }
    }

    private var settingsCard: some View {
        ComicDetailSectionCard(
            title: "Source Settings",
            subtitle: model.settings.isEmpty
                ? "This source does not expose runtime settings."
                : "Settings are persisted per source, following the source script contract."
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                if model.isLoading && model.settings.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if model.settings.isEmpty {
                    Text("No source settings available.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.settings) { setting in
                        settingRow(setting)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func settingRow(_ setting: SourceSettingDefinition) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(setting.title)
                        .font(.subheadline.weight(.semibold))
                    Text(setting.key)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isSaving(setting.key) {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            switch setting.type.lowercased() {
            case "switch":
                Toggle(
                    isOn: Binding(
                        get: { setting.currentBoolValue },
                        set: { newValue in
                            Task { await model.saveSetting(setting, value: newValue, using: vm, sourceKey: source.key) }
                        }
                    )
                ) {
                    Text(setting.currentBoolValue ? "Enabled" : "Disabled")
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)

            case "select":
                Menu {
                    ForEach(setting.options) { option in
                        Button {
                            Task { await model.saveSetting(setting, value: option.value, using: vm, sourceKey: source.key) }
                        } label: {
                            if option.value == setting.currentStringValue {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(displayLabel(for: setting))
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                }
                .buttonStyle(.plain)

            default:
                TextField(
                    setting.defaultValue ?? setting.title,
                    text: Binding(
                        get: { textSettingDrafts[setting.key] ?? setting.currentStringValue },
                        set: { textSettingDrafts[setting.key] = $0 }
                    )
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))

                Button("Save") {
                    let value = textSettingDrafts[setting.key] ?? setting.currentStringValue
                    Task { await model.saveSetting(setting, value: value, using: vm, sourceKey: source.key) }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(AppSpacing.md)
        .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    private func displayLabel(for setting: SourceSettingDefinition) -> String {
        setting.options.first(where: { $0.value == setting.currentStringValue })?.label ?? setting.currentStringValue
    }

    private func seedTextDrafts() {
        for setting in model.settings where setting.type.lowercased() == "input" {
            textSettingDrafts[setting.key] = setting.currentStringValue
        }
    }

    private var loginStatusColor: Color {
        login.currentSourceLoginStateLabel.contains("Logged In") ? AppTint.success : .secondary
    }

    private func statusBadge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    private func supportPill(title: String, systemImage: String, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(enabled ? AppTint.accent : .secondary)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text(enabled ? "Supported" : "Unavailable")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }
}

private struct PrimarySelectionButtonStyleModifier: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        if isSelected {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
