import SwiftUI

@MainActor
struct WebDAVSyncView: View {
    // NOTE: These dependencies are passed in explicitly rather than read via
    // `@Environment(...)`. `WebDAVSyncView` is presented as a `NavigationLink`
    // destination closure inside `SettingsView`, and SwiftUI may pre-evaluate
    // that destination to collect navigation preferences — especially on macOS
    // where `SettingsView` is nested inside a `NavigationSplitView` detail.
    // A force-unwrapped `@Environment` read during that pre-evaluation crashes
    // when the environment chain is not yet established; explicit parameters
    // keep view construction side-effect free.
    private let library: LibraryViewModel
    private let sourceManager: SourceManagerViewModel
    private let tracker: TrackerViewModel
    @Bindable var model: SettingsScreenModel

    init(
        model: SettingsScreenModel,
        library: LibraryViewModel,
        sourceManager: SourceManagerViewModel,
        tracker: TrackerViewModel
    ) {
        self.model = model
        self.library = library
        self.sourceManager = sourceManager
        self.tracker = tracker
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Last Sync", value: lastSyncValue)
                LabeledContent("Last Result", value: model.webDAVLastSyncSummary)
                    .foregroundStyle(.secondary)
            }

            Section("Server") {
                TextField("Directory URL", text: $model.webDAVDirectoryURL)
                    .platformTextInputAutocapitalizationNever()
                    .autocorrectionDisabled()
                    .platformKeyboardURL()

                TextField("Username", text: $model.webDAVUsername)
                    .platformTextInputAutocapitalizationNever()
                    .autocorrectionDisabled()

                SecureField("Password", text: $model.webDAVPassword)

                TextField("Remote File Name", text: $model.webDAVRemoteFileName)
                    .platformTextInputAutocapitalizationNever()
                    .autocorrectionDisabled()

                Toggle("Upload timestamped snapshots", isOn: $model.webDAVUploadSnapshots)
            }

            Section("Actions") {
                Button {
                    model.saveWebDAVConfiguration()
                } label: {
                    Label("Save Configuration", systemImage: "square.and.arrow.down")
                }

                Button {
                    Task { await model.testWebDAVConnection() }
                } label: {
                    Label("Test Connection", systemImage: "network")
                }
                .disabled(model.webDAVActionsDisabled)

                Button {
                    Task { await model.uploadBackupToWebDAV(using: library, tracker: tracker) }
                } label: {
                    HStack {
                        Label("Upload Backup", systemImage: "arrow.up.doc")
                        Spacer()
                        if model.uploadingWebDAV {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(model.webDAVActionsDisabled)

                Button {
                    Task { await model.restoreBackupFromWebDAV(using: library, sourceManager: sourceManager, tracker: tracker) }
                } label: {
                    HStack {
                        Label("Restore Configured Backup", systemImage: "arrow.down.doc")
                        Spacer()
                        if model.downloadingWebDAV {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(model.webDAVActionsDisabled)

                Button {
                    Task { await model.restoreLatestBackupFromWebDAV(using: library, sourceManager: sourceManager, tracker: tracker) }
                } label: {
                    Label("Restore Latest Remote Backup", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
                .disabled(model.webDAVActionsDisabled)
            }

            Section("Remote Backups") {
                Button {
                    Task { await model.refreshWebDAVEntries() }
                } label: {
                    HStack {
                        Label("Refresh Remote Backups", systemImage: "arrow.clockwise")
                        Spacer()
                        if model.loadingWebDAVEntries {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(model.webDAVActionsDisabled)

                if model.webDAVEntries.isEmpty {
                    Text("No remote backups loaded")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.webDAVEntries) { entry in
                        Button {
                            Task {
                                await model.restoreBackupFromWebDAVEntry(
                                    entry,
                                    using: library,
                                    sourceManager: sourceManager,
                                    tracker: tracker
                                )
                            }
                        } label: {
                            HStack(spacing: AppSpacing.md) {
                                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                    Text(entry.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(entry.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.down.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .disabled(model.webDAVActionsDisabled)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await model.deleteWebDAVEntry(entry) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Section {
                LabeledContent("Status", value: model.webDAVStatus)
                    .foregroundStyle(.secondary)
            } footer: {
                Text(AppLocalization.text("webdav.hint", "Use an existing WebDAV directory. Backups include tracker bindings and plaintext tracker access tokens. Offline files, active download queue, and pending tracker sync events are not uploaded."))
            }
        }
        .navigationTitle("WebDAV Sync")
        .platformNavigationBarTitleDisplayModeInline()
        .alert("WebDAV Error", isPresented: Binding(
            get: { model.webDAVError != nil },
            set: { if !$0 { model.webDAVError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.webDAVError ?? "Unknown WebDAV error")
        }
        .alert("WebDAV Complete", isPresented: Binding(
            get: { model.webDAVSuccessMessage != nil },
            set: { if !$0 { model.webDAVSuccessMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.webDAVSuccessMessage ?? "")
        }
        .task {
            if model.webDAVEntries.isEmpty, !model.webDAVDirectoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await model.refreshWebDAVEntries()
            }
        }
    }

    private var lastSyncValue: String {
        guard let date = model.webDAVLastSyncAt else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
