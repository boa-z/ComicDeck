import Foundation

private enum HtmlBridgeLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

@inline(__always)
private nonisolated func htmlBridgeLog(_ message: String, level: HtmlBridgeLogLevel = .debug) {
    let line = "[SourceRuntime][\(level.rawValue)][HtmlBridge] \(message)"
    RuntimeDebugConsole.appendRuntimeLine(line)
}

nonisolated final class HtmlRuntimeBridge: @unchecked Sendable {
    static let shared = HtmlRuntimeBridge()

    private let engine: HtmlRuntimeEngine
    private let lock = NSLock()

    private init(engine: HtmlRuntimeEngine = InProcessHtmlRuntimeEngine()) {
        self.engine = engine
        htmlBridgeLog("Initialized in-process HTML runtime engine", level: .info)
    }

    nonisolated func parse(html: String) -> Int {
        withEngine { engine in
            engine.parse(html: html)
        }
    }

    nonisolated func querySelector(documentKey: Int, query: String) -> Int? {
        guard documentKey > 0 else { return nil }
        return withEngine { engine in
            engine.querySelector(documentKey: documentKey, query: query)
        }
    }

    nonisolated func querySelectorAll(documentKey: Int, query: String) -> [Int] {
        guard documentKey > 0 else { return [] }
        return withEngine { engine in
            engine.querySelectorAll(documentKey: documentKey, query: query)
        }
    }

    nonisolated func getElementById(documentKey: Int, id: String) -> Int? {
        guard documentKey > 0 else { return nil }
        return withEngine { engine in
            engine.getElementById(documentKey: documentKey, id: id)
        }
    }

    nonisolated func elementQuerySelector(elementKey: Int, query: String) -> Int? {
        guard elementKey > 0 else { return nil }
        return withEngine { engine in
            engine.elementQuerySelector(elementKey: elementKey, query: query)
        }
    }

    nonisolated func elementQuerySelectorAll(elementKey: Int, query: String) -> [Int] {
        guard elementKey > 0 else { return [] }
        return withEngine { engine in
            engine.elementQuerySelectorAll(elementKey: elementKey, query: query)
        }
    }

    nonisolated func children(elementKey: Int) -> [Int] {
        guard elementKey > 0 else { return [] }
        return withEngine { engine in
            engine.children(elementKey: elementKey)
        }
    }

    nonisolated func nodes(elementKey: Int) -> [Int] {
        guard elementKey > 0 else { return [] }
        return withEngine { engine in
            engine.nodes(elementKey: elementKey)
        }
    }

    nonisolated func previousElementSibling(elementKey: Int) -> Int? {
        guard elementKey > 0 else { return nil }
        return withEngine { engine in
            engine.previousElementSibling(elementKey: elementKey)
        }
    }

    nonisolated func nextElementSibling(elementKey: Int) -> Int? {
        guard elementKey > 0 else { return nil }
        return withEngine { engine in
            engine.nextElementSibling(elementKey: elementKey)
        }
    }

    nonisolated func parentElement(elementKey: Int) -> Int? {
        guard elementKey > 0 else { return nil }
        return withEngine { engine in
            engine.parentElement(elementKey: elementKey)
        }
    }

    nonisolated func text(elementKey: Int) -> String {
        guard elementKey > 0 else { return "" }
        return withEngine { engine in
            engine.text(elementKey: elementKey)
        }
    }

    nonisolated func innerHTML(elementKey: Int) -> String {
        guard elementKey > 0 else { return "" }
        return withEngine { engine in
            engine.innerHTML(elementKey: elementKey)
        }
    }

    nonisolated func outerHTML(elementKey: Int) -> String {
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

    func nodeText(nodeKey: Int) -> String {
        guard nodeKey > 0 else { return "" }
        return withEngine { engine in
            engine.nodeText(nodeKey: nodeKey)
        }
    }

    func nodeType(nodeKey: Int) -> String {
        guard nodeKey > 0 else { return "unknown" }
        return withEngine { engine in
            engine.nodeType(nodeKey: nodeKey)
        }
    }

    func nodeToElement(nodeKey: Int) -> Int? {
        guard nodeKey > 0 else { return nil }
        return withEngine { engine in
            engine.nodeToElement(nodeKey: nodeKey)
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
