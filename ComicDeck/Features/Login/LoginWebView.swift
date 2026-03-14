import SwiftUI
import WebKit

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
    
    private func webDebugLog(_ message: String) {
        guard RuntimeDebugConsole.isEnabled else { return }
        let line = "[SourceRuntime][DEBUG][LoginWebView] \(message)"
        NSLog("%@", line)
        RuntimeDebugConsole.shared.append(line)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onCookieCaptured: () -> Void
        private let onPageChanged: (String, String) -> Void

        init(onCookieCaptured: @escaping () -> Void, onPageChanged: @escaping (String, String) -> Void) {
            self.onCookieCaptured = onCookieCaptured
            self.onPageChanged = onPageChanged
        }

        private func webDebugLog(_ message: String) {
            guard RuntimeDebugConsole.isEnabled else { return }
            let line = "[SourceRuntime][DEBUG][LoginWebView.Coordinator] \(message)"
            NSLog("%@", line)
            RuntimeDebugConsole.shared.append(line)
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
