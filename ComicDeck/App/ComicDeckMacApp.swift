import SwiftUI

#if os(macOS)
import AppKit

@main
struct ComicDeckMac: App {
    @State private var readerVM = ReaderViewModel()
    @AppStorage("ui.appAppearance") private var appAppearanceRaw = AppAppearance.system.rawValue

    private var appAppearance: AppAppearance {
        AppAppearance(rawValue: appAppearanceRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            MacMainView(vm: readerVM)
                .preferredColorScheme(appAppearance.colorScheme)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 760)
        .commands {
            MacAppCommands()
        }

        WindowGroup(id: "search") {
            MacSearchWindowHostView(vm: readerVM)
                .environment(readerVM.library)
                .environment(readerVM.tracker)
                .preferredColorScheme(appAppearance.colorScheme)
                .task {
                    await readerVM.prepareIfNeeded()
                }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 980, height: 720)

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
            MacSettingsHostView(vm: readerVM)
                .preferredColorScheme(appAppearance.colorScheme)
        }
    }
}

private struct MacAppCommands: Commands {
    @FocusedValue(\.macAppCommandController) var controller: MacAppCommandController?
    @FocusedValue(\.macSelectionCommandController) var selectionController: MacSelectionCommandController?
    @FocusedValue(\.macSearchCommandController) var searchController: MacSearchCommandController?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(AppLocalization.text("search.title", "Search")) {
                if searchController?.canFocusSearch == true {
                    searchController?.focusSearch()
                } else {
                    controller?.openSearch()
                }
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(searchController?.canFocusSearch != true && controller == nil)
        }

        CommandGroup(after: .sidebar) {
            Button(AppLocalization.text("common.refresh", "Refresh")) {
                controller?.refreshCurrentView()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(controller?.canRefreshCurrentView != true)
        }

        CommandMenu(AppLocalization.text("mac.menu.selection", "Selection")) {
            Button(selectionController?.openTitle ?? AppLocalization.text("common.open", "Open")) {
                selectionController?.open()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(selectionController?.canOpen != true)

            Button(AppLocalization.text("downloads.action.delete", "Delete"), role: .destructive) {
                selectionController?.delete()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(selectionController?.canDelete != true)

            Divider()

            Button(AppLocalization.text("detail.action.copy_title", "Copy Title")) {
                selectionController?.copyTitle()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(selectionController?.canCopyTitle != true)

            Button(AppLocalization.text("detail.action.copy_id", "Copy ID")) {
                selectionController?.copyID()
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(selectionController?.canCopyID != true)

            Divider()

            Button(AppLocalization.text("downloads.action.reveal_in_finder", "Reveal in Finder")) {
                selectionController?.reveal()
            }
            .disabled(selectionController?.canReveal != true)

            Button(selectionController?.exportTitle ?? AppLocalization.text("downloads.action.export_zip", "Export ZIP")) {
                selectionController?.export()
            }
            .disabled(selectionController?.canExport != true)
        }

        CommandMenu(AppLocalization.text("mac.menu.navigate", "Navigate")) {
            Button(AppLocalization.text("downloads.navigation.title", "Downloads")) {
                controller?.openDownloads()
            }
            .keyboardShortcut("1", modifiers: [.command, .option])
            .disabled(controller?.canOpenDownloads != true)

            Button(AppLocalization.text("source.management.title", "Sources")) {
                controller?.openSources()
            }
            .keyboardShortcut("2", modifiers: [.command, .option])
            .disabled(controller?.canOpenSources != true)

            Button(AppLocalization.text("settings.navigation.title", "Settings")) {
                controller?.openSettings()
            }
            .keyboardShortcut(",", modifiers: [.command])
            .disabled(controller?.canOpenSettings != true)
        }
    }
}

private struct MacSettingsHostView: View {
    @Bindable var vm: ReaderViewModel

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

private struct MacSearchWindowHostView: View {
    @Bindable var vm: ReaderViewModel
    @State private var commandController = MacAppCommandController()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MacSearchWorkspaceView(vm: vm)
            .frame(minWidth: 880, minHeight: 600)
            .onAppear {
                configureCommandController()
            }
            .focusedSceneValue(\.macAppCommandController, commandController)
    }

    private func configureCommandController() {
        commandController.openSearch = { openWindow(id: "search") }
        commandController.openDownloads = {}
        commandController.openSources = {}
        commandController.openSettings = {
            MacAppCommandsActions.showSettingsWindow()
        }
        commandController.refreshCurrentView = {
            Task {
                await vm.prepareIfNeeded()
            }
        }
        commandController.canOpenSettings = true
        commandController.canRefreshCurrentView = true
    }
}

private struct GoMenuCommands: Commands {
    @FocusedValue(\.readerController) var controller: ReaderController?
    @FocusedValue(\.macReaderCommandState) var commandState: MacReaderCommandState?

    var body: some Commands {
        CommandMenu(AppLocalization.text("reader.menu.go", "Go")) {
            Button(AppLocalization.text("reader.action.previous_page", "Previous Page")) {
                controller?.previousPage()
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(controller?.canGoToPreviousPage != true)

            Button(AppLocalization.text("reader.action.next_page", "Next Page")) {
                controller?.nextPage()
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(controller?.canGoToNextPage != true)

            Button(AppLocalization.text("reader.action.first_page", "First Page")) {
                controller?.firstPage()
            }
            .disabled(controller?.canGoToFirstPage != true)

            Button(AppLocalization.text("reader.action.last_page", "Last Page")) {
                controller?.lastPage()
            }
            .disabled(controller?.canGoToLastPage != true)

            Divider()

            Button(AppLocalization.text("reader.action.previous_chapter", "Previous Chapter")) {
                controller?.openAdjacentChapter(step: -1)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(controller?.canGoToPreviousChapter != true)

            Button(AppLocalization.text("reader.action.next_chapter", "Next Chapter")) {
                controller?.openAdjacentChapter(step: 1)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(controller?.canGoToNextChapter != true)

            Divider()

            Button(AppLocalization.text("reader.action.reload_page", "Reload Current Page")) {
                controller?.reloadCurrentPage()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(controller?.canReloadCurrentPage != true)
        }

        CommandMenu(AppLocalization.text("reader.menu.view", "Reader")) {
            Menu(AppLocalization.text("reader.chrome.mode", "Mode")) {
                ForEach(ReaderMode.allCases) { mode in
                    Button {
                        commandState?.setReaderMode(mode)
                    } label: {
                        if commandState?.readerMode == mode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                    .disabled(commandState == nil)
                }
            }

            Menu(AppLocalization.text("reader.background.mode", "Background")) {
                ForEach(ReaderBackgroundMode.allCases) { mode in
                    Button {
                        commandState?.setBackgroundMode(mode)
                    } label: {
                        if commandState?.backgroundMode == mode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                    .disabled(commandState == nil)
                }
            }

            Divider()

            Button(AppLocalization.text("common.close", "Close")) {
                commandState?.closeWindow()
            }
            .keyboardShortcut("w", modifiers: [.command])
            .disabled(commandState == nil)
        }
    }
}
#endif
