import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum PlatformPasteboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

enum PlatformColors {
    static var systemBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var secondarySystemBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #elseif os(macOS)
        Color(nsColor: .underPageBackgroundColor)
        #endif
    }

    static var systemGroupedBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var tertiarySystemBackground: Color {
        #if os(iOS)
        Color(uiColor: .tertiarySystemBackground)
        #elseif os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    static var secondarySystemFill: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemFill)
        #elseif os(macOS)
        Color(nsColor: .quaternaryLabelColor)
        #endif
    }

    static var tertiaryLabel: Color {
        #if os(iOS)
        Color(uiColor: .tertiaryLabel)
        #elseif os(macOS)
        Color(nsColor: .tertiaryLabelColor)
        #endif
    }
}

extension ToolbarItemPlacement {
    static var platformTopBarLeading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    static var platformTopBarTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

extension View {
    @ViewBuilder
    func platformNavigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder
    func platformTextInputAutocapitalizationNever() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    @ViewBuilder
    func platformTextInputAutocapitalizationWords() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.words)
        #else
        self
        #endif
    }

    @ViewBuilder
    func platformKeyboardURL() -> some View {
        #if os(iOS)
        self.keyboardType(.URL)
        #else
        self
        #endif
    }

    @ViewBuilder
    func platformKeyboardDecimalPad() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad)
        #else
        self
        #endif
    }

    @ViewBuilder
    func platformKeyboardNumberPad() -> some View {
        #if os(iOS)
        self.keyboardType(.numberPad)
        #else
        self
        #endif
    }

    @ViewBuilder
    func platformStatusBarHidden(_ hidden: Bool) -> some View {
        #if os(iOS)
        self.statusBarHidden(hidden)
        #else
        self
        #endif
    }

    @ViewBuilder
    func platformHideTabBar() -> some View {
        #if os(iOS)
        self.toolbar(.hidden, for: .tabBar)
        #else
        self
        #endif
    }

    @ViewBuilder
    func platformInsetGroupedListStyle() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self.listStyle(.inset)
        #endif
    }

    @ViewBuilder
    func platformPresentationDetentsMedium() -> some View {
        #if os(iOS)
        self.presentationDetents([.medium])
        #else
        self.frame(minWidth: 420, minHeight: 360)
        #endif
    }

    @ViewBuilder
    func platformPresentationDetentsMediumLarge() -> some View {
        #if os(iOS)
        self.presentationDetents([.medium, .large])
        #else
        self.frame(minWidth: 520, minHeight: 480)
        #endif
    }

    @ViewBuilder
    func platformPresentationDetentsPagePicker() -> some View {
        #if os(iOS)
        self.presentationDetents([.height(220)])
        #else
        self.frame(minWidth: 360, minHeight: 220)
        #endif
    }
}
