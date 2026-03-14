import Foundation

enum AppLocalization {
    static func text(_ key: String, _ defaultValue: String, comment: String = "") -> String {
        Bundle.main.localizedString(forKey: key, value: defaultValue, table: nil)
    }

    static func format(_ key: String, _ defaultValue: String, _ arguments: CVarArg..., comment: String = "") -> String {
        let format = Bundle.main.localizedString(forKey: key, value: defaultValue, table: nil)
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}
