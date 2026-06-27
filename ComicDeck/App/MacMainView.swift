import SwiftUI
import Observation

#if os(macOS)
@MainActor
struct MacMainView: View {
    private enum SidebarDestination: String, CaseIterable, Identifiable {
        case home
        case discover
        case library
        case downloads
        case sources
        case tracking
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: return AppLocalization.text("tab.home", "Home")
            case .discover: return AppLocalization.text("tab.discover", "Discover")
            case .library: return AppLocalization.text("tab.library", "Library")
            case .downloads: return AppLocalization.text("downloads.navigation.title", "Downloads")
            case .sources: return AppLocalization.text("source.management.title", "Sources")
            case .tracking: return AppLocalization.text("tracking.navigation.title", "Tracking")
            case .settings: return AppLocalization.text("settings.navigation.title", "Settings")
            }
        }

        var systemImage: String {
            switch self {
            case .home: return "house"
            case .discover: return "sparkles.rectangle.stack"
            case .library: return "books.vertical"
            case .downloads: return "arrow.down.circle"
            case .sources: return "puzzlepiece.extension"
            case .tracking: return "rectangle.stack.badge.person.crop"
            case .settings: return "gearshape"
            }
        }
    }

    @Bindable var vm: ReaderViewModel
    @State private var selectedDestination: SidebarDestination? = .home
    @State private var sourceSearchRoute: SourceSearchRoute?
    @State private var commandController = MacAppCommandController()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    private struct SourceSearchRoute: Identifiable {
        let id = UUID()
        let sourceKey: String
        let keyword: String
    }

    private nonisolated func appDebugLog(_ message: String) {
        let line = "[SourceRuntime][DEBUG][MacMainView] \(message)"
        RuntimeDebugConsole.appendRuntimeLine(line)
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarDestination.allCases, selection: $selectedDestination) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
            }
            .navigationTitle(AppLocalization.text("settings.about.app_name", "ComicDeck"))
            .frame(minWidth: 190)
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 240)
        } detail: {
            detailView
        }
        .frame(minWidth: 820, minHeight: 600)
        .task {
            await vm.prepareIfNeeded()
        }
        .onAppear {
            configureCommandController()
        }
        .environment(vm.library)
        .environment(vm.tracker)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await vm.tracker.flushPendingSync() }
        }
        .sheet(item: $sourceSearchRoute) { route in
            MacSourceScopedSearchView(
                vm: vm,
                sourceKey: route.sourceKey,
                initialKeyword: route.keyword
            )
            .environment(vm.library)
            .environment(vm.tracker)
            .frame(minWidth: 880, minHeight: 600)
        }
        .overlay {
            LoginSheetPresenter(login: vm.login, appDebugLog: appDebugLog)
        }
        .focusedSceneValue(\.macAppCommandController, commandController)
    }

    private func configureCommandController() {
        commandController.openSearch = { openSearchWindow() }
        commandController.openDownloads = { selectedDestination = .downloads }
        commandController.openSources = { selectedDestination = .sources }
        commandController.openSettings = { MacAppCommandsActions.showSettingsWindow() }
        commandController.refreshCurrentView = {
            Task { await refreshSelectedDestination() }
        }
        commandController.canOpenDownloads = true
        commandController.canOpenSources = true
        commandController.canOpenSettings = true
        commandController.canRefreshCurrentView = true
    }

    private func refreshSelectedDestination() async {
        switch selectedDestination ?? .home {
        case .home, .discover, .library:
            await vm.prepareIfNeeded()
        case .downloads:
            await vm.library.refreshDownloadList()
        case .sources:
            await vm.sourceManager.refreshRemoteSources(forceRefresh: true)
        case .tracking:
            try? await vm.tracker.reload()
        case .settings:
            await vm.prepareIfNeeded()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedDestination ?? .home {
        case .home:
            NavigationStack {
                HomeView(
                    vm: vm,
                    sourceManager: vm.sourceManager,
                    onOpenSearch: openSearchWindow,
                    onOpenSettings: { selectedDestination = .settings },
                    onOpenDiscover: { selectedDestination = .discover },
                    onOpenLibrary: { selectedDestination = .library },
                    onTagSearchRequested: { tag, sourceKey in
                        sourceSearchRoute = SourceSearchRoute(sourceKey: sourceKey, keyword: tag)
                    }
                )
                .environment(vm.library)
                .environment(vm.tracker)
            }
        case .discover:
            NavigationStack {
                DiscoverView(vm: vm, onOpenSearch: openSearchWindow)
                    .environment(vm.library)
                    .environment(vm.tracker)
            }
        case .library:
            MacLibraryWorkspaceView(vm: vm, sourceManager: vm.sourceManager) { tag, sourceKey in
                sourceSearchRoute = SourceSearchRoute(sourceKey: sourceKey, keyword: tag)
            }
            .environment(vm.library)
            .environment(vm.tracker)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .downloads:
            NavigationStack {
                MacDownloadWorkspaceView(vm: vm)
                    .environment(vm.library)
            }
        case .sources:
            NavigationStack {
                MacSourceWorkspaceView(vm: vm, sourceManager: vm.sourceManager)
            }
        case .tracking:
            NavigationStack {
                MacTrackingWorkspaceView(vm: vm, sourceManager: vm.sourceManager)
                    .environment(vm.library)
                    .environment(vm.tracker)
            }
        case .settings:
            NavigationStack {
                SettingsView()
                    .environment(vm.library)
                    .environment(vm.sourceManager)
                    .environment(vm.tracker)
            }
        }
    }

    private func openSearchWindow() {
        openWindow(id: "search")
    }
}
#endif
