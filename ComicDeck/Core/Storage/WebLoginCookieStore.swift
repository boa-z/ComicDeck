import Foundation

enum WebLoginCookieStore {
    private static let userDefaultsKey = "source.runtime.cookies"
    private static let cookieFormKey = "source.runtime.cookieFormValues"
    private static let authProfilesKey = "source.runtime.authProfiles"
    private static let activeAuthProfileKey = "source.runtime.activeAuthProfiles"

    struct AuthProfile: Codable, Hashable, Identifiable {
        let id: String
        var label: String
        var cookieFormValues: [String: String]
        var cookies: [[String: String]]
        var cookieDomains: [String]
        var accountData: [String: BackupJSONValue]
        var updatedAt: Date

        init(
            id: String = UUID().uuidString,
            label: String,
            cookieFormValues: [String: String],
            cookies: [[String: String]],
            cookieDomains: [String] = [],
            accountData: [String: BackupJSONValue] = [:],
            updatedAt: Date = Date.now
        ) {
            self.id = id
            self.label = label
            self.cookieFormValues = cookieFormValues
            self.cookies = cookies
            self.cookieDomains = cookieDomains
            self.accountData = accountData
            self.updatedAt = updatedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            label = try container.decode(String.self, forKey: .label)
            cookieFormValues = try container.decode([String: String].self, forKey: .cookieFormValues)
            cookies = try container.decode([[String: String]].self, forKey: .cookies)
            cookieDomains = try container.decodeIfPresent([String].self, forKey: .cookieDomains)
                ?? Self.domains(from: cookies)
            accountData = try container.decodeIfPresent([String: BackupJSONValue].self, forKey: .accountData) ?? [:]
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        }

        private static func domains(from cookies: [[String: String]]) -> [String] {
            Array(Set(cookies.compactMap { $0["domain"]?.lowercased() })).sorted()
        }
    }

    static func exportCookies(for host: String? = nil) -> [HTTPCookie] {
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        guard let host, !host.isEmpty else {
            return cookies
        }
        return cookies.filter { cookie in
            cookie.domain.contains(host)
        }
    }

    static func hasCookies(hostHints: [String] = []) -> Bool {
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        guard !hostHints.isEmpty else { return !cookies.isEmpty }
        return cookies.contains { cookie in
            hostHints.contains { hostMatches(cookieDomain: cookie.domain, host: $0) }
        }
    }

    static func persistCookies() {
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        let payload = cookies.compactMap { $0.properties }
        UserDefaults.standard.set(payload, forKey: userDefaultsKey)
    }

    static func restoreCookies() {
        guard let payload = UserDefaults.standard.array(forKey: userDefaultsKey) as? [[HTTPCookiePropertyKey: Any]] else {
            return
        }

        for item in payload {
            if let cookie = HTTPCookie(properties: item) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }

    static func extractCookieValues(fields: [String], hostHints: [String]) -> [String] {
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

    static func saveCookieFormValues(sourceKey: String, fields: [String], values: [String]) {
        guard fields.count == values.count else { return }
        var all = UserDefaults.standard.dictionary(forKey: cookieFormKey) as? [String: [String: String]] ?? [:]
        var map: [String: String] = [:]
        for (idx, field) in fields.enumerated() {
            map[field] = values[idx]
        }
        all[sourceKey] = map
        UserDefaults.standard.set(all, forKey: cookieFormKey)
    }

    static func loadCookieFormValues(sourceKey: String, fields: [String]) -> [String]? {
        guard let all = UserDefaults.standard.dictionary(forKey: cookieFormKey) as? [String: [String: String]],
              let map = all[sourceKey] else {
            return nil
        }
        let values = fields.map { map[$0] ?? "" }
        return values.contains(where: { !$0.isEmpty }) ? values : nil
    }

    static func authProfiles(sourceKey: String) -> [AuthProfile] {
        allAuthProfiles()[sourceKey]?.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        } ?? []
    }

    static func activeAuthProfileID(sourceKey: String) -> String? {
        let all = UserDefaults.standard.dictionary(forKey: activeAuthProfileKey) as? [String: String] ?? [:]
        return all[sourceKey]
    }

    static func setActiveAuthProfileID(_ id: String?, sourceKey: String) {
        var all = UserDefaults.standard.dictionary(forKey: activeAuthProfileKey) as? [String: String] ?? [:]
        if let id, !id.isEmpty {
            all[sourceKey] = id
        } else {
            all.removeValue(forKey: sourceKey)
        }
        UserDefaults.standard.set(all, forKey: activeAuthProfileKey)
    }

    static func saveCurrentAuthProfile(
        sourceKey: String,
        label: String,
        fields: [String],
        values: [String],
        hostHints: [String] = [],
        accountData: [String: BackupJSONValue] = [:],
        replacing profileID: String? = nil
    ) -> AuthProfile {
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookieMap = cookieFormMap(fields: fields, values: values)
        let cookies = (HTTPCookieStorage.shared.cookies ?? [])
            .filter { cookie in
                hostHints.isEmpty || hostHints.contains { hostMatches(cookieDomain: cookie.domain, host: $0) }
            }
            .compactMap(cookieSnapshot)
        let cookieDomains = Array(Set(
            (cookies.compactMap { $0["domain"] } + hostHints).map { normalizedCookieDomain($0) }
        ))
        .filter { !$0.isEmpty }
        .sorted()
        let profile = AuthProfile(
            id: profileID?.isEmpty == false ? profileID! : UUID().uuidString,
            label: normalizedLabel.isEmpty ? defaultProfileLabel(cookieFormValues: cookieMap) : normalizedLabel,
            cookieFormValues: cookieMap,
            cookies: cookies,
            cookieDomains: cookieDomains,
            accountData: accountData,
            updatedAt: Date.now
        )

        var all = allAuthProfiles()
        var profiles = all[sourceKey] ?? []
        profiles.removeAll { $0.id == profile.id }
        profiles.append(profile)
        all[sourceKey] = profiles
        saveAllAuthProfiles(all)
        setActiveAuthProfileID(profile.id, sourceKey: sourceKey)
        if !fields.isEmpty, !values.isEmpty {
            saveCookieFormValues(sourceKey: sourceKey, fields: fields, values: values)
        }
        return profile
    }

    static func applyAuthProfile(_ profile: AuthProfile, sourceKey: String, fields: [String], hostHints: [String] = []) -> [String] {
        clearCookies(matching: Array(Set(profile.cookieDomains + hostHints)).sorted())
        for item in profile.cookies {
            if let cookie = cookie(fromSnapshot: item) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
        let values = fields.map { profile.cookieFormValues[$0] ?? "" }
        if !values.isEmpty {
            saveCookieFormValues(sourceKey: sourceKey, fields: fields, values: values)
        }
        setActiveAuthProfileID(profile.id, sourceKey: sourceKey)
        persistCookies()
        return values
    }

    static func deleteAuthProfile(id: String, sourceKey: String) {
        var all = allAuthProfiles()
        var profiles = all[sourceKey] ?? []
        profiles.removeAll { $0.id == id }
        all[sourceKey] = profiles
        saveAllAuthProfiles(all)
        if activeAuthProfileID(sourceKey: sourceKey) == id {
            setActiveAuthProfileID(profiles.sorted { $0.updatedAt > $1.updatedAt }.first?.id, sourceKey: sourceKey)
        }
    }

    static func clearActiveAuthProfile(sourceKey: String) {
        setActiveAuthProfileID(nil, sourceKey: sourceKey)
    }

    private static func allAuthProfiles() -> [String: [AuthProfile]] {
        guard let data = UserDefaults.standard.data(forKey: authProfilesKey),
              let decoded = try? JSONDecoder().decode([String: [AuthProfile]].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    private static func saveAllAuthProfiles(_ profiles: [String: [AuthProfile]]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: authProfilesKey)
    }

    private static func cookieFormMap(fields: [String], values: [String]) -> [String: String] {
        guard fields.count == values.count else { return [:] }
        var map: [String: String] = [:]
        for (idx, field) in fields.enumerated() {
            map[field] = values[idx]
        }
        return map
    }

    private static func defaultProfileLabel(cookieFormValues: [String: String]) -> String {
        let candidate = cookieFormValues.values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return candidate ?? "Account"
    }

    private static func cookieSnapshot(_ cookie: HTTPCookie) -> [String: String]? {
        var snapshot: [String: String] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "secure": cookie.isSecure ? "1" : "0"
        ]
        if let expiresDate = cookie.expiresDate {
            snapshot["expires"] = String(expiresDate.timeIntervalSince1970)
        }
        return snapshot
    }

    private static func clearCookies(matching domains: [String]) {
        let domains = Set(domains.map(normalizedCookieDomain).filter { !$0.isEmpty })
        guard !domains.isEmpty else { return }
        let storage = HTTPCookieStorage.shared
        for cookie in storage.cookies ?? [] {
            let domain = normalizedCookieDomain(cookie.domain)
            if domains.contains(where: { hostMatches(cookieDomain: domain, host: $0) || hostMatches(cookieDomain: $0, host: domain) }) {
                storage.deleteCookie(cookie)
            }
        }
    }

    private static func cookie(fromSnapshot snapshot: [String: String]) -> HTTPCookie? {
        guard let name = snapshot["name"],
              let value = snapshot["value"],
              let domain = snapshot["domain"]
        else {
            return nil
        }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: snapshot["path"] ?? "/"
        ]
        if snapshot["secure"] == "1" {
            properties[.secure] = "TRUE"
        }
        if let expires = snapshot["expires"].flatMap(TimeInterval.init) {
            properties[.expires] = Date(timeIntervalSince1970: expires)
        }
        return HTTPCookie(properties: properties)
    }

    private static func normalizedCookieDomain(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)).lowercased()
    }

    private static func hostMatches(cookieDomain: String, host: String) -> Bool {
        let domain = normalizedCookieDomain(cookieDomain)
        let host = normalizedCookieDomain(host)
        guard !domain.isEmpty, !host.isEmpty else { return false }
        return domain == host || domain.hasSuffix(".\(host)") || host.hasSuffix(".\(domain)")
    }
}
