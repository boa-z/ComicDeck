import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct SettingsView: View {
    @Environment(LibraryViewModel.self) private var library
    @Environment(SourceManagerViewModel.self) private var sourceManager
    @Environment(TrackerViewModel.self) private var tracker
    @AppStorage(RuntimeDebugConsole.enabledKey) private var debugEnabled = false
    @AppStorage("ui.appAppearance") private var appAppearanceRaw = AppAppearance.system.rawValue
    @AppStorage("ui.comicBrowseMode") private var browseModeRaw = ComicBrowseDisplayMode.list.rawValue
    @State private var debugConsole = RuntimeDebugConsole.shared
    @State private var model = SettingsScreenModel()
    @State private var showingBackupImporter = false

    private var appAppearance: AppAppearance {
        get { AppAppearance(rawValue: appAppearanceRaw) ?? .system }
        nonmutating set { appAppearanceRaw = newValue.rawValue }
    }

    private var browseMode: ComicBrowseDisplayMode {
        get { ComicBrowseDisplayMode(rawValue: browseModeRaw) ?? .list }
        nonmutating set { browseModeRaw = newValue.rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Section(AppLocalization.text("settings.section.appearance", "Appearance")) {
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Label(AppLocalization.text("settings.appearance.theme", "Theme"), systemImage: appAppearance.systemImage)
                            .font(.subheadline.weight(.semibold))

                        Picker(AppLocalization.text("settings.appearance.theme", "Theme"), selection: Binding(
                            get: { appAppearance },
                            set: { appAppearance = $0 }
                        )) {
                            ForEach(AppAppearance.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)

                        Label(AppLocalization.text("settings.appearance.browse_layout", "Comic Browse Layout"), systemImage: "square.grid.2x2")
                            .font(.subheadline.weight(.semibold))

                        Picker(AppLocalization.text("settings.appearance.browse_layout", "Comic Browse Layout"), selection: Binding(
                            get: { browseMode },
                            set: { browseMode = $0 }
                        )) {
                            ForEach(ComicBrowseDisplayMode.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(AppLocalization.text("settings.appearance.browse_layout_hint", "Applies to search, favorites, history, category, and ranking pages."))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(AppLocalization.text("settings.appearance.theme_hint", "Theme applies across the whole app."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section(AppLocalization.text("settings.section.reader", "Reader")) {
                    HStack {
                        Text(AppLocalization.text("settings.reader.cache", "Reader Cache"))
                        Spacer()
                        Text(model.readerCacheSize)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text(AppLocalization.text("settings.reader.memory_cache", "Reader Memory Cache"))
                        Spacer()
                        Text(model.readerCacheMemory)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text(AppLocalization.text("settings.reader.cache_efficiency", "Reader Cache Efficiency"))
                        Spacer()
                        Text(model.readerCacheHitRate)
                            .foregroundStyle(.secondary)
                    }

                    Button(AppLocalization.text("settings.reader.clear_cache", "Clear Reader Cache"), role: .destructive) {
                        Task { await model.clearReaderCache(using: library) }
                    }
                    .disabled(model.clearingReaderCache)
                }

                Section(AppLocalization.text("settings.section.diagnostics", "Diagnostics")) {
                    NavigationLink {
                        DebugLogsView(console: debugConsole, model: model, debugEnabled: $debugEnabled)
                    } label: {
                        Label(AppLocalization.text("settings.diagnostics.debug_logs", "Debug Logs"), systemImage: "ladybug")
                    }
                }

                Section(AppLocalization.text("settings.section.data", "Data")) {
                    NavigationLink {
                        WebDAVSyncView(model: model)
                    } label: {
                        Label(AppLocalization.text("settings.data.webdav", "WebDAV Sync"), systemImage: "externaldrive.connected.to.line.below")
                    }

                    Button {
                        model.prepareBackupShare(using: library)
                    } label: {
                        Label(AppLocalization.text("settings.data.export_backup", "Export Backup"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.sharingBackup || model.restoringBackup)

                    Button {
                        showingBackupImporter = true
                    } label: {
                        Label(AppLocalization.text("settings.data.restore_backup", "Restore Backup"), systemImage: "arrow.down.doc")
                    }
                    .disabled(model.sharingBackup || model.restoringBackup)

                    Text(AppLocalization.text("settings.data.backup_hint", "Backups include favorites, reading history, source preferences, and reader/app settings. Offline files and active download queue are not included."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Tracking") {
                    NavigationLink {
                        TrackingSettingsView()
                    } label: {
                        Label("Tracking", systemImage: "arrow.triangle.2.circlepath")
                    }
                    ForEach(TrackerProvider.allCases) { provider in
                        if let account = tracker.account(for: provider) {
                            HStack {
                                Text(provider.title)
                                Spacer()
                                Text(account.displayName)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    NavigationLink {
                        AboutView(
                            appVersion: appVersion,
                            buildVersion: buildVersion,
                            gitBranch: gitBranch,
                            gitCommit: gitCommit
                        )
                    } label: {
                        HStack(spacing: AppSpacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(AppLocalization.text("settings.about.app_name", "ComicDeck"))
                                    .font(.body.weight(.semibold))
                                Text(
                                    AppLocalization.format(
                                        "settings.about.version",
                                        "Version %@",
                                        appVersion
                                    )
                                )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(
                                AppLocalization.format(
                                    "settings.about.build",
                                    "Build %@",
                                    buildVersion
                                )
                            )
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle(AppLocalization.text("settings.navigation.title", "Settings"))
            .sheet(item: Binding(
                get: { model.sharedLogURL.map(ShareFile.init) },
                set: { _ in model.sharedLogURL = nil }
            )) { shareFile in
                ActivityShareSheet(items: [shareFile.url])
            }
            .sheet(item: Binding(
                get: { model.sharedBackupURL.map(ShareFile.init) },
                set: { _ in model.sharedBackupURL = nil }
            )) { shareFile in
                ActivityShareSheet(items: [shareFile.url])
            }
            .fileImporter(
                isPresented: $showingBackupImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(urls):
                    guard let url = urls.first else { return }
                    let granted = url.startAccessingSecurityScopedResource()
                    Task {
                        await model.restoreBackup(from: url, using: library, sourceManager: sourceManager)
                        if granted {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                case let .failure(error):
                    model.backupError = error.localizedDescription
                }
            }
            .alert(AppLocalization.text("settings.backup.error_title", "Backup Error"), isPresented: Binding(
                get: { model.backupError != nil },
                set: { if !$0 { model.backupError = nil } }
            )) {
                Button(AppLocalization.text("common.ok", "OK"), role: .cancel) {}
            } message: {
                Text(model.backupError ?? AppLocalization.text("settings.backup.unknown_error", "Unknown backup error"))
            }
            .alert(AppLocalization.text("settings.backup.restored_title", "Backup Restored"), isPresented: Binding(
                get: { model.backupSuccessMessage != nil },
                set: { if !$0 { model.backupSuccessMessage = nil } }
            )) {
                Button(AppLocalization.text("common.ok", "OK"), role: .cancel) {}
            } message: {
                Text(model.backupSuccessMessage ?? "")
            }
            .task {
                await model.loadReaderCacheSize(using: library)
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    private var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }

    private var gitBranch: String {
        buildMetadata["CDGitBranch"] as? String ?? "-"
    }

    private var gitCommit: String {
        buildMetadata["CDGitCommit"] as? String ?? "-"
    }

    private var buildMetadata: [String: Any] {
        guard
            let url = Bundle.main.url(forResource: "BuildMetadata", withExtension: "plist"),
            let dictionary = NSDictionary(contentsOf: url) as? [String: Any]
        else {
            return [:]
        }

        return dictionary
    }
}

private struct DebugLogsView: View {
    private enum DebugLogFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case warnAndError = "Warn+Error"
        case error = "Error"

        var id: String { rawValue }

        func includes(_ line: String) -> Bool {
            switch self {
            case .all:
                return true
            case .warnAndError:
                return line.contains("[WARN]") || line.contains("[ERROR]")
            case .error:
                return line.contains("[ERROR]")
            }
        }
    }

    @Bindable var console: RuntimeDebugConsole
    @Bindable var model: SettingsScreenModel
    @Binding var debugEnabled: Bool
    @State private var copiedAlertVisible = false
    @State private var filter: DebugLogFilter = .all

    private var filteredLines: [String] {
        console.lines.filter { filter.includes($0) }
    }

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            Toggle(AppLocalization.text("settings.debug.enable_logs", "Enable Debug Logs"), isOn: $debugEnabled)
                .padding(.horizontal, AppSpacing.screen)

            HStack(spacing: AppSpacing.sm) {
                Label(
                    AppLocalization.format(
                        "settings.debug.visible_count",
                        "%@ visible",
                        String(filteredLines.count)
                    ),
                    systemImage: "line.3.horizontal.decrease.circle"
                )
                Spacer()
                Label(console.activeLogDescription(), systemImage: "doc.text")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, AppSpacing.screen)

            if console.lines.isEmpty {
                ContentUnavailableView(
                    "No Debug Logs",
                    systemImage: "doc.text",
                    description: Text("Enable debug logging and reproduce the issue to collect logs.")
                )
                .padding(.horizontal, AppSpacing.lg)
            } else {
                VStack(spacing: AppSpacing.sm) {
                    Picker("Log Filter", selection: $filter) {
                        ForEach(DebugLogFilter.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, AppSpacing.screen)

                    if filteredLines.isEmpty {
                        ContentUnavailableView(
                            AppLocalization.text("settings.debug.no_matching.title", "No Matching Logs"),
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text(AppLocalization.text("settings.debug.no_matching.subtitle", "The current filter does not match any in-memory log lines."))
                        )
                        .padding(.horizontal, AppSpacing.lg)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            Text(filteredLines.joined(separator: "\n"))
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(AppSpacing.md)
                        }
                        .background(AppSurface.subtle, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                        .padding(.horizontal, AppSpacing.screen)
                    }
                }
                .padding(.top, AppSpacing.sm)
            }
        }
        .navigationTitle(AppLocalization.text("settings.diagnostics.debug_logs", "Debug Logs"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(AppLocalization.text("settings.debug.copied_title", "Copied to Clipboard"), isPresented: $copiedAlertVisible) {
            Button(AppLocalization.text("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(AppLocalization.text("settings.debug.copied_message", "The visible debug logs have been copied."))
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: AppSpacing.xs) {
                HStack(spacing: AppSpacing.sm) {
                    Button {
                        model.prepareDebugLogShare(using: console)
                    } label: {
                        HStack(spacing: AppSpacing.xs) {
                            if model.sharingLog {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                            Text(AppLocalization.text("common.share", "Share"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(!console.activeLogFileExists() || model.sharingLog)

                    Button {
                        UIPasteboard.general.string = filteredLines.joined(separator: "\n")
                        copiedAlertVisible = true
                    } label: {
                        Label(AppLocalization.text("common.copy", "Copy"), systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(filteredLines.isEmpty)

                    Button(role: .destructive) {
                        console.clear()
                    } label: {
                        Label(AppLocalization.text("common.clear", "Clear"), systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(console.lines.isEmpty)
                }
                .font(.body)
                .padding(.bottom, AppSpacing.xs)

                if let error = console.lastWriteError ?? model.debugShareError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, AppSpacing.screen)
            .padding(.top, AppSpacing.sm)
            .padding(.bottom, AppSpacing.sm)
            .background(.ultraThinMaterial)
        }
    }

}

private struct AboutView: View {
    let appVersion: String
    let buildVersion: String
    let gitBranch: String
    let gitCommit: String

    private let repoURL = URL(string: "https://github.com/boa-z/ComicDeck")!

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("ComicDeck")
                        .font(.title3.weight(.semibold))
                    Text("Comic management and reading for iOS.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, AppSpacing.xs)
            }

            Section("App") {
                aboutRow(title: "Version", value: "\(appVersion) (\(buildVersion))")
                aboutRow(title: "Revision", value: "\(gitBranch)/\(gitCommit)")
            }

            Section("Project") {
                Link(destination: repoURL) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Repository")
                            Text(repoURL.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } icon: {
                        Image(systemName: "link")
                    }
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func aboutRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}
