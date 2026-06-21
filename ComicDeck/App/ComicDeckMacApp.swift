import SwiftUI

#if os(macOS)
@main
struct ComicDeckMac: App {
    @State private var readerVM = ReaderViewModel()
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

        WindowGroup(id: "reader", for: ReaderLaunchContext.self) { $context in
            Group {
                if let context {
                    MacReaderWindowView(
                        vm: readerVM,
                        item: context.item,
                        chapterID: context.chapterID,
                        chapterTitle: context.chapterTitle,
                        localChapterDirectory: context.localDirectory,
                        initialPage: context.initialPage,
                        chapterSequence: context.chapterSequence
                    )
                    .frame(minWidth: 600, minHeight: 400)
                    .preferredColorScheme(appAppearance.colorScheme)
                }
            }
            .environment(readerVM.library)
            .environment(readerVM.tracker)
            .task {
                await readerVM.prepareIfNeeded()
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 800, height: 1000)
        .commands {
            GoMenuCommands()
        }

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

private struct GoMenuCommands: Commands {
    @FocusedValue(\.readerController) var controller: ReaderController?

    var body: some Commands {
        CommandMenu(AppLocalization.text("reader.menu.go", "Go")) {
            Button(AppLocalization.text("reader.action.next_page", "Next Page")) {
                controller?.nextPage()
            }

            Button(AppLocalization.text("reader.action.previous_page", "Previous Page")) {
                controller?.previousPage()
            }

            Divider()

            Button(AppLocalization.text("reader.action.next_chapter", "Next Chapter")) {
                controller?.openAdjacentChapter(step: 1)
            }

            Button(AppLocalization.text("reader.action.previous_chapter", "Previous Chapter")) {
                controller?.openAdjacentChapter(step: -1)
            }
        }
    }
}
#endif
