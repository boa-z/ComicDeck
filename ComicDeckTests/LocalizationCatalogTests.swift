import XCTest

final class LocalizationCatalogTests: XCTestCase {
    func testEveryAppLocalizationKeyHasEnglishAndChineseTranslations() throws {
        let sourceRoot = sourceRootURL
        let catalogURL = sourceRoot
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Localization", isDirectory: true)
            .appendingPathComponent("Localizable.xcstrings")
        let usedKeys = try appLocalizationKeys(in: sourceRoot)
        let catalog = try localizationCatalog(at: catalogURL)

        let missingKeys = usedKeys.subtracting(catalog.keys).sorted()
        XCTAssertTrue(missingKeys.isEmpty, "Missing localization keys: \(missingKeys.joined(separator: ", "))")

        let incompleteKeys = usedKeys.compactMap { key -> String? in
            guard let entry = catalog[key] else { return nil }
            return hasTranslation(entry, locale: "en") && hasTranslation(entry, locale: "zh-Hans") ? nil : key
        }.sorted()
        XCTAssertTrue(
            incompleteKeys.isEmpty,
            "Localization keys missing English or Simplified Chinese values: \(incompleteKeys.joined(separator: ", "))"
        )
    }

    func testAppOwnedUIStringsUseLocalizationCatalog() throws {
        let violations = try directUIStringViolations(in: sourceRootURL)
        XCTAssertTrue(
            violations.isEmpty,
            "App-owned UI strings must use AppLocalization:\n\(violations.joined(separator: "\n"))"
        )
    }

    private var sourceRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ComicDeck", isDirectory: true)
    }

    private func appLocalizationKeys(in sourceRoot: URL) throws -> Set<String> {
        let expression = try NSRegularExpression(
            pattern: #"AppLocalization\.(?:text|format)\(\s*"([^"]+)""#
        )
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Could not enumerate Swift source files")
            return []
        }

        var keys = Set<String>()
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let values = try url.resourceValues(forKeys: Set(resourceKeys))
            guard values.isRegularFile == true else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                keys.insert(String(source[keyRange]))
            }
        }
        return keys
    }

    private func localizationCatalog(at url: URL) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: [String: Any]])
    }

    private func directUIStringViolations(in sourceRoot: URL) throws -> [String] {
        let expression = try NSRegularExpression(
            pattern: #"(?:Text|Button|Label|Section|Menu|Picker|Toggle|TextField|SecureField|navigationTitle|navigationSubtitle|accessibilityLabel|help)\(\s*"([^"\n]+)""#
        )
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Could not enumerate Swift source files")
            return []
        }

        var violations: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let values = try url.resourceValues(forKeys: Set(resourceKeys))
            guard values.isRegularFile == true else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: range) {
                guard let literalRange = Range(match.range(at: 1), in: source) else { continue }
                let literal = String(source[literalRange])
                guard literal.rangeOfCharacter(from: .letters) != nil,
                      !literal.contains(#"\("#)
                else {
                    continue
                }
                let line = source[..<literalRange.lowerBound].reduce(into: 1) { count, character in
                    if character == "\n" { count += 1 }
                }
                let relativePath = url.path.replacingOccurrences(of: sourceRoot.path + "/", with: "")
                violations.append("\(relativePath):\(line): \(literal)")
            }
        }
        return violations.sorted()
    }

    private func hasTranslation(_ entry: [String: Any], locale: String) -> Bool {
        guard let localizations = entry["localizations"] as? [String: Any],
              let localization = localizations[locale] as? [String: Any],
              let stringUnit = localization["stringUnit"] as? [String: Any],
              stringUnit["state"] as? String == "translated",
              let value = stringUnit["value"] as? String
        else {
            return false
        }
        return !value.isEmpty
    }
}
