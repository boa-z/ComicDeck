import Foundation
import WebKit
import UIKit

// MARK: - Logging (internal to this file)

private enum HtmlBridgeLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

@inline(__always)
private func htmlBridgeLog(_ message: String, level: HtmlBridgeLogLevel = .debug) {
    guard RuntimeDebugConsole.isEnabled else { return }
    let line = "[SourceRuntime][\(level.rawValue)][HtmlBridge] \(message)"
    NSLog("%@", line)
    RuntimeDebugConsole.shared.append(line)
}

// MARK: - HtmlRuntimeBridge

/// WKWebView-backed HTML parser used by the JS runtime to execute DOM queries.
/// Uses a singleton shared instance to avoid creating multiple WebViews.
final class HtmlRuntimeBridge {
    static let shared = HtmlRuntimeBridge()

    private var webView: WKWebView
    private let loaderDelegate = HtmlRuntimeLoaderDelegate()
    private let evalTimeoutSeconds: TimeInterval = 8
    private var setupDone = false
    private var pageReady = false

    private init() {
        self.webView = Self.createWebView()
        Self.runOnMainSync {
            self.webView.navigationDelegate = self.loaderDelegate
        }
        self.pageReady = Self.loadBlankPageSync(on: webView, delegate: loaderDelegate)
        _ = evaluateSync("document.documentElement.innerHTML = '<html><body></body></html>'; true;")
    }

    private func rebuildWebView() {
        let newWebView = Self.createWebView()
        Self.runOnMainSync {
            newWebView.navigationDelegate = self.loaderDelegate
        }
        self.webView = newWebView
        self.setupDone = false
        self.pageReady = Self.loadBlankPageSync(on: newWebView, delegate: loaderDelegate)
        if !self.pageReady {
            htmlBridgeLog("Rebuild failed: blank page timeout", level: .error)
            return
        }
        self.ensureSetup()
    }

    private static func createWebView() -> WKWebView {
        if Thread.isMainThread {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            return WKWebView(frame: .zero, configuration: config)
        }
        var webView: WKWebView?
        DispatchQueue.main.sync {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            webView = WKWebView(frame: .zero, configuration: config)
        }
        return webView!
    }

    private static func runOnMainSync(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
            return
        }
        DispatchQueue.main.sync {
            action()
        }
    }

    private static func loadBlankPageSync(on webView: WKWebView, delegate: HtmlRuntimeLoaderDelegate) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        runOnMainSync {
            delegate.onLoadFinished = {
                delegate.onLoadFinished = nil
                semaphore.signal()
            }
            webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
        }
        return semaphore.wait(timeout: .now() + 5) == .success
    }

    // MARK: - Public DOM API

    func parse(html: String) -> Int {
        ensureSetup()
        return (call(name: "parse", args: [html]) as? NSNumber)?.intValue ?? 0
    }

    func querySelector(documentKey: Int, query: String) -> Int? {
        guard documentKey > 0 else { return nil }
        ensureSetup()
        let value = (call(name: "querySelector", args: [documentKey, query]) as? NSNumber)?.intValue ?? 0
        return value > 0 ? value : nil
    }

    func querySelectorAll(documentKey: Int, query: String) -> [Int] {
        guard documentKey > 0 else { return [] }
        ensureSetup()
        return intArray(call(name: "querySelectorAll", args: [documentKey, query]))
    }

    func getElementById(documentKey: Int, id: String) -> Int? {
        guard documentKey > 0 else { return nil }
        ensureSetup()
        let value = (call(name: "getElementById", args: [documentKey, id]) as? NSNumber)?.intValue ?? 0
        return value > 0 ? value : nil
    }

    func elementQuerySelector(elementKey: Int, query: String) -> Int? {
        guard elementKey > 0 else { return nil }
        ensureSetup()
        let value = (call(name: "elementQuerySelector", args: [elementKey, query]) as? NSNumber)?.intValue ?? 0
        return value > 0 ? value : nil
    }

    func elementQuerySelectorAll(elementKey: Int, query: String) -> [Int] {
        guard elementKey > 0 else { return [] }
        ensureSetup()
        return intArray(call(name: "elementQuerySelectorAll", args: [elementKey, query]))
    }

    func children(elementKey: Int) -> [Int] {
        guard elementKey > 0 else { return [] }
        ensureSetup()
        return intArray(call(name: "children", args: [elementKey]))
    }

    func text(elementKey: Int) -> String {
        guard elementKey > 0 else { return "" }
        ensureSetup()
        return (call(name: "text", args: [elementKey]) as? String) ?? ""
    }

    func innerHTML(elementKey: Int) -> String {
        guard elementKey > 0 else { return "" }
        ensureSetup()
        return (call(name: "innerHTML", args: [elementKey]) as? String) ?? ""
    }

    func attributes(elementKey: Int) -> [String: String] {
        guard elementKey > 0 else { return [:] }
        ensureSetup()
        return call(name: "attributes", args: [elementKey]) as? [String: String] ?? [:]
    }

    func dispose(documentKey: Int) {
        guard documentKey > 0 else { return }
        ensureSetup()
        _ = call(name: "dispose", args: [documentKey])
    }

    // MARK: - Private Implementation

    private func intArray(_ value: Any?) -> [Int] {
        let list = value as? [Any] ?? []
        return list.compactMap {
            if let n = $0 as? NSNumber { return n.intValue }
            if let i = $0 as? Int { return i }
            return nil
        }
    }

    private func ensureSetup() {
        guard !setupDone else { return }
        let script = """
        window.__sourceHtml = {
          docs: {},
          elements: {},
          nextDoc: 1,
          nextElement: 1,
          registerElement(el) {
            if (!el) return 0;
            const id = this.nextElement++;
            this.elements[id] = el;
            return id;
          },
          parse(html) {
            const parser = new DOMParser();
            const doc = parser.parseFromString(String(html || ''), 'text/html');
            const id = this.nextDoc++;
            this.docs[id] = doc;
            return id;
          },
          querySelector(docId, query) {
            const doc = this.docs[Number(docId)];
            if (!doc) return 0;
            return this.registerElement(doc.querySelector(String(query)));
          },
          querySelectorAll(docId, query) {
            const doc = this.docs[Number(docId)];
            if (!doc) return [];
            return Array.from(doc.querySelectorAll(String(query))).map((el) => this.registerElement(el));
          },
          getElementById(docId, id) {
            const doc = this.docs[Number(docId)];
            if (!doc) return 0;
            return this.registerElement(doc.getElementById(String(id)));
          },
          elementQuerySelector(elId, query) {
            const el = this.elements[Number(elId)];
            if (!el) return 0;
            return this.registerElement(el.querySelector(String(query)));
          },
          elementQuerySelectorAll(elId, query) {
            const el = this.elements[Number(elId)];
            if (!el) return [];
            return Array.from(el.querySelectorAll(String(query))).map((item) => this.registerElement(item));
          },
          children(elId) {
            const el = this.elements[Number(elId)];
            if (!el) return [];
            return Array.from(el.children || []).map((item) => this.registerElement(item));
          },
          text(elId) {
            const el = this.elements[Number(elId)];
            return el ? (el.textContent || '') : '';
          },
          innerHTML(elId) {
            const el = this.elements[Number(elId)];
            return el ? (el.innerHTML || '') : '';
          },
          attributes(elId) {
            const el = this.elements[Number(elId)];
            if (!el || !el.attributes) return {};
            const obj = {};
            for (const attr of Array.from(el.attributes)) {
              obj[attr.name] = attr.value;
            }
            return obj;
          },
          dispose(docId) {
            delete this.docs[Number(docId)];
          }
        };
        true;
        """
        let initialized = (evaluateSync(script) as? NSNumber)?.boolValue == true
        setupDone = initialized
        if !initialized {
            htmlBridgeLog("Setup failed", level: .error)
        }
    }

    private func call(name: String, args: [Any]) -> Any? {
        if !setupDone {
            ensureSetup()
        }
        guard setupDone else { return nil }

        guard let data = try? JSONSerialization.data(withJSONObject: args),
              let argsJSON = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let expr = """
        (() => {
          const out = window.__sourceHtml.\(name).apply(window.__sourceHtml, \(argsJSON));
          return out === undefined ? null : out;
        })();
        """
        let value = evaluateSync(expr)
        if value == nil {
            htmlBridgeLog("Call failed: method=\(name), argsCount=\(args.count)", level: .error)
        }
        return value
    }

    private func evaluateSync(_ script: String) -> Any? {
        if !pageReady {
            pageReady = Self.loadBlankPageSync(on: webView, delegate: loaderDelegate)
            if !pageReady {
                htmlBridgeLog("Blank page load timeout", level: .error)
                return nil
            }
        }

        let first = evaluateOnce(script, timeoutSeconds: evalTimeoutSeconds)
        if !first.timedOut {
            if first.error == nil, first.value != nil {
                return first.value
            }

            if let evalError = first.error {
                htmlBridgeLog("Evaluate failed: \(evalError.localizedDescription), rebuilding webView", level: .warn)
            } else {
                htmlBridgeLog("Evaluate returned nil without timeout, rebuilding webView", level: .warn)
            }

            rebuildWebView()
            guard pageReady else {
                htmlBridgeLog("Evaluate failed: rebuild did not recover page", level: .error)
                return nil
            }

            let second = evaluateOnce(script, timeoutSeconds: evalTimeoutSeconds)
            if second.timedOut {
                htmlBridgeLog("Evaluate timeout after rebuild", level: .error)
                return nil
            }
            if let evalError = second.error {
                htmlBridgeLog("Evaluate failed after rebuild: \(evalError.localizedDescription)", level: .error)
            }
            return second.value
        }

        htmlBridgeLog("Evaluate timeout, rebuilding webView and retrying once", level: .warn)
        rebuildWebView()
        guard pageReady else {
            htmlBridgeLog("Evaluate timeout", level: .error)
            return nil
        }

        let second = evaluateOnce(script, timeoutSeconds: evalTimeoutSeconds)
        if second.timedOut {
            htmlBridgeLog("Evaluate timeout after rebuild", level: .error)
            return nil
        }

        if let evalError = second.error {
            htmlBridgeLog("Evaluate failed: \(evalError.localizedDescription)", level: .error)
        }
        return second.value
    }

    private func evaluateOnce(_ script: String, timeoutSeconds: TimeInterval) -> (value: Any?, error: Error?, timedOut: Bool) {
        // Must NOT be called from the main thread in production paths.
        // All JS engine calls go through engineExecutionQueue (background).
        var result: Any?
        var evalError: Error?

        if Thread.isMainThread {
            var done = false
            webView.evaluateJavaScript(script) { value, error in
                result = value
                evalError = error
                done = true
            }
            let timeout = Date().addingTimeInterval(timeoutSeconds)
            while !done && Date() < timeout {
                RunLoop.current.run(mode: .common, before: Date().addingTimeInterval(0.003))
            }
            return (result, evalError, !done)
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            self.webView.evaluateJavaScript(script) { value, error in
                result = value
                evalError = error
                semaphore.signal()
            }
        }
        let timedOut = semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut
        return (result, evalError, timedOut)
    }
}

// MARK: - HtmlRuntimeLoaderDelegate

final class HtmlRuntimeLoaderDelegate: NSObject, WKNavigationDelegate {
    var onLoadFinished: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onLoadFinished?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onLoadFinished?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onLoadFinished?()
    }
}
