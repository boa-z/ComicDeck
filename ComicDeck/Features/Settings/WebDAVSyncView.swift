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
    @State private var pendingDeleteEntry: WebDAVRemoteBackup?

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
        let remoteBackupsSnapshot = WebDAVRemoteBackupsSnapshot(model: model)

        Form {
            Section {
                LabeledContent(AppLocalization.text("webdav.last_sync", "Last Sync"), value: lastSyncValue)
                LabeledContent(AppLocalization.text("webdav.last_result", "Last Result"), value: model.webDAVLastSyncSummary)
                    .foregroundStyle(.secondary)
            }

            Section(AppLocalization.text("webdav.section.server", "Server")) {
                TextField(AppLocalization.text("webdav.directory_url", "Directory URL"), text: $model.webDAVDirectoryURL)
                    .platformTextInputAutocapitalizationNever()
                    .autocorrectionDisabled()
                    .platformKeyboardURL()

                TextField(AppLocalization.text("webdav.username", "Username"), text: $model.webDAVUsername)
                    .platformTextInputAutocapitalizationNever()
                    .autocorrectionDisabled()

                SecureField(AppLocalization.text("webdav.password", "Password"), text: $model.webDAVPassword)

                TextField(AppLocalization.text("webdav.remote_file_name", "Remote File Name"), text: $model.webDAVRemoteFileName)
                    .platformTextInputAutocapitalizationNever()
                    .autocorrectionDisabled()

                Toggle(AppLocalization.text("webdav.upload_snapshots", "Upload timestamped snapshots"), isOn: $model.webDAVUploadSnapshots)
            }

            Section(AppLocalization.text("webdav.section.actions", "Actions")) {
                Button {
                    model.saveWebDAVConfiguration()
                } label: {
                    Label(AppLocalization.text("webdav.action.save_configuration", "Save Configuration"), systemImage: "square.and.arrow.down")
                }

                Button {
                    Task { await model.testWebDAVConnection() }
                } label: {
                    Label(AppLocalization.text("webdav.action.test_connection", "Test Connection"), systemImage: "network")
                }
                .disabled(model.webDAVActionsDisabled)

                Button {
                    Task { await model.uploadBackupToWebDAV(using: library, tracker: tracker) }
                } label: {
                    HStack {
                        Label(AppLocalization.text("webdav.action.upload_backup", "Upload Backup"), systemImage: "arrow.up.doc")
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
                        Label(AppLocalization.text("webdav.action.restore_configured", "Restore Configured Backup"), systemImage: "arrow.down.doc")
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
                    Label(AppLocalization.text("webdav.action.restore_latest", "Restore Latest Remote Backup"), systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
                .disabled(model.webDAVActionsDisabled)
            }

            Section(AppLocalization.text("webdav.section.remote_backups", "Remote Backups")) {
                Button {
                    Task { await model.refreshWebDAVEntries() }
                } label: {
                    HStack {
                        Label(AppLocalization.text("webdav.action.refresh_remote", "Refresh Remote Backups"), systemImage: "arrow.clockwise")
                        Spacer()
                        if model.loadingWebDAVEntries {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(model.webDAVActionsDisabled)

                if let emptyState = remoteBackupsSnapshot.emptyState {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(emptyState.title)
                            .font(.subheadline.weight(.semibold))
                        Text(emptyState.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, AppSpacing.xs)
                } else {
                    ForEach(remoteBackupsSnapshot.rows) { row in
                        let entry = row.entry
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
                                    Text(row.subtitle)
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
                        .contextMenu {
                            Button(AppLocalization.text("webdav.action.restore_entry", "Restore Backup"), systemImage: "arrow.down.doc") {
                                Task {
                                    await model.restoreBackupFromWebDAVEntry(
                                        entry,
                                        using: library,
                                        sourceManager: sourceManager,
                                        tracker: tracker
                                    )
                                }
                            }
                            .disabled(model.webDAVActionsDisabled)

                            Button(AppLocalization.text("webdav.action.copy_url", "Copy URL"), systemImage: "link") {
                                PlatformPasteboard.copy(entry.url.absoluteString)
                            }

                            Button(AppLocalization.text("common.delete", "Delete"), systemImage: "trash", role: .destructive) {
                                pendingDeleteEntry = entry
                            }
                            .disabled(model.webDAVActionsDisabled)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeleteEntry = entry
                            } label: {
                                Label(AppLocalization.text("common.delete", "Delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Section {
                LabeledContent(AppLocalization.text("common.status", "Status"), value: model.webDAVStatus)
                    .foregroundStyle(.secondary)
            } footer: {
                Text(AppLocalization.text("webdav.hint", "Use an existing WebDAV directory. Backups include tracker bindings and plaintext tracker access tokens. Offline files, active download queue, and pending tracker sync events are not uploaded."))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(AppLocalization.text("webdav.navigation", "WebDAV Sync"))
        .platformNavigationBarTitleDisplayModeInline()
        .alert(AppLocalization.text("webdav.error_title", "WebDAV Error"), isPresented: Binding(
            get: { model.webDAVError != nil },
            set: { if !$0 { model.webDAVError = nil } }
        )) {
            Button(AppLocalization.text("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(model.webDAVError ?? AppLocalization.text("webdav.unknown_error", "Unknown WebDAV error"))
        }
        .alert(AppLocalization.text("webdav.complete_title", "WebDAV Complete"), isPresented: Binding(
            get: { model.webDAVSuccessMessage != nil },
            set: { if !$0 { model.webDAVSuccessMessage = nil } }
        )) {
            Button(AppLocalization.text("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(model.webDAVSuccessMessage ?? "")
        }
        .alert(
            AppLocalization.text("webdav.delete.title", "Delete remote backup?"),
            isPresented: Binding(
                get: { pendingDeleteEntry != nil },
                set: { if !$0 { pendingDeleteEntry = nil } }
            )
        ) {
            Button(AppLocalization.text("common.delete", "Delete"), role: .destructive) {
                guard let entry = pendingDeleteEntry else { return }
                pendingDeleteEntry = nil
                Task { await model.deleteWebDAVEntry(entry) }
            }
            Button(AppLocalization.text("common.cancel", "Cancel"), role: .cancel) {
                pendingDeleteEntry = nil
            }
        } message: {
            Text(
                AppLocalization.format(
                    "webdav.delete.message",
                    "Delete %@ from the remote WebDAV directory? This action cannot be undone.",
                    pendingDeleteEntry?.name ?? ""
                )
            )
        }
        .task {
            if model.webDAVEntries.isEmpty, !model.webDAVDirectoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await model.refreshWebDAVEntries()
            }
        }
    }

    private var lastSyncValue: String {
        guard let date = model.webDAVLastSyncAt else {
            return AppLocalization.text("common.never", "Never")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
