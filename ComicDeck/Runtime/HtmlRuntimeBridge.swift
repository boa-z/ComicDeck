import Foundation

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

nonisolated final class HtmlRuntimeBridge {
    static let shared = HtmlRuntimeBridge()

    private let engine: HtmlRuntimeEngine
    private let lock = NSLock()

    private init(engine: HtmlRuntimeEngine = InProcessHtmlRuntimeEngine()) {
        self.engine = engine
        htmlBridgeLog("Initialized in-process HTML runtime engine", level: .info)
    }

    func parse(html: String) -> Int {
        withEngine { engine in
            engine.parse(html: html)
        }
    }

    func querySelector(documentKey: Int, query: String) -> Int? {
        guard documentKey > 0 else { return nil }
        return withEngine { engine in
            engine.querySelector(documentKey: documentKey, query: query)
        }
    }

    func querySelectorAll(documentKey: Int, query: String) -> [Int] {
        guard documentKey > 0 else { return [] }
        return withEngine { engine in
            engine.querySelectorAll(documentKey: documentKey, query: query)
        }
    }

    func getElementById(documentKey: Int, id: String) -> Int? {
        guard documentKey > 0 else { return nil }
        return withEngine { engine in
            engine.getElementById(documentKey: documentKey, id: id)
        }
    }

    func elementQuerySelector(elementKey: Int, query: String) -> Int? {
        guard elementKey > 0 else { return nil }
        return withEngine { engine in
            engine.elementQuerySelector(elementKey: elementKey, query: query)
        }
    }

    func elementQuerySelectorAll(elementKey: Int, query: String) -> [Int] {
        guard elementKey > 0 else { return [] }
        return withEngine { engine in
            engine.elementQuerySelectorAll(elementKey: elementKey, query: query)
        }
    }

    func children(elementKey: Int) -> [Int] {
        guard elementKey > 0 else { return [] }
        return withEngine { engine in
            engine.children(elementKey: elementKey)
        }
    }

    func previousElementSibling(elementKey: Int) -> Int? {
        guard elementKey > 0 else { return nil }
        return withEngine { engine in
            engine.previousElementSibling(elementKey: elementKey)
        }
    }

    func nextElementSibling(elementKey: Int) -> Int? {
        guard elementKey > 0 else { return nil }
        return withEngine { engine in
            engine.nextElementSibling(elementKey: elementKey)
        }
    }

    func parentElement(elementKey: Int) -> Int? {
        guard elementKey > 0 else { return nil }
        return withEngine { engine in
            engine.parentElement(elementKey: elementKey)
        }
    }

    func text(elementKey: Int) -> String {
        guard elementKey > 0 else { return "" }
        return withEngine { engine in
            engine.text(elementKey: elementKey)
        }
    }

    func innerHTML(elementKey: Int) -> String {
        guard elementKey > 0 else { return "" }
        return withEngine { engine in
            engine.innerHTML(elementKey: elementKey)
        }
    }

    func outerHTML(elementKey: Int) -> String {
        guard elementKey > 0 else { return "" }
        return withEngine { engine in
            engine.outerHTML(elementKey: elementKey)
        }
    }

    func tagName(elementKey: Int) -> String {
        guard elementKey > 0 else { return "" }
        return withEngine { engine in
            engine.tagName(elementKey: elementKey)
        }
    }

    func attributes(elementKey: Int) -> [String: String] {
        guard elementKey > 0 else { return [:] }
        return withEngine { engine in
            engine.attributes(elementKey: elementKey)
        }
    }

    func dispose(documentKey: Int) {
        guard documentKey > 0 else { return }
        withEngine { engine in
            engine.dispose(documentKey: documentKey)
        }
    }

    private func withEngine<T>(_ work: (HtmlRuntimeEngine) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work(engine)
    }
}
