import SwiftUI

/// A widget that displays comment content with support for rich text formatting.
/// Supports HTML tags (<br/>, <a>, <b>, <i>, <u>, <s>, <strong>, <span>) and auto-linking of URLs.
/// Modeled after venera's RichCommentContent implementation.
struct RichTextContent: View {
    let text: String
    let lineLimit: Int?
    
    init(text: String, lineLimit: Int? = nil) {
        self.text = text
        self.lineLimit = lineLimit
    }
    
    var body: some View {
        if needsRichRendering() {
            RichTextView(text: text, lineLimit: lineLimit)
        } else {
            Text(text)
                .lineLimit(lineLimit)
        }
    }
    
    /// Check if the text contains HTML tags or URLs that need rich rendering
    private func needsRichRendering() -> Bool {
        return text.contains("<") || text.contains("http://") || text.contains("https://")
    }
}

/// Internal view that handles HTML parsing and rich text rendering
private struct RichTextView: View {
    let text: String
    let lineLimit: Int?
    
    var attributedText: AttributedString {
        return HTMLParser.parse(text)
    }
    
    var body: some View {
        let textView = Text(attributedText)
            .textSelection(.enabled)
        
        if let limit = lineLimit {
            textView.lineLimit(limit)
        } else {
            textView.lineLimit(nil)
        }
    }
}

/// HTML tag parser that converts HTML to AttributedString
private struct HTMLParser {
    private struct Tag {
        let name: String
        let tagAttributes: [String: String]
        
        func apply(to attributes: AttributeContainer) -> AttributeContainer {
            var result = attributes
            
            switch name {
            case "b", "strong":
                result.font = Font.system(.body).bold()
            case "i", "em":
                result.font = Font.system(.body).italic()
            case "u":
                result.underlineStyle = .single
            case "s", "strike":
                result.strikethroughStyle = .single
            case "a":
                result.foregroundColor = .blue
                if let href = tagAttributes["href"] {
                    result.link = URL(string: href)
                }
            case "span":
                if let style = tagAttributes["style"] {
                    result = applyInlineStyle(style, to: result)
                }
            default:
                break
            }
            
            return result
        }
        
        private func applyInlineStyle(_ style: String, to attributes: AttributeContainer) -> AttributeContainer {
            var result = attributes
            let pairs = style.split(separator: ";")
            
            for pair in pairs {
                let parts = pair.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                
                switch key {
                case "font-weight":
                    if value == "bold" {
                        result.font = Font.system(.body).bold()
                    }
                case "font-style":
                    if value == "italic" {
                        result.font = Font.system(.body).italic()
                    }
                case "text-decoration":
                    if value.contains("underline") {
                        result.underlineStyle = .single
                    }
                    if value.contains("line-through") {
                        result.strikethroughStyle = .single
                    }
                default:
                    break
                }
            }
            
            return result
        }
    }
    
    static func parse(_ html: String) -> AttributedString {
        var result = AttributedString()
        var text = html
        var tagStack: [Tag] = []
        var currentText = ""
        var index = text.startIndex
        
        // Normalize line endings
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        // Decode common HTML entities
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        
        let acceptedTags = ["br", "a", "b", "i", "u", "s", "strong", "span", "em", "strike"]
        
        while index < text.endIndex {
            let remaining = text[index...]
            
            // Check for HTML tag
            if remaining.hasPrefix("<"), let closeIndex = remaining.firstIndex(of: ">") {
                // Flush current text
                if !currentText.isEmpty {
                    appendText(currentText, with: tagStack, to: &result)
                    currentText = ""
                }
                
                let tagContent = String(remaining[remaining.index(after: remaining.startIndex)..<closeIndex])
                let isClosing = tagContent.hasPrefix("/")
                let cleanTag = isClosing ? String(tagContent.dropFirst()) : tagContent
                
                let components = cleanTag.split(separator: " ", maxSplits: 1)
                    .map { String($0).lowercased() }
                let tagName = components[0]
                
                if acceptedTags.contains(tagName) {
                    if isClosing {
                        // Remove matching tag from stack
                        if let lastIdx = tagStack.lastIndex(where: { $0.name == tagName }) {
                            tagStack.remove(at: lastIdx)
                        }
                        // Handle closing br tag
                        if tagName == "br" {
                            currentText += "\n"
                        }
                    } else {
                        // Parse attributes
                        var attributes: [String: String] = [:]
                        if components.count > 1 {
                            attributes = parseAttributes(String(remaining[remaining.index(after: remaining.startIndex)..<closeIndex]))
                        }
                        
                        let tag = Tag(name: tagName, tagAttributes: attributes)
                        
                        // Handle self-closing tags like <br />, <br/>
                        let isSelfClosing = tagContent.hasSuffix("/")
                        
                        if tagName == "br" || isSelfClosing {
                            currentText += "\n"
                        } else {
                            tagStack.append(tag)
                        }
                    }
                    
                    index = text.index(after: closeIndex)
                    continue
                }
            }
            
            // Check for auto-linking URLs
            if remaining.hasPrefix("http://") || remaining.hasPrefix("https://") {
                // Flush current text
                if !currentText.isEmpty {
                    appendText(currentText, with: tagStack, to: &result)
                    currentText = ""
                }
                
                // Extract URL
                var urlEndIndex = index
                var validChars = 0
                while urlEndIndex < text.endIndex, validChars < 500 {
                    let char = text[urlEndIndex]
                    if isValidURLChar(char) {
                        validChars += 1
                        urlEndIndex = text.index(after: urlEndIndex)
                    } else {
                        break
                    }
                }
                
                let urlString = String(text[index..<urlEndIndex])
                if let url = URL(string: urlString) {
                    var urlAttributes = AttributeContainer()
                    urlAttributes.foregroundColor = .blue
                    urlAttributes.link = url
                    urlAttributes.underlineStyle = .single
                    
                    var linkString = AttributedString(urlString)
                    linkString.mergeAttributes(urlAttributes)
                    result += linkString
                    
                    index = urlEndIndex
                    continue
                }
            }
            
            // Regular character
            currentText.append(text[index])
            index = text.index(after: index)
        }
        
        // Flush remaining text
        if !currentText.isEmpty {
            appendText(currentText, with: tagStack, to: &result)
        }
        
        return result
    }
    
    private static func parseAttributes(_ tagContent: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let pattern = #"(\w+)="([^"]*)""#
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return attributes
        }
        
        let range = NSRange(tagContent.startIndex..., in: tagContent)
        let matches = regex.matches(in: tagContent, options: [], range: range)
        
        for match in matches {
            guard match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: tagContent),
                  let valueRange = Range(match.range(at: 2), in: tagContent) else {
                continue
            }
            
            let key = String(tagContent[keyRange])
            let value = String(tagContent[valueRange])
            attributes[key] = value
        }
        
        return attributes
    }
    
    private static func appendText(_ text: String, with tagStack: [Tag], to result: inout AttributedString) {
        var attributes = AttributeContainer()
        
        // Apply all tags in stack
        for tag in tagStack {
            attributes = tag.apply(to: attributes)
        }
        
        var attributed = AttributedString(text)
        attributed.mergeAttributes(attributes)
        result += attributed
    }
    
    private static func isValidURLChar(_ char: Character) -> Bool {
        let validChars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789%:/.@-_?&=#*!+;$"
        return validChars.contains(char)
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 16) {
        RichTextContent(text: "Simple text without any HTML")
        
        RichTextContent(text: "Text with <b>bold</b> and <i>italic</i>")
        
        RichTextContent(text: "Link: <a href=\"https://example.com\">Click here</a>")
        
        RichTextContent(text: "Auto-linked URL: https://example.com/page")
        
        RichTextContent(text: "Line one<br />Line two<br />Line three")
    }
    .padding()
}
#endif
