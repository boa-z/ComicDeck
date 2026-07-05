import Foundation
import SwiftSoup

nonisolated final class HtmlDocumentStore {
    private struct RegisteredElement {
        let documentKey: Int
        let element: Element
    }

    private struct RegisteredNode {
        let documentKey: Int
        let node: Node
    }

    private var nextDocumentKey = 1
    private var nextElementKey = 1
    private var nextNodeKey = 1
    private var documents: [Int: Document] = [:]
    private var elements: [Int: RegisteredElement] = [:]
    private var nodes: [Int: RegisteredNode] = [:]
    private var elementKeysByDocument: [Int: Set<Int>] = [:]
    private var nodeKeysByDocument: [Int: Set<Int>] = [:]

    func storeDocument(_ document: Document) -> Int {
        let key = nextDocumentKey
        nextDocumentKey += 1
        documents[key] = document
        elementKeysByDocument[key] = []
        nodeKeysByDocument[key] = []
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

    func registerNode(_ node: Node, documentKey: Int) -> Int {
        guard documents[documentKey] != nil else { return 0 }
        let key = nextNodeKey
        nextNodeKey += 1
        nodes[key] = RegisteredNode(documentKey: documentKey, node: node)
        nodeKeysByDocument[documentKey, default: []].insert(key)
        return key
    }

    func element(for key: Int) -> Element? {
        elements[key]?.element
    }

    func node(for key: Int) -> Node? {
        nodes[key]?.node
    }

    func documentKey(forElementKey key: Int) -> Int? {
        elements[key]?.documentKey
    }

    func documentKey(forNodeKey key: Int) -> Int? {
        nodes[key]?.documentKey
    }

    func dispose(documentKey: Int) {
        documents.removeValue(forKey: documentKey)
        let elementKeys = elementKeysByDocument.removeValue(forKey: documentKey) ?? []
        for key in elementKeys {
            elements.removeValue(forKey: key)
        }
        let nodeKeys = nodeKeysByDocument.removeValue(forKey: documentKey) ?? []
        for key in nodeKeys {
            nodes.removeValue(forKey: key)
        }
    }
}
