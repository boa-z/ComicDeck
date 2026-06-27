import SwiftUI

@MainActor
struct TrackingSettingsView: View {
    private enum PersistKey {
        static let aniListClientID = "tracking.anilist.clientID"
        static let aniListClientSecretAccount = "anilist.clientSecret"
    }

    @Environment(TrackerViewModel.self) private var tracker
    @State private var tokens: [TrackerProvider: String] = [:]
    @State private var connectingProvider: TrackerProvider?
    @State private var testingProvider: TrackerProvider?
    @State private var alertMessage: String?
    @AppStorage(PersistKey.aniListClientID) private var aniListClientID = ""
    @State private var aniListClientSecret = ""
    private let aniListOAuth = AniListOAuthSession()

    var body: some View {
        List {
            ForEach(TrackerProvider.allCases) { provider in
                Section(provider.title) {
                    providerSection(provider)
                }
            }

            syncBehaviorSection

            Section(AppLocalization.text("tracking.settings.status.title", "Status")) {
                Text(tracker.status)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(AppLocalization.text("tracking.settings.status.queued_events", "Queued Sync Events"))
                    Spacer()
                    Text("\(tracker.pendingEvents.count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(AppLocalization.text("tracking.section.title", "Tracking"))
        .alert(AppLocalization.text("tracking.section.title", "Tracking"), isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button(AppLocalization.text("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .task {
            aniListClientSecret = (try? SecureStore.read(service: "boa.ComicDeck.Tracker", account: PersistKey.aniListClientSecretAccount)) ?? ""
        }
    }

    private var syncBehaviorSection: some View {
        Section(AppLocalization.text("tracking.settings.sync_behavior.title", "Sync Behavior")) {
            Toggle(
                AppLocalization.text("tracking.settings.sync_behavior.automatic", "Automatic Sync"),
                isOn: Binding(
                    get: { tracker.automaticSyncEnabled },
                    set: { tracker.automaticSyncEnabled = $0 }
                )
            )

            Picker(
                AppLocalization.text("tracking.settings.sync_behavior.automatic_direction", "Automatic Direction"),
                selection: Binding(
                    get: { tracker.automaticSyncDirection },
                    set: { tracker.automaticSyncDirection = $0 }
                )
            ) {
                ForEach(TrackerSyncDirection.allCases) { direction in
                    Text(syncDirectionTitle(direction)).tag(direction)
                }
            }
            .disabled(!tracker.automaticSyncEnabled)

            Picker(
                AppLocalization.text("tracking.settings.sync_behavior.manual_default", "Manual Sync Default"),
                selection: Binding(
                    get: { tracker.manualSyncDefaultDirection },
                    set: { tracker.manualSyncDefaultDirection = $0 }
                )
            ) {
                ForEach(TrackerSyncDirection.allCases) { direction in
                    Text(syncDirectionTitle(direction)).tag(direction)
                }
            }

            ForEach(TrackerProvider.allCases) { provider in
                Toggle(
                    AppLocalization.format(
                        "tracking.settings.sync_behavior.provider_auto_format",
                        "Sync %@ automatically",
                        provider.title
                    ),
                    isOn: Binding(
                        get: { tracker.automaticSyncEnabled(for: provider) },
                        set: { tracker.setAutomaticSyncEnabled($0, for: provider) }
                    )
                )
                .disabled(!tracker.automaticSyncEnabled)
            }

            Text(AppLocalization.text(
                "tracking.settings.sync_behavior.help",
                "Pull and two-way sync only use confirmed bindings. Local history is updated only when a local chapter list is available."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func providerSection(_ provider: TrackerProvider) -> some View {
        if provider == .aniList {
            aniListSection
        } else if let account = tracker.account(for: provider) {
            VStack(alignment: .leading, spacing: 8) {
                Label(account.displayName, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                Text(AppLocalization.format(
                    "tracking.settings.connected_provider_user",
                    "Connected as %@ user %@",
                    provider.title,
                    account.remoteUserID
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(testingProvider == provider
                   ? AppLocalization.text("tracking.settings.validating", "Validating...")
                   : AppLocalization.text("tracking.settings.validate_connection", "Validate Connection")) {
                Task { await validateCurrentToken(provider) }
            }
            .disabled(testingProvider != nil || connectingProvider != nil)

            Button(AppLocalization.text("tracking.disconnect", "Disconnect"), role: .destructive) {
                Task { await disconnect(provider) }
            }
            .disabled(testingProvider != nil || connectingProvider != nil)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                TextField(AppLocalization.format(
                    "tracking.settings.access_token_placeholder",
                    "%@ access token",
                    provider.title
                ), text: Binding(
                    get: { tokens[provider] ?? "" },
                    set: { tokens[provider] = $0 }
                ))
                .platformTextInputAutocapitalizationNever()
                .autocorrectionDisabled()
                .font(.callout.monospaced())

                Text(providerHelpText(provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(connectingProvider == provider
                   ? AppLocalization.text("tracking.settings.connecting", "Connecting...")
                   : AppLocalization.format("tracking.settings.connect_provider", "Connect %@", provider.title)) {
                Task { await connect(provider) }
            }
            .disabled(
                connectingProvider != nil ||
                testingProvider != nil ||
                (tokens[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
    }

    private var aniListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(AppLocalization.text("tracking.settings.anilist.client_id", "AniList OAuth client ID"), text: $aniListClientID)
                .platformTextInputAutocapitalizationNever()
                .autocorrectionDisabled()
                .font(.callout.monospaced())

            SecureField(AppLocalization.text("tracking.settings.anilist.client_secret", "AniList OAuth client secret"), text: $aniListClientSecret)
                .platformTextInputAutocapitalizationNever()
                .autocorrectionDisabled()
                .font(.callout.monospaced())

            Text(AppLocalization.format(
                "tracking.settings.anilist.oauth_help",
                "Register %@ as the redirect URI in your AniList app, then authorize here. ComicDeck exchanges the returned authorization code locally and keeps the access token plus client secret in Keychain.",
                AniListOAuthSession.redirectURI
            ))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let account = tracker.account(for: .aniList) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(account.displayName, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                    Text(AppLocalization.format(
                        "tracking.settings.connected_anilist_user",
                        "Connected as AniList user %@",
                        account.remoteUserID
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(testingProvider == .aniList
                           ? AppLocalization.text("tracking.settings.validating", "Validating...")
                           : AppLocalization.text("tracking.settings.validate_connection", "Validate Connection")) {
                        Task { await validateCurrentToken(.aniList) }
                    }
                    .disabled(testingProvider != nil || connectingProvider != nil)

                    Button(connectingProvider == .aniList
                           ? AppLocalization.text("tracking.settings.authorizing", "Authorizing...")
                           : AppLocalization.text("tracking.settings.reconnect_oauth", "Reconnect OAuth")) {
                        Task { await connectAniListOAuth() }
                    }
                    .disabled(
                        connectingProvider != nil ||
                        testingProvider != nil ||
                        aniListClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        aniListClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }

                Button(AppLocalization.text("tracking.disconnect", "Disconnect"), role: .destructive) {
                    Task { await disconnect(.aniList) }
                }
                .disabled(testingProvider != nil || connectingProvider != nil)
            } else {
                Button(connectingProvider == .aniList
                       ? AppLocalization.text("tracking.settings.authorizing", "Authorizing...")
                       : AppLocalization.text("tracking.settings.authorize_anilist", "Authorize AniList")) {
                    Task { await connectAniListOAuth() }
                }
                .disabled(
                    connectingProvider != nil ||
                    testingProvider != nil ||
                    aniListClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    aniListClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
    }

    private func syncDirectionTitle(_ direction: TrackerSyncDirection) -> String {
        switch direction {
        case .localToRemote:
            return AppLocalization.text("tracking.sync.direction.local_to_remote", "Push Local Progress")
        case .remoteToLocal:
            return AppLocalization.text("tracking.sync.direction.remote_to_local", "Pull Tracker Progress")
        case .bidirectional:
            return AppLocalization.text("tracking.sync.direction.bidirectional", "Two-way Sync")
        }
    }

    private func providerHelpText(_ provider: TrackerProvider) -> String {
        switch provider {
        case .aniList:
            return AppLocalization.text(
                "tracking.settings.anilist.help",
                "AniList now uses authorization code OAuth. Enter both the client ID and client secret from your AniList app, and register the ComicDeck callback URL in the AniList developer console."
            )
        case .bangumi:
            return AppLocalization.text(
                "tracking.settings.bangumi.help",
                "Use a Bangumi personal access token. ComicDeck currently syncs reading progress one-way from the app to Bangumi."
            )
        }
    }

    private func connect(_ provider: TrackerProvider) async {
        connectingProvider = provider
        defer { connectingProvider = nil }
        do {
            switch provider {
            case .aniList:
                await connectAniListOAuth()
                return
            case .bangumi:
                try await tracker.connectBangumi(accessToken: tokens[provider] ?? "")
            }
            tokens[provider] = ""
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func connectAniListOAuth() async {
        connectingProvider = .aniList
        defer { connectingProvider = nil }
        do {
            let code = try await aniListOAuth.authorize(clientID: aniListClientID)
            let token = try await AniListTrackerClient().exchangeAuthorizationCode(
                clientID: aniListClientID.trimmingCharacters(in: .whitespacesAndNewlines),
                clientSecret: aniListClientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
                authorizationCode: code
            )
            try SecureStore.save(
                aniListClientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
                service: "boa.ComicDeck.Tracker",
                account: PersistKey.aniListClientSecretAccount
            )
            try await tracker.connectAniList(accessToken: token)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func validateCurrentToken(_ provider: TrackerProvider) async {
        testingProvider = provider
        defer { testingProvider = nil }
        do {
            _ = try await tracker.validateConnection(provider)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func disconnect(_ provider: TrackerProvider) async {
        do {
            try await tracker.disconnect(provider)
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}
