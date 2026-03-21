import Foundation

@usableFromInline
typealias SoupElement = Element

@usableFromInline
typealias SoupTag = Tag

@inline(__always)
func soupParse(_ html: String, _ baseUri: String, _ parser: Parser) throws -> Document {
    try parse(html, baseUri, parser)
}
