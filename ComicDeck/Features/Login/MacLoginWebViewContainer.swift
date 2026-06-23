import SwiftUI

#if os(macOS)
@MainActor
struct MacLoginWebViewContainer: View {
    let url: URL
    let onClose: () -> Void
    let onCookieCaptured: () -> Void
    let onPageChanged: (String, String) -> Void

    @State private var navigationState = MacLoginWebNavigationState()

    var body: some View {
        VStack(spacing: 0) {
            MacLoginWebToolbar(
                navigationState: navigationState,
                onClose: onClose
            )

            Divider()

            LoginWebView(
                url: url,
                navigationState: navigationState,
                onCookieCaptured: onCookieCaptured,
                onPageChanged: onPageChanged
            )
        }
        .frame(
            minWidth: MacLoginWebMetrics.minWidth,
            idealWidth: MacLoginWebMetrics.idealWidth,
            minHeight: MacLoginWebMetrics.minHeight,
            idealHeight: MacLoginWebMetrics.idealHeight
        )
        .background(AppSurface.card)
        .onDisappear {
            navigationState.stopLoading()
        }
    }
}

private struct MacLoginWebToolbar: View {
    @Bindable var navigationState: MacLoginWebNavigationState
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Button(AppLocalization.text("common.back", "Back"), systemImage: "chevron.left") {
                navigationState.goBack()
            }
            .disabled(!navigationState.canGoBack)
            .labelStyle(.iconOnly)
            .help(AppLocalization.text("common.back", "Back"))

            Button(AppLocalization.text("login.web.forward", "Forward"), systemImage: "chevron.right") {
                navigationState.goForward()
            }
            .disabled(!navigationState.canGoForward)
            .labelStyle(.iconOnly)
            .help(AppLocalization.text("login.web.forward", "Forward"))

            Button(refreshTitle, systemImage: refreshSystemImage) {
                if navigationState.isLoading {
                    navigationState.stopLoading()
                } else {
                    navigationState.reload()
                }
            }
            .labelStyle(.iconOnly)
            .help(refreshTitle)

            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)

                Text(addressText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppSurface.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if navigationState.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
            }

            Button(AppLocalization.text("common.close", "Close"), systemImage: "xmark") {
                navigationState.stopLoading()
                onClose()
            }
            .labelStyle(.iconOnly)
            .help(AppLocalization.text("common.close", "Close"))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
    }

    private var addressText: String {
        if !navigationState.currentURL.isEmpty {
            return navigationState.currentURL
        }
        return AppLocalization.text("login.web.loading_address", "Loading page...")
    }

    private var refreshTitle: String {
        if navigationState.isLoading {
            return AppLocalization.text("login.web.stop_loading", "Stop loading")
        }
        return AppLocalization.text("common.refresh", "Refresh")
    }

    private var refreshSystemImage: String {
        navigationState.isLoading ? "xmark" : "arrow.clockwise"
    }
}

private enum MacLoginWebMetrics {
    static let minWidth: CGFloat = 900
    static let idealWidth: CGFloat = 980
    static let minHeight: CGFloat = 640
    static let idealHeight: CGFloat = 760
}
#endif
