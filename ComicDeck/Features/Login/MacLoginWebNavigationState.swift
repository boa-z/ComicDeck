import Observation
import WebKit

#if os(macOS)
@MainActor
@Observable
final class MacLoginWebNavigationState {
    var currentURL = ""
    var currentTitle = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false

    @ObservationIgnored
    private weak var webView: WKWebView?

    func attach(_ webView: WKWebView) {
        self.webView = webView
        update(from: webView, isLoading: webView.isLoading)
    }

    func detach(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        self.webView = nil
        isLoading = false
    }

    func update(from webView: WKWebView, isLoading: Bool) {
        currentURL = webView.url?.absoluteString ?? currentURL
        currentTitle = webView.title ?? currentTitle
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        self.isLoading = isLoading
    }

    func goBack() {
        guard let webView, webView.canGoBack else { return }
        webView.goBack()
        update(from: webView, isLoading: webView.isLoading)
    }

    func goForward() {
        guard let webView, webView.canGoForward else { return }
        webView.goForward()
        update(from: webView, isLoading: webView.isLoading)
    }

    func reload() {
        guard let webView else { return }
        webView.reload()
        update(from: webView, isLoading: true)
    }

    func stopLoading() {
        guard let webView else { return }
        webView.stopLoading()
        update(from: webView, isLoading: false)
    }
}
#endif
