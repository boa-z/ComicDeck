import Foundation

protocol HtmlRuntimeEngine: AnyObject {
    func parse(html: String) -> Int
    func querySelector(documentKey: Int, query: String) -> Int?
    func querySelectorAll(documentKey: Int, query: String) -> [Int]
    func getElementById(documentKey: Int, id: String) -> Int?
    func elementQuerySelector(elementKey: Int, query: String) -> Int?
    func elementQuerySelectorAll(elementKey: Int, query: String) -> [Int]
    func children(elementKey: Int) -> [Int]
    func previousElementSibling(elementKey: Int) -> Int?
    func nextElementSibling(elementKey: Int) -> Int?
    func parentElement(elementKey: Int) -> Int?
    func text(elementKey: Int) -> String
    func innerHTML(elementKey: Int) -> String
    func outerHTML(elementKey: Int) -> String
    func tagName(elementKey: Int) -> String
    func attributes(elementKey: Int) -> [String: String]
    func dispose(documentKey: Int)
}

nonisolated final class InProcessHtmlRuntimeEngine: HtmlRuntimeEngine {
    private let store = HtmlDocumentStore()

    func parse(html: String) -> Int {
        do {
            let document = try parseHTML(html)
            return store.storeDocument(document)
        } catch {
            return 0
        }
    }

    func querySelector(documentKey: Int, query: String) -> Int? {
        guard let document = store.document(for: documentKey) else { return nil }
        guard let element = firstElement(in: document, query: query) else { return nil }
        return register(element: element, documentKey: documentKey)
    }

    func querySelectorAll(documentKey: Int, query: String) -> [Int] {
        guard let document = store.document(for: documentKey) else { return [] }
        return elements(in: document, query: query).compactMap { register(element: $0, documentKey: documentKey) }
    }

    func getElementById(documentKey: Int, id: String) -> Int? {
        guard let document = store.document(for: documentKey) else { return nil }
        guard let element = try? document.getElementById(id) else { return nil }
        return register(element: element, documentKey: documentKey)
    }

    func elementQuerySelector(elementKey: Int, query: String) -> Int? {
        guard let element = store.element(for: elementKey), let documentKey = store.documentKey(forElementKey: elementKey) else { return nil }
        guard let match = firstDescendant(in: element, query: query) else { return nil }
        return register(element: match, documentKey: documentKey)
    }

    func elementQuerySelectorAll(elementKey: Int, query: String) -> [Int] {
        guard let element = store.element(for: elementKey), let documentKey = store.documentKey(forElementKey: elementKey) else { return [] }
        return descendantElements(in: element, query: query).compactMap { register(element: $0, documentKey: documentKey) }
    }

    func children(elementKey: Int) -> [Int] {
        guard let element = store.element(for: elementKey), let documentKey = store.documentKey(forElementKey: elementKey) else { return [] }
        return element.children().array().compactMap { register(element: $0, documentKey: documentKey) }
    }

    func previousElementSibling(elementKey: Int) -> Int? {
        sibling(elementKey: elementKey, offset: -1)
    }

    func nextElementSibling(elementKey: Int) -> Int? {
        sibling(elementKey: elementKey, offset: 1)
    }

    func parentElement(elementKey: Int) -> Int? {
        guard let element = store.element(for: elementKey),
              let parent = element.parent(),
              !(parent is Document),
              let documentKey = store.documentKey(forElementKey: elementKey)
        else { return nil }
        return register(element: parent, documentKey: documentKey)
    }

    func text(elementKey: Int) -> String {
        guard let element = store.element(for: elementKey) else { return "" }
        return textContent(of: element)
    }

    func innerHTML(elementKey: Int) -> String {
        guard let element = store.element(for: elementKey) else { return "" }
        return (try? element.html()) ?? ""
    }

    func outerHTML(elementKey: Int) -> String {
        guard let element = store.element(for: elementKey) else { return "" }
        return (try? element.outerHtml()) ?? ""
    }

    func tagName(elementKey: Int) -> String {
        guard let element = store.element(for: elementKey) else { return "" }
        return element.tagName()
    }

    func attributes(elementKey: Int) -> [String: String] {
        guard let element = store.element(for: elementKey) else { return [:] }
        guard let attributes = element.getAttributes() else { return [:] }
        var result: [String: String] = [:]
        for attribute in attributes.asList() {
            result[attribute.getKey()] = attribute.getValue()
        }
        return result
    }

    func dispose(documentKey: Int) {
        store.dispose(documentKey: documentKey)
    }

    private func register(element: Element, documentKey: Int) -> Int {
        store.registerElement(element, documentKey: documentKey)
    }

    private func sibling(elementKey: Int, offset: Int) -> Int? {
        guard let element = store.element(for: elementKey),
              let parent = element.parent(),
              !(parent is Document),
              let documentKey = store.documentKey(forElementKey: elementKey)
        else { return nil }
        let siblings = parent.children().array()
        guard let index = siblings.firstIndex(where: { $0 === element }) else { return nil }
        let target = index + offset
        guard siblings.indices.contains(target) else { return nil }
        return register(element: siblings[target], documentKey: documentKey)
    }

    private func firstElement(in document: Document, query: String) -> Element? {
        elements(in: document, query: query).first
    }

    private func elements(in document: Document, query: String) -> [Element] {
        do {
            return try document.select(query).array()
        } catch {
            return []
        }
    }

    private func firstDescendant(in element: Element, query: String) -> Element? {
        descendantElements(in: element, query: query).first
    }

    private func descendantElements(in element: Element, query: String) -> [Element] {
        do {
            return try element.select(query).array().filter { $0 !== element }
        } catch {
            return []
        }
    }

    private func textContent(of node: Node) -> String {
        if let textNode = node as? TextNode {
            return textNode.getWholeText()
        }
        if let dataNode = node as? DataNode {
            return dataNode.getWholeData()
        }
        return node.childNodes.map(textContent(of:)).joined()
    }
}
