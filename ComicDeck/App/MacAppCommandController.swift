#if os(macOS)
import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class MacAppCommandController {
    var openSearch: () -> Void = {}
    var openDownloads: () -> Void = {}
    var openSources: () -> Void = {}
    var openSettings: () -> Void = {}
    var refreshCurrentView: () -> Void = {}
    var canOpenDownloads = false
    var canOpenSources = false
    var canOpenSettings = false
    var canRefreshCurrentView = false
}

@MainActor
@Observable
final class MacSelectionCommandController {
    var open: () -> Void = {}
    var delete: () -> Void = {}
    var copyTitle: () -> Void = {}
    var copyID: () -> Void = {}
    var reveal: () -> Void = {}
    var export: () -> Void = {}
    var canOpen = false
    var canDelete = false
    var canCopyTitle = false
    var canCopyID = false
    var canReveal = false
    var canExport = false
    var openTitle = AppLocalization.text("common.open", "Open")
    var exportTitle = AppLocalization.text("downloads.action.export_zip", "Export ZIP")

    func reset() {
        open = {}
        delete = {}
        copyTitle = {}
        copyID = {}
        reveal = {}
        export = {}
        canOpen = false
        canDelete = false
        canCopyTitle = false
        canCopyID = false
        canReveal = false
        canExport = false
        openTitle = AppLocalization.text("common.open", "Open")
        exportTitle = AppLocalization.text("downloads.action.export_zip", "Export ZIP")
    }
}

@MainActor
@Observable
final class MacSearchCommandController {
    var focusSearch: () -> Void = {}
    var canFocusSearch = false
}

@MainActor
enum MacAppCommandsActions {
    static func showSettingsWindow() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

struct MacAppCommandControllerFocusedValueKey: FocusedValueKey {
    typealias Value = MacAppCommandController
}

struct MacSelectionCommandControllerFocusedValueKey: FocusedValueKey {
    typealias Value = MacSelectionCommandController
}

struct MacSearchCommandControllerFocusedValueKey: FocusedValueKey {
    typealias Value = MacSearchCommandController
}

extension FocusedValues {
    var macAppCommandController: MacAppCommandController? {
        get { self[MacAppCommandControllerFocusedValueKey.self] }
        set { self[MacAppCommandControllerFocusedValueKey.self] = newValue }
    }

    var macSelectionCommandController: MacSelectionCommandController? {
        get { self[MacSelectionCommandControllerFocusedValueKey.self] }
        set { self[MacSelectionCommandControllerFocusedValueKey.self] = newValue }
    }

    var macSearchCommandController: MacSearchCommandController? {
        get { self[MacSearchCommandControllerFocusedValueKey.self] }
        set { self[MacSearchCommandControllerFocusedValueKey.self] = newValue }
    }
}
#endif
