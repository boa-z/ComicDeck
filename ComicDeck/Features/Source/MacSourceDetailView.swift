#if os(macOS)
import SwiftUI
import Observation

/// Native macOS (Form/.grouped) variant of the installed-source detail.
///
/// The shared `SourceDetailView` is an iOS-styled ScrollView that sets its own
/// `.navigationTitle` and `.ignoresSafeArea()` background — both of which fight
/// the macOS detail pane when embedded inside `MacSourceWorkspaceView`. This
/// view reuses the same backing models (`SourceDetailScreenModel`,
/// `LoginViewModel`) but renders through a native grouped `Form` so the
/// installed-source detail matches the remote/index details visually.
@MainActor
struct MacSourceDetailView: View {
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

    private var isSelected: Bool {
        sourceManager.selectedSourceKey == source.key
    }

    private var supportItems: [(title: String, systemImage: String, enabled: Bool)] {
        [
            (AppLocalization.text("source.capability.explore", "Explore"), "sparkles.rectangle.stack", model.capabilityProfile.hasExplore),
            (AppLocalization.text("source.capability.category", "Category"), "square.grid.3x3.topleft.filled", model.capabilityProfile.hasCategory),
            (AppLocalization.text("source.capability.search", "Search"), "magnifyingglass", model.capabilityProfile.hasSearch),
            (AppLocalization.text("source.capability.favorites", "Favorites"), "heart", model.capabilityProfile.hasFavorites),
            (AppLocalization.text("source.capability.comments", "Comments"), "bubble.left.and.bubble.right", model.capabilityProfile.hasComments),
            (AppLocalization.text("source.capability.account", "Account"), "person.text.rectangle", model.capabilityProfile.hasAccountLogin),
            (AppLocalization.text("source.capability.web", "Web"), "globe", model.capabilityProfile.hasWebLogin),
            (AppLocalization.text("source.capability.cookies", "Cookies"), "key.horizontal", model.capabilityProfile.hasCookieLogin),
            (AppLocalization.text("source.capability.settings", "Settings"), "slider.horizontal.3", model.capabilityProfile.hasSettings)
        ]
    }

    var body: some View {
        Form {
            overviewSection
            supportSection
            authenticationSection
            settingsSection
            statusSection
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: source.key) {
            await model.load(source: source, using: vm)
            seedTextDrafts()
        }
    }

    // MARK: - Overview

    private var overviewSection: some View {
        Section {
            LabeledContent(AppLocalization.text("source.detail.key", "Key"), value: source.key)
            LabeledContent(AppLocalization.text("source.detail.version", "Version"), value: source.version)
            LabeledContent(AppLocalization.text("source.detail.script", "Script"), value: source.scriptFileName)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    overviewActionButtons
                }

                VStack(alignment: .leading, spacing: 8) {
                    overviewActionButtons
                }
            }
            .padding(.top, 4)
        } header: {
            Text(source.name)
        }
    }

    @ViewBuilder
    private var overviewActionButtons: some View {
        Button {
            sourceManager.selectSource(source)
        } label: {
            Label(
                isSelected ? AppLocalization.text("source.detail.selected", "Selected") : AppLocalization.text("source.action.use", "Use Source"),
                systemImage: isSelected ? "checkmark.circle.fill" : "checkmark.circle"
            )
        }
        .disabled(isSelected || sourceManager.isOperating(on: source.key))

        if updateVersion != nil {
            Button {
                Task { await sourceManager.updateSource(source) }
            } label: {
                Label(
                    sourceManager.isOperating(on: source.key)
                        ? AppLocalization.text("source.action.updating", "Updating...")
                        : AppLocalization.text("source.action.update", "Update"),
                    systemImage: "square.and.arrow.down"
                )
            }
            .disabled(sourceManager.isOperating(on: source.key))
        }

        Button(role: .destructive) {
            Task { await sourceManager.uninstallSource(source) }
        } label: {
            Label(AppLocalization.text("source.action.delete", "Delete"), systemImage: "trash")
        }
        .disabled(sourceManager.isOperating(on: source.key))
    }

    // MARK: - Support

    private var supportSection: some View {
        Section {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110), spacing: 10)],
                spacing: 10
            ) {
                ForEach(supportItems, id: \.title) { item in
                    supportPill(title: item.title, systemImage: item.systemImage, enabled: item.enabled)
                }
            }
            .padding(.vertical, 2)

            if !model.capabilityProfile.availableSearchMethods.isEmpty {
                Text(AppLocalization.format(
                    "source.detail.search_methods_format",
                    "Search methods: %@",
                    model.capabilityProfile.availableSearchMethods.joined(separator: ", ")
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text(AppLocalization.text("source.detail.support", "Support"))
        } footer: {
            Text(AppLocalization.text("source.detail.support_footer", "Capabilities detected from the installed source script"))
        }
    }

    private func supportPill(title: String, systemImage: String, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(enabled ? AppTint.accent : .secondary)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text(enabled
                 ? AppLocalization.text("source.detail.supported", "Supported")
                 : AppLocalization.text("source.detail.unavailable", "Unavailable"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    // MARK: - Authentication

    private var authenticationSection: some View {
        Section {
            HStack {
                Label(AppLocalization.text("source.detail.session", "Session"), systemImage: "person.badge.key")
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(login.currentSourceLoginStateLabel)
                        .foregroundStyle(loginStatusColor)
                    if let activeProfile = activeAuthProfile {
                        Text(activeProfile.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button(AppLocalization.text("source.detail.refresh_login", "Refresh Login Status")) {
                Task { await login.refreshCurrentSourceLoginState(for: source) }
            }

            Button(AppLocalization.text("source.detail.save_current_account", "Save Current Account")) {
                Task { await login.saveCurrentAuthProfile(for: source, replacingActive: false) }
            }
            .disabled(!canSaveAuthProfile)

            if !login.authProfiles.isEmpty {
                Divider()
                ForEach(login.authProfiles) { profile in
                    authProfileRow(profile)
                }
            }

            if model.capabilityProfile.hasAccountLogin {
                Divider()
                accountLoginForm
            }

            if model.capabilityProfile.hasCookieLogin {
                Divider()
                cookieLoginForm
            }

            if model.capabilityProfile.hasWebLogin {
                Divider()
                webLoginRow
            }

            if !login.registerURL.isEmpty {
                Divider()
                Link(destination: URL(string: login.registerURL) ?? URL(fileURLWithPath: "")) {
                    Label(AppLocalization.text("source.management.open_register", "Open Register Page"), systemImage: "arrow.up.right.square")
                }
                .font(.footnote)
            }
        } header: {
            Text(AppLocalization.text("source.detail.authentication", "Authentication"))
        } footer: {
            Text(AppLocalization.text("source.detail.authentication_footer", "Login flows and session state for this source"))
        }
    }

    private var accountLoginForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalization.text("source.login.account_login", "Account Login"))
                .font(.subheadline.weight(.semibold))

            TextField(AppLocalization.text("source.login.account", "Account"), text: $login.loginAccount)
                .platformTextInputAutocapitalizationNever()
                .autocorrectionDisabled()

            SecureField(AppLocalization.text("source.login.password", "Password"), text: $login.loginPassword)

            Button(AppLocalization.text("source.login.login", "Login With Account")) {
                Task { await login.loginWithAccount(for: source) }
            }
        }
        .padding(.vertical, 4)
    }

    private var cookieLoginForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalization.text("source.login.cookie_login", "Cookie Login"))
                .font(.subheadline.weight(.semibold))

            TextField(AppLocalization.text("source.detail.account_label", "Account label"), text: $login.newAuthProfileLabel)
                .platformTextInputAutocapitalizationWords()
                .autocorrectionDisabled()

            ForEach(login.cookieLoginFields.indices, id: \.self) { index in
                let field = login.cookieLoginFields[index]
                TextField(
                    field,
                    text: Binding(
                        get: {
                            login.cookieLoginValues.indices.contains(index) ? login.cookieLoginValues[index] : ""
                        },
                        set: { login.updateCookieField(at: index, value: $0) }
                    )
                )
                .platformTextInputAutocapitalizationNever()
                .autocorrectionDisabled()
            }

            Button(AppLocalization.text("source.detail.validate_cookies", "Validate Cookies")) {
                Task { await login.loginWithCookies(for: source) }
            }
        }
        .padding(.vertical, 4)
    }

    private var webLoginRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.text("source.login.web_login", "Web Login"))
                .font(.subheadline.weight(.semibold))
            if !login.loginURL.isEmpty {
                Text(login.loginURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Button(AppLocalization.text("source.login.open_web", "Open Web Login")) {
                Task { await login.openWebLogin(for: source) }
            }
        }
        .padding(.vertical, 4)
    }

    private func authProfileRow(_ profile: WebLoginCookieStore.AuthProfile) -> some View {
        HStack {
            Label(
                profile.label,
                systemImage: profile.id == login.activeAuthProfileID ? "checkmark.circle.fill" : "person.crop.circle"
            )
            .foregroundStyle(profile.id == login.activeAuthProfileID ? AppTint.success : .primary)

            Spacer(minLength: 0)

            Button(AppLocalization.text("source.detail.use_account", "Use")) {
                Task { await login.switchAuthProfile(profile, for: source) }
            }
            .disabled(profile.id == login.activeAuthProfileID)

            Button(role: .destructive) {
                Task { await login.deleteAuthProfile(profile, for: source) }
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel(AppLocalization.format("source.detail.delete_account_label", "Delete %@", profile.label))
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        Section {
            if model.isLoading && model.settings.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
            } else if model.settings.isEmpty {
                Text(AppLocalization.text("source.detail.no_settings", "No source settings available."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.settings) { setting in
                    settingRow(setting)
                }
            }
        } header: {
            Text(AppLocalization.text("source.detail.settings", "Source Settings"))
        } footer: {
            Text(model.settings.isEmpty
                 ? AppLocalization.text("source.detail.settings_footer_empty", "This source does not expose runtime settings.")
                 : AppLocalization.text("source.detail.settings_footer", "Settings are persisted per source, following the source script contract."))
        }
    }

    @ViewBuilder
    private func settingRow(_ setting: SourceSettingDefinition) -> some View {
        switch setting.type.lowercased() {
        case "switch":
            Toggle(isOn: Binding(
                get: { setting.currentBoolValue },
                set: { newValue in
                    Task { await model.saveSetting(setting, value: newValue, using: vm, sourceKey: source.key) }
                }
            )) {
                Text(setting.title)
            }

        case "select":
            Picker(selection: Binding(
                get: { setting.currentStringValue },
                set: { newValue in
                    Task { await model.saveSetting(setting, value: newValue, using: vm, sourceKey: source.key) }
                }
            )) {
                ForEach(setting.options) { option in
                    Text(option.label).tag(option.value)
                }
            } label: {
                Text(setting.title)
            }
            .pickerStyle(.menu)

        default:
            HStack {
                TextField(
                    setting.defaultValue ?? setting.title,
                    text: Binding(
                        get: { textSettingDrafts[setting.key] ?? setting.currentStringValue },
                        set: { textSettingDrafts[setting.key] = $0 }
                    )
                )
                .platformTextInputAutocapitalizationNever()
                .autocorrectionDisabled()

                Button(AppLocalization.text("source.detail.save", "Save")) {
                    let value = textSettingDrafts[setting.key] ?? setting.currentStringValue
                    Task { await model.saveSetting(setting, value: value, using: vm, sourceKey: source.key) }
                }
                .disabled(model.isSaving(setting.key))

                if model.isSaving(setting.key) {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        if !model.status.isEmpty || !sourceManager.status.isEmpty {
            Section {
                Text(model.status.isEmpty ? sourceManager.status : model.status)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text(AppLocalization.text("source.repository.status", "Status"))
            }
        }
    }

    // MARK: - Helpers

    private var activeAuthProfile: WebLoginCookieStore.AuthProfile? {
        guard let id = login.activeAuthProfileID else { return nil }
        return login.authProfiles.first { $0.id == id }
    }

    private var canSaveAuthProfile: Bool {
        login.canSaveCurrentAuthProfile(sourceKey: source.key)
    }

    private var loginStatusColor: Color {
        login.currentSourceLoginStateLabel.contains("Logged In") ? AppTint.success : .secondary
    }

    private func seedTextDrafts() {
        for setting in model.settings where setting.type.lowercased() == "input" {
            textSettingDrafts[setting.key] = setting.currentStringValue
        }
    }
}
#endif
