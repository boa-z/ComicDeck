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

            Section("Status") {
                Text(tracker.status)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Queued Sync Events")
                    Spacer()
                    Text("\(tracker.pendingEvents.count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Tracking")
        .alert("Tracking", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .task {
            aniListClientSecret = (try? SecureStore.read(service: "boa.ComicDeck.Tracker", account: PersistKey.aniListClientSecretAccount)) ?? ""
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
                Text("Connected as \(provider.title) user \(account.remoteUserID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(testingProvider == provider ? "Validating..." : "Validate Connection") {
                Task { await validateCurrentToken(provider) }
            }
            .disabled(testingProvider != nil || connectingProvider != nil)

            Button("Disconnect", role: .destructive) {
                Task { await disconnect(provider) }
            }
            .disabled(testingProvider != nil || connectingProvider != nil)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                TextField("\(provider.title) access token", text: Binding(
                    get: { tokens[provider] ?? "" },
                    set: { tokens[provider] = $0 }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout.monospaced())

                Text(providerHelpText(provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(connectingProvider == provider ? "Connecting..." : "Connect \(provider.title)") {
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
            TextField("AniList OAuth client ID", text: $aniListClientID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout.monospaced())

            SecureField("AniList OAuth client secret", text: $aniListClientSecret)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout.monospaced())

            Text("Register \(AniListOAuthSession.redirectURI) as the redirect URI in your AniList app, then authorize here. ComicDeck exchanges the returned authorization code locally and keeps the access token plus client secret in Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let account = tracker.account(for: .aniList) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(account.displayName, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                    Text("Connected as AniList user \(account.remoteUserID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(testingProvider == .aniList ? "Validating..." : "Validate Connection") {
                        Task { await validateCurrentToken(.aniList) }
                    }
                    .disabled(testingProvider != nil || connectingProvider != nil)

                    Button(connectingProvider == .aniList ? "Authorizing..." : "Reconnect OAuth") {
                        Task { await connectAniListOAuth() }
                    }
                    .disabled(
                        connectingProvider != nil ||
                        testingProvider != nil ||
                        aniListClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        aniListClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }

                Button("Disconnect", role: .destructive) {
                    Task { await disconnect(.aniList) }
                }
                .disabled(testingProvider != nil || connectingProvider != nil)
            } else {
                Button(connectingProvider == .aniList ? "Authorizing..." : "Authorize AniList") {
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

    private func providerHelpText(_ provider: TrackerProvider) -> String {
        switch provider {
        case .aniList:
            return "AniList now uses authorization code OAuth. Enter both the client ID and client secret from your AniList app, and register the ComicDeck callback URL in the AniList developer console."
        case .bangumi:
            return "Use a Bangumi personal access token. ComicDeck currently syncs reading progress one-way from the app to Bangumi."
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
