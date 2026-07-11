import SwiftUI
import Observation

@MainActor
struct MainView: View {
    private struct SourceSearchRoute: Identifiable {
        let id = UUID()
        let sourceKey: String
        let keyword: String
    }

    private enum MainTab: Int {
        case home
        case discover
        case library
    }

    @State private var vm = ReaderViewModel()
    @State private var selectedTab: MainTab = .home
    @State private var sourceSearchRoute: SourceSearchRoute?
    @State private var showGlobalSearch = false
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("ui.appAppearance") private var appAppearanceRaw = AppAppearance.system.rawValue

    private var appAppearance: AppAppearance {
        get { AppAppearance(rawValue: appAppearanceRaw) ?? .system }
        nonmutating set { appAppearanceRaw = newValue.rawValue }
    }

    private nonisolated func appDebugLog(_ message: String) {
        let line = "[SourceRuntime][DEBUG][MainView] \(message)"
        RuntimeDebugConsole.appendRuntimeLine(line)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(
                vm: vm,
                sourceManager: vm.sourceManager,
                onOpenSearch: { showGlobalSearch = true },
                onOpenSettings: { showSettings = true },
                onOpenDiscover: { selectedTab = .discover },
                onOpenLibrary: { selectedTab = .library },
                onTagSearchRequested: { tag, sourceKey in
                    sourceSearchRoute = SourceSearchRoute(sourceKey: sourceKey, keyword: tag)
                }
            )
            .environment(vm.library)
            .environment(vm.tracker)
            .tabItem {
                Label(AppLocalization.text("home.navigation.title", "Home"), systemImage: "house")
            }
            .tag(MainTab.home)

            DiscoverView(vm: vm, onOpenSearch: { showGlobalSearch = true })
                .environment(vm.library)
                .environment(vm.tracker)
                .tabItem {
                    Label(AppLocalization.text("discover.navigation.title", "Discover"), systemImage: "sparkles.rectangle.stack")
                }
                .tag(MainTab.discover)

            LibraryHomeView(vm: vm, sourceManager: vm.sourceManager) { tag, sourceKey in
                sourceSearchRoute = SourceSearchRoute(sourceKey: sourceKey, keyword: tag)
            }
            .environment(vm.library)
            .environment(vm.tracker)
            .tabItem {
                Label(AppLocalization.text("library.navigation.title", "Library"), systemImage: "books.vertical")
            }
            .tag(MainTab.library)
        }
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
        }
        .sheet(isPresented: $showGlobalSearch) {
            SearchView(vm: vm)
                .environment(vm.library)
                .environment(vm.tracker)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(vm.library)
                .environment(vm.sourceManager)
                .environment(vm.tracker)
        }
        .overlay {
            LoginSheetPresenter(login: vm.login, appDebugLog: appDebugLog)
        }
        .preferredColorScheme(appAppearance.colorScheme)
    }
}
