import SwiftUI

struct ComicTrackerProviderState: Identifiable, Hashable {
    let provider: TrackerProvider
    let account: TrackerAccount?
    let binding: TrackerBinding?
    let syncing: Bool
    let statusText: String

    var id: TrackerProvider { provider }
}

struct ComicTrackerSection: View {
    let providers: [ComicTrackerProviderState]
    let onLink: (TrackerProvider) -> Void
    let onSync: (TrackerProvider) -> Void
    let onUnlink: (TrackerProvider) -> Void

    var body: some View {
        ComicDetailSectionCard(title: "Tracking", subtitle: "Sync reading progress to external services") {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                ForEach(providers) { provider in
                    providerRow(provider)
                    if provider.id != providers.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func providerRow(_ state: ComicTrackerProviderState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(state.provider.title, systemImage: state.account == nil ? "link.badge.plus" : "checkmark.circle.fill")
                    .foregroundStyle(state.account == nil ? Color.secondary : Color.green)
                Spacer()
                if let account = state.account {
                    Text(account.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not connected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let binding = state.binding {
                VStack(alignment: .leading, spacing: 6) {
                    Text(binding.remoteTitle)
                        .font(.headline)
                    HStack(spacing: 8) {
                        Text("Progress \(binding.lastSyncedProgress)")
                        if let status = binding.lastSyncedStatus {
                            Text(status.title)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button(state.syncing ? "Syncing..." : "Sync Now") {
                        onSync(state.provider)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.syncing)

                    Button("Unlink", role: .destructive) {
                        onUnlink(state.provider)
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.syncing)
                }
            } else if state.account != nil {
                Button("Link \(state.provider.title) Entry") {
                    onLink(state.provider)
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.syncing)
            } else {
                Text("Connect \(state.provider.title) in Settings before linking this comic.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !state.statusText.isEmpty {
                Text(state.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
struct TrackerSearchSheet: View {
    @Environment(TrackerViewModel.self) private var tracker
    @Environment(\.dismiss) private var dismiss
    let item: ComicSummary
    let provider: TrackerProvider
    let initialQuery: String
    let onBound: () -> Void

    @State private var query = ""
    @State private var loading = false
    @State private var results: [TrackerSearchResult] = []
    @State private var errorText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Search \(provider.title) manga", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if loading {
                    Section {
                        ProgressView("Searching...")
                    }
                } else if !errorText.isEmpty {
                    Section("Error") {
                        Text(errorText)
                            .foregroundStyle(.red)
                    }
                } else if results.isEmpty {
                    Section {
                        Text("No \(provider.title) results yet.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Results") {
                        ForEach(results) { result in
                            Button {
                                Task { await bind(result) }
                            } label: {
                                HStack(spacing: 12) {
                                    CoverArtworkView(urlString: result.coverURL, width: 48, height: 64)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.title)
                                            .font(.body.weight(.semibold))
                                            .multilineTextAlignment(.leading)
                                        if let subtitle = result.subtitle, !subtitle.isEmpty {
                                            Text(subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        HStack(spacing: 6) {
                                            if let chapterCount = result.chapterCount {
                                                Text("\(chapterCount) ch")
                                            }
                                            if let statusText = result.statusText {
                                                Text(statusText)
                                            }
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Link \(provider.title)")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Search") {
                        Task { await search() }
                    }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
                }
            }
            .task {
                if query.isEmpty {
                    query = initialQuery
                    await search()
                }
            }
        }
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        loading = true
        errorText = ""
        defer { loading = false }
        do {
            results = try await tracker.search(provider, query: trimmed)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func bind(_ result: TrackerSearchResult) async {
        do {
            try await tracker.bind(item, provider: provider, result: result)
            onBound()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
