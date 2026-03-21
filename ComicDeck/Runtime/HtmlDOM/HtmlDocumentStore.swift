import Foundation

nonisolated final class HtmlDocumentStore {
    private struct RegisteredElement {
        let documentKey: Int
        let element: Element
    }

    private var nextDocumentKey = 1
    private var nextElementKey = 1
    private var documents: [Int: Document] = [:]
    private var elements: [Int: RegisteredElement] = [:]
    private var elementKeysByDocument: [Int: Set<Int>] = [:]

    func storeDocument(_ document: Document) -> Int {
        let key = nextDocumentKey
        nextDocumentKey += 1
        documents[key] = document
        elementKeysByDocument[key] = []
        return key
    }

    func document(for key: Int) -> Document? {
        documents[key]
    }

    func registerElement(_ element: Element, documentKey: Int) -> Int {
        guard documents[documentKey] != nil else { return 0 }
        let key = nextElementKey
        nextElementKey += 1
        elements[key] = RegisteredElement(documentKey: documentKey, element: element)
        elementKeysByDocument[documentKey, default: []].insert(key)
        return key
    }

    func element(for key: Int) -> Element? {
        elements[key]?.element
    }

    func documentKey(forElementKey key: Int) -> Int? {
        elements[key]?.documentKey
    }

    func dispose(documentKey: Int) {
        documents.removeValue(forKey: documentKey)
        let elementKeys = elementKeysByDocument.removeValue(forKey: documentKey) ?? []
        for key in elementKeys {
            elements.removeValue(forKey: key)
        }
    }
}
