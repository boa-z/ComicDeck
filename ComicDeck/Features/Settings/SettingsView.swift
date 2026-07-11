import SwiftUI
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
                    NavigationLink {
                        TranslationSettingsView()
                    } label: {
                        Label(AppLocalization.text("settings.translation.title", "Translation"), systemImage: "globe")
                    }

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
                        WebDAVSyncView(
                            model: model,
                            library: library,
                            sourceManager: sourceManager,
                            tracker: tracker
                        )
                    } label: {
                        Label(AppLocalization.text("settings.data.webdav", "WebDAV Sync"), systemImage: "externaldrive.connected.to.line.below")
                    }

                    Button {
                        #if os(macOS)
                        exportBackupToFile()
                        #else
                        model.prepareBackupShare(using: library, tracker: tracker)
                        #endif
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

                    Text(AppLocalization.text("settings.data.backup_hint", "Backups include favorites, reading history, source preferences, tracker bindings, and plaintext tracker access tokens. Offline files, active download queue, and pending tracker sync events are not included."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(AppLocalization.text("tracking.section.title", "Tracking")) {
                    NavigationLink {
                        TrackingSettingsView()
                    } label: {
                        Label(AppLocalization.text("tracking.section.title", "Tracking"), systemImage: "arrow.triangle.2.circlepath")
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
                        await model.restoreBackup(from: url, using: library, sourceManager: sourceManager, tracker: tracker)
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
            .alert(AppLocalization.text("settings.backup.exported_title", "Backup Exported"), isPresented: Binding(
                get: { model.backupExportSuccessMessage != nil },
                set: { if !$0 { model.backupExportSuccessMessage = nil } }
            )) {
                Button(AppLocalization.text("common.ok", "OK"), role: .cancel) {}
            } message: {
                Text(model.backupExportSuccessMessage ?? "")
            }
            .task {
                await model.loadReaderCacheSize(using: library)
            }
        }
    }

    #if os(macOS)
    private func exportBackupToFile() {
        model.sharingBackup = true
        model.backupError = nil
        model.backupExportSuccessMessage = nil
        defer { model.sharingBackup = false }

        do {
            let temporaryURL = try model.makeBackupExport(using: library, tracker: tracker)
            guard let destinationURL = try PlatformFileActions.copyFileToUserSelectedDestination(
                sourceURL: temporaryURL,
                suggestedFileName: temporaryURL.lastPathComponent
            ) else {
                return
            }
            PlatformFileActions.reveal(url: destinationURL)
            model.backupExportSuccessMessage = AppLocalization.format(
                "settings.backup.exported_message",
                "Backup exported to %@.",
                destinationURL.lastPathComponent
            )
        } catch {
            model.backupError = error.localizedDescription
        }
    }
    #endif

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

    private struct DebugLogSnapshot: Hashable {
        let allLineCount: Int
        let visibleLineCount: Int
        let visibleText: String
        let activeLogDescription: String
        let activeLogFileExists: Bool

        var hasLines: Bool { allLineCount > 0 }
        var hasVisibleLines: Bool { visibleLineCount > 0 }

        init(console: RuntimeDebugConsole, filter: DebugLogFilter) {
            let lines = console.lines
            let visibleLines: [String]
            if filter == .all {
                visibleLines = lines
            } else {
                visibleLines = lines.filter { filter.includes($0) }
            }

            self.allLineCount = lines.count
            self.visibleLineCount = visibleLines.count
            self.visibleText = visibleLines.joined(separator: "\n")
            self.activeLogDescription = console.activeLogDescription()
            self.activeLogFileExists = console.activeLogFileExists()
        }
    }

    @Bindable var console: RuntimeDebugConsole
    @Bindable var model: SettingsScreenModel
    @Binding var debugEnabled: Bool
    @State private var copiedAlertVisible = false
    @State private var exportedLogMessage: String?
    @State private var filter: DebugLogFilter = .all

    var body: some View {
        let snapshot = DebugLogSnapshot(console: console, filter: filter)

        VStack(spacing: AppSpacing.sm) {
            Toggle(AppLocalization.text("settings.debug.enable_logs", "Enable Debug Logs"), isOn: $debugEnabled)
                .padding(.horizontal, AppSpacing.screen)

            HStack(spacing: AppSpacing.sm) {
                Label(
                    AppLocalization.format(
                        "settings.debug.visible_count",
                        "%@ visible",
                        String(snapshot.visibleLineCount)
                    ),
                    systemImage: "line.3.horizontal.decrease.circle"
                )
                Spacer()
                Label(snapshot.activeLogDescription, systemImage: "doc.text")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, AppSpacing.screen)

            if !snapshot.hasLines {
                ContentUnavailableView(
                    AppLocalization.text("settings.debug.empty.title", "No Debug Logs"),
                    systemImage: "doc.text",
                    description: Text(AppLocalization.text("settings.debug.empty.subtitle", "Enable debug logging and reproduce the issue to collect logs."))
                )
                .padding(.horizontal, AppSpacing.lg)
            } else {
                VStack(spacing: AppSpacing.sm) {
                    Picker(AppLocalization.text("settings.debug.filter", "Log Filter"), selection: $filter) {
                        ForEach(DebugLogFilter.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, AppSpacing.screen)

                    if !snapshot.hasVisibleLines {
                        ContentUnavailableView(
                            AppLocalization.text("settings.debug.no_matching.title", "No Matching Logs"),
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text(AppLocalization.text("settings.debug.no_matching.subtitle", "The current filter does not match any in-memory log lines."))
                        )
                        .padding(.horizontal, AppSpacing.lg)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            Text(snapshot.visibleText)
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
        .platformNavigationBarTitleDisplayModeInline()
        .alert(AppLocalization.text("settings.debug.copied_title", "Copied to Clipboard"), isPresented: $copiedAlertVisible) {
            Button(AppLocalization.text("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(AppLocalization.text("settings.debug.copied_message", "The visible debug logs have been copied."))
        }
        .alert(AppLocalization.text("settings.debug.exported_title", "Log Exported"), isPresented: Binding(
            get: { exportedLogMessage != nil },
            set: { if !$0 { exportedLogMessage = nil } }
        )) {
            Button(AppLocalization.text("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(exportedLogMessage ?? "")
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: AppSpacing.xs) {
                HStack(spacing: AppSpacing.sm) {
                    Button {
                        #if os(macOS)
                        exportLogToFile()
                        #else
                        model.prepareDebugLogShare(using: console)
                        #endif
                    } label: {
                        HStack(spacing: AppSpacing.xs) {
                            if model.sharingLog {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                            Text(AppLocalization.text("settings.debug.export", "Export"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(!snapshot.activeLogFileExists || model.sharingLog)

                    Button {
                        PlatformPasteboard.copy(snapshot.visibleText)
                        copiedAlertVisible = true
                    } label: {
                        Label(AppLocalization.text("common.copy", "Copy"), systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!snapshot.hasVisibleLines)

                    Button(role: .destructive) {
                        console.clear()
                    } label: {
                        Label(AppLocalization.text("common.clear", "Clear"), systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!snapshot.hasLines)
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

    #if os(macOS)
    private func exportLogToFile() {
        model.sharingLog = true
        model.debugShareError = nil
        defer { model.sharingLog = false }

        do {
            let temporaryURL = try model.makeDebugLogExport(using: console)
            guard let destinationURL = try PlatformFileActions.copyFileToUserSelectedDestination(
                sourceURL: temporaryURL,
                suggestedFileName: temporaryURL.lastPathComponent
            ) else {
                return
            }
            PlatformFileActions.reveal(url: destinationURL)
            exportedLogMessage = AppLocalization.format(
                "settings.debug.exported_message",
                "Debug log exported to %@.",
                destinationURL.lastPathComponent
            )
        } catch {
            model.debugShareError = error.localizedDescription
        }
    }
    #endif

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
                    Text(AppLocalization.text("settings.about.app_name", "ComicDeck"))
                        .font(.title3.weight(.semibold))
                    Text(AppLocalization.text("settings.about.description", "Comic management and reading."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, AppSpacing.xs)
            }

            Section(AppLocalization.text("settings.about.section.app", "App")) {
                aboutRow(
                    title: AppLocalization.text("settings.about.version_label", "Version"),
                    value: "\(appVersion) (\(buildVersion))"
                )
                aboutRow(
                    title: AppLocalization.text("settings.about.revision_label", "Revision"),
                    value: "\(gitBranch)/\(gitCommit)"
                )
            }

            Section(AppLocalization.text("settings.about.section.project", "Project")) {
                Link(destination: repoURL) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppLocalization.text("settings.about.repository", "Repository"))
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
        .navigationTitle(AppLocalization.text("settings.about.title", "About"))
        .platformNavigationBarTitleDisplayModeInline()
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
