import Foundation

// MARK: - SourceScriptParser

/// Pure static utility for parsing metadata and login information out of
/// a raw ComicSource JS script string. No engine instantiation required.
enum SourceScriptParser {

    /// Extracts the class name of the first `class Foo extends ComicSource` declaration.
    static func extractClassName(from script: String) -> String? {
        let pattern = #"class\s+([A-Za-z0-9_]+)\s+extends\s+ComicSource"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(location: 0, length: script.utf16.count)
        guard let match = regex.firstMatch(in: script, range: range),
              let classRange = Range(match.range(at: 1), in: script)
        else {
            return nil
        }
        return String(script[classRange])
    }

    /// Extracts structured metadata (name, key, version, url) from a source script.
    static func extractMetadata(from script: String) -> SourceScriptMetadata? {
        guard let className = extractClassName(from: script) else {
            return nil
        }

        func capture(_ key: String) -> String? {
            let pattern = #"\#(key)\s*=\s*[\"']([^\"']+)[\"']"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return nil
            }
            let range = NSRange(location: 0, length: script.utf16.count)
            guard let match = regex.firstMatch(in: script, range: range),
                  let valueRange = Range(match.range(at: 1), in: script)
            else {
                return nil
            }
            return String(script[valueRange])
        }

        let name = capture("name") ?? className
        let key = capture("key") ?? className.lowercased()
        let version = capture("version") ?? "0.0.0"
        let url = capture("url")

        return SourceScriptMetadata(
            className: className,
            name: name,
            key: key,
            version: version,
            url: url
        )
    }

    /// Extracts the `loginWithWebview/loginWithWebView.url` property from a source script without
    /// running the script engine.
    static func extractLoginWebviewURL(from script: String) -> String? {
        let patterns = [
            #"loginWithWebview\s*:\s*\{[\s\S]*?url\s*:\s*["']([^"']+)["']"#,
            #"account\s*=\s*\{[\s\S]*?loginWithWebview\s*:\s*\{[\s\S]*?url\s*:\s*["']([^"']+)["']"#,
            #"loginWithWebView\s*:\s*\{[\s\S]*?url\s*:\s*["']([^"']+)["']"#,
            #"account\s*=\s*\{[\s\S]*?loginWithWebView\s*:\s*\{[\s\S]*?url\s*:\s*["']([^"']+)["']"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(location: 0, length: script.utf16.count)
            if let match = regex.firstMatch(in: script, range: range),
               let urlRange = Range(match.range(at: 1), in: script) {
                let url = String(script[urlRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !url.isEmpty, url.hasPrefix("http") {
                    return url
                }
            }
        }
        return nil
    }
}
