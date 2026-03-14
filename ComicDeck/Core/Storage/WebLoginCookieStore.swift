import Foundation

public enum WebLoginCookieStore {
    private static let userDefaultsKey = "source.runtime.cookies"
    private static let cookieFormKey = "source.runtime.cookieFormValues"

    public static func exportCookies(for host: String? = nil) -> [HTTPCookie] {
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        guard let host, !host.isEmpty else {
            return cookies
        }
        return cookies.filter { cookie in
            cookie.domain.contains(host)
        }
    }

    public static func persistCookies() {
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        let payload = cookies.compactMap { $0.properties }
        UserDefaults.standard.set(payload, forKey: userDefaultsKey)
    }

    public static func restoreCookies() {
        guard let payload = UserDefaults.standard.array(forKey: userDefaultsKey) as? [[HTTPCookiePropertyKey: Any]] else {
            return
        }

        for item in payload {
            if let cookie = HTTPCookie(properties: item) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }

    public static func extractCookieValues(fields: [String], hostHints: [String]) -> [String] {
        guard !fields.isEmpty else { return [] }
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        let hints = hostHints.map { $0.lowercased() }.filter { !$0.isEmpty }

        return fields.map { field in
            if hints.isEmpty {
                return cookies.first(where: { $0.name == field })?.value ?? ""
            }
            return cookies.first(where: { cookie in
                guard cookie.name == field else { return false }
                let domain = cookie.domain.lowercased()
                return hints.contains(where: { hint in domain.contains(hint) || hint.contains(domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) })
            })?.value ?? ""
        }
    }

    public static func saveCookieFormValues(sourceKey: String, fields: [String], values: [String]) {
        guard fields.count == values.count else { return }
        var all = UserDefaults.standard.dictionary(forKey: cookieFormKey) as? [String: [String: String]] ?? [:]
        var map: [String: String] = [:]
        for (idx, field) in fields.enumerated() {
            map[field] = values[idx]
        }
        all[sourceKey] = map
        UserDefaults.standard.set(all, forKey: cookieFormKey)
    }

    public static func loadCookieFormValues(sourceKey: String, fields: [String]) -> [String]? {
        guard let all = UserDefaults.standard.dictionary(forKey: cookieFormKey) as? [String: [String: String]],
              let map = all[sourceKey] else {
            return nil
        }
        let values = fields.map { map[$0] ?? "" }
        return values.contains(where: { !$0.isEmpty }) ? values : nil
    }
}
