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

    @State private var vm = ReaderViewModel()
    @State private var selectedDestination: SidebarDestination? = .home
    @State private var sourceSearchRoute: SourceSearchRoute?
    @State private var showGlobalSearch = false
    @Environment(\.scenePhase) private var scenePhase

    private struct SourceSearchRoute: Identifiable {
        let id = UUID()
        let sourceKey: String
        let keyword: String
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarDestination.allCases, selection: $selectedDestination) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
            }
            .navigationTitle(AppLocalization.text("settings.about.app_name", "ComicDeck"))
            .frame(minWidth: 190)
        } detail: {
            detailView
        }
        .frame(minWidth: 980, minHeight: 680)
        .task {
            await vm.prepareIfNeeded()
        }
        .environment(vm.library)
        .environment(vm.tracker)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await vm.tracker.flushPendingSync() }
        }
        .sheet(item: $sourceSearchRoute) { route in
            NavigationStack {
                SourceScopedSearchView(
                    vm: vm,
                    sourceKey: route.sourceKey,
                    initialKeyword: route.keyword
                )
                .environment(vm.library)
                .environment(vm.tracker)
            }
            .frame(minWidth: 820, minHeight: 620)
        }
        .sheet(isPresented: $showGlobalSearch) {
            SearchView(vm: vm)
                .environment(vm.library)
                .environment(vm.tracker)
                .frame(minWidth: 820, minHeight: 620)
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
                    onOpenSearch: { showGlobalSearch = true },
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
                DiscoverView(vm: vm, onOpenSearch: { showGlobalSearch = true })
                    .environment(vm.library)
                    .environment(vm.tracker)
            }
        case .library:
            NavigationStack {
                LibraryHomeView(vm: vm, sourceManager: vm.sourceManager) { tag, sourceKey in
                    sourceSearchRoute = SourceSearchRoute(sourceKey: sourceKey, keyword: tag)
                }
                .environment(vm.library)
                .environment(vm.tracker)
            }
        case .downloads:
            NavigationStack {
                DownloadManagerView(vm: vm)
                    .environment(vm.library)
            }
        case .sources:
            MacSourceWorkspaceView(vm: vm, sourceManager: vm.sourceManager)
        case .tracking:
            MacTrackingWorkspaceView(vm: vm, sourceManager: vm.sourceManager)
                .environment(vm.library)
                .environment(vm.tracker)
        case .settings:
            NavigationStack {
                SettingsView()
                    .environment(vm.library)
                    .environment(vm.sourceManager)
                    .environment(vm.tracker)
            }
        }
    }
}
#endif
