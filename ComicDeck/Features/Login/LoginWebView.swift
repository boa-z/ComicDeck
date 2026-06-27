import SwiftUI
import WebKit

#if os(iOS)
@MainActor
struct LoginWebView: UIViewRepresentable {
    let url: URL
    let onCookieCaptured: () -> Void
    let onPageChanged: (String, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCookieCaptured: onCookieCaptured, onPageChanged: onPageChanged)
    }

    func makeUIView(context: Context) -> WKWebView {
        webDebugLog("makeUIView start, url=\(url.absoluteString)")
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        webDebugLog("makeUIView issued load request")
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        webDebugLog("updateUIView called, currentURL=\(uiView.url?.absoluteString ?? "nil")")
    }
    
    private nonisolated func webDebugLog(_ message: String) {
        let line = "[SourceRuntime][DEBUG][LoginWebView] \(message)"
        RuntimeDebugConsole.appendRuntimeLine(line)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onCookieCaptured: () -> Void
        private let onPageChanged: (String, String) -> Void

        init(onCookieCaptured: @escaping () -> Void, onPageChanged: @escaping (String, String) -> Void) {
            self.onCookieCaptured = onCookieCaptured
            self.onPageChanged = onPageChanged
        }

        private nonisolated func webDebugLog(_ message: String) {
            let line = "[SourceRuntime][DEBUG][LoginWebView.Coordinator] \(message)"
            RuntimeDebugConsole.appendRuntimeLine(line)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            webDebugLog("didStartProvisionalNavigation: \(webView.url?.absoluteString ?? "nil")")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let currentURL = webView.url?.absoluteString ?? ""
            let currentTitle = webView.title ?? ""
            webDebugLog("didFinish: url=\(currentURL), title=\(currentTitle)")
            Task { @MainActor in
                self.onPageChanged(currentURL, currentTitle)
            }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                self.webDebugLog("didFinish cookie count=\(cookies.count)")
                for cookie in cookies {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
                Task { @MainActor in
                    self.onCookieCaptured()
                }
            }
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            webDebugLog("didFail: \(error.localizedDescription)")
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            webDebugLog("didFailProvisionalNavigation: \(error.localizedDescription)")
        }
    }
}
#elseif os(macOS)
@MainActor
struct LoginWebView: NSViewRepresentable {
    let url: URL
    let navigationState: MacLoginWebNavigationState?
    let onCookieCaptured: () -> Void
    let onPageChanged: (String, String) -> Void

    init(
        url: URL,
        navigationState: MacLoginWebNavigationState? = nil,
        onCookieCaptured: @escaping () -> Void,
        onPageChanged: @escaping (String, String) -> Void
    ) {
        self.url = url
        self.navigationState = navigationState
        self.onCookieCaptured = onCookieCaptured
        self.onPageChanged = onPageChanged
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(navigationState: navigationState, onCookieCaptured: onCookieCaptured, onPageChanged: onPageChanged)
    }

    func makeNSView(context: Context) -> WKWebView {
        webDebugLog("makeNSView start, url=\(url.absoluteString)")
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(to: webView)
        webView.load(URLRequest(url: url))
        webDebugLog("makeNSView issued load request")
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        webDebugLog("updateNSView called, currentURL=\(nsView.url?.absoluteString ?? "nil")")
        context.coordinator.navigationState = navigationState
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.tearDown(webView: nsView)
    }

    private nonisolated func webDebugLog(_ message: String) {
        let line = "[SourceRuntime][DEBUG][LoginWebView] \(message)"
        RuntimeDebugConsole.appendRuntimeLine(line)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var navigationState: MacLoginWebNavigationState?
        private let onCookieCaptured: () -> Void
        private let onPageChanged: (String, String) -> Void
        private var isActive = true

        init(
            navigationState: MacLoginWebNavigationState?,
            onCookieCaptured: @escaping () -> Void,
            onPageChanged: @escaping (String, String) -> Void
        ) {
            self.navigationState = navigationState
            self.onCookieCaptured = onCookieCaptured
            self.onPageChanged = onPageChanged
        }

        func attach(to webView: WKWebView) {
            isActive = true
            navigationState?.attach(webView)
        }

        func detach(from webView: WKWebView) {
            navigationState?.detach(webView)
        }

        func tearDown(webView: WKWebView) {
            isActive = false
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.loadHTMLString("", baseURL: nil)
            detach(from: webView)
        }

        private nonisolated func webDebugLog(_ message: String) {
            let line = "[SourceRuntime][DEBUG][LoginWebView.Coordinator] \(message)"
            RuntimeDebugConsole.appendRuntimeLine(line)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard isActive else { return }
            webDebugLog("didStartProvisionalNavigation: \(webView.url?.absoluteString ?? "nil")")
            navigationState?.update(from: webView, isLoading: true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard isActive else { return }
            let currentURL = webView.url?.absoluteString ?? ""
            let currentTitle = webView.title ?? ""
            webDebugLog("didFinish: url=\(currentURL), title=\(currentTitle)")
            navigationState?.update(from: webView, isLoading: false)
            Task { @MainActor in
                guard self.isActive else { return }
                self.onPageChanged(currentURL, currentTitle)
            }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                self.webDebugLog("didFinish cookie count=\(cookies.count)")
                for cookie in cookies {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
                Task { @MainActor in
                    guard self.isActive else { return }
                    self.onCookieCaptured()
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard isActive else { return }
            webDebugLog("didFail: \(error.localizedDescription)")
            navigationState?.update(from: webView, isLoading: false)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard isActive else { return }
            webDebugLog("didFailProvisionalNavigation: \(error.localizedDescription)")
            navigationState?.update(from: webView, isLoading: false)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard isActive else { return }
            webDebugLog("webViewWebContentProcessDidTerminate")
            navigationState?.update(from: webView, isLoading: false)
        }
    }
}
#endif
