import SwiftUI

#if os(macOS)
@main
struct ComicDeckMac: App {
    @AppStorage("ui.appAppearance") private var appAppearanceRaw = AppAppearance.system.rawValue

    private var appAppearance: AppAppearance {
        AppAppearance(rawValue: appAppearanceRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            MacMainView()
                .preferredColorScheme(appAppearance.colorScheme)
        }
        .windowStyle(.titleBar)

        Settings {
            MacSettingsHostView()
                .preferredColorScheme(appAppearance.colorScheme)
        }
    }
}

private struct MacSettingsHostView: View {
    @State private var vm = ReaderViewModel()

    var body: some View {
        SettingsView()
            .environment(vm.library)
            .environment(vm.sourceManager)
            .environment(vm.tracker)
            .task {
                await vm.prepareIfNeeded()
            }
    }
}
#endif
