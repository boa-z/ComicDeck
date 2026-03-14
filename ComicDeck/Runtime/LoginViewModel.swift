import Foundation
import Observation

private enum LoginVMLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

@inline(__always)
private func loginDebugLog(_ message: String, level: LoginVMLogLevel = .debug) {
    guard RuntimeDebugConsole.isEnabled else { return }
    let line = "[SourceRuntime][\(level.rawValue)][LoginVM] \(message)"
    NSLog("%@", line)
    RuntimeDebugConsole.shared.append(line)
}

/// Manages source login state (web login, account login, cookie login).
/// Intended to be used as an @EnvironmentObject in SwiftUI.
@MainActor
@Observable
final class LoginViewModel {
    var showLogin = false
    var activeLoginSourceKey = ""
    var loginURL = ""
    var loginAccount = ""
    var loginPassword = ""
    var supportsWebLogin = false
    var supportsAccountLogin = false
    var supportsCookieLogin = false
    var currentSourceIsLogged: Bool? = nil
    var currentSourceLoginStateLabel: String = "Unknown"
    var registerURL = ""
    var cookieLoginFields: [String] = []
    var cookieLoginValues: [String] = []
    var searchOptionGroups: [SearchOptionGroup] = []
    var searchOptionValues: [String] = []
    var searchFeatureProfile: SearchFeatureProfile = .empty
    var status = "Ready"

    // Injected dependencies
    var sourceStore: SourceStore?
    var sourceManagerViewModel: SourceManagerViewModel?

    // The engine execution queue is owned by ReaderViewModel and injected here.
    var engineExecutionQueue: DispatchQueue?

    // MARK: - Login Profile Refresh

    func refreshLoginURLForSelectedSource() async {
        guard let source = sourceManagerViewModel?.selectedSource else { return }
        await prepareLoginState(for: source)
    }

    func prepareLoginState(for source: InstalledSource) async {
        guard let sourceStore else { return }
        do {
            let script = try await sourceStore.readScript(fileName: source.scriptFileName)
            guard let engine = try sourceManagerViewModel?.getOrCreateEngine(sourceKey: source.key, script: script) else { return }
            let profile = try engine.getLoginProfile()
            let webLoginURL = profile.webLoginURL ?? SourceScriptParser.extractLoginWebviewURL(from: script)
            let normalizedWebLoginURL = normalizedHTTPURLString(webLoginURL)

            supportsAccountLogin = profile.hasAccountLogin
            supportsWebLogin = profile.hasWebLogin && normalizedWebLoginURL != nil
            supportsCookieLogin = profile.hasCookieLogin
            registerURL = profile.registerWebsite ?? ""
            cookieLoginFields = profile.cookieFields
            cookieLoginValues = Array(repeating: "", count: profile.cookieFields.count)
            hydrateCookieFieldsFromStore(sourceKey: source.key)

            loginURL = normalizedWebLoginURL ?? ""

            let groups = try engine.getSearchOptionGroups()
            searchOptionGroups = groups
            searchOptionValues = groups.map { group in
                if let def = group.defaultValue, !def.isEmpty { return def }
                return group.options.first?.value ?? ""
            }
            searchFeatureProfile = try engine.getSearchFeatureProfile()

            let state = try await computeLoggedStateDetail(engine: engine, sourceKey: source.key)
            currentSourceIsLogged = state.isLogged
            currentSourceLoginStateLabel = state.label
            activeLoginSourceKey = source.key
            loginDebugLog(
                "refreshLoginURL: key=\(source.key), web=\(supportsWebLogin), acct=\(supportsAccountLogin), cookie=\(supportsCookieLogin)",
                level: .info
            )
        } catch {
            loginDebugLog("refreshLoginURLForSelectedSource failed: \(error.localizedDescription)", level: .error)
            resetLoginState()
        }
    }

    func refreshCurrentSourceLoginState() async {
        guard let source = sourceManagerViewModel?.selectedSource else {
            currentSourceIsLogged = nil
            currentSourceLoginStateLabel = "Unknown"
            return
        }
        await refreshCurrentSourceLoginState(for: source)
    }

    func refreshCurrentSourceLoginState(for source: InstalledSource) async {
        guard let sourceStore else {
            currentSourceIsLogged = nil
            currentSourceLoginStateLabel = "Unknown"
            return
        }
        do {
            let script = try await sourceStore.readScript(fileName: source.scriptFileName)
            let engine = try sourceManagerViewModel?.getOrCreateEngine(sourceKey: source.key, script: script)
            guard let engine else { return }
            let state = try await computeLoggedStateDetail(engine: engine, sourceKey: source.key)
            currentSourceIsLogged = state.isLogged
            currentSourceLoginStateLabel = state.label
            activeLoginSourceKey = source.key
            loginDebugLog("refreshCurrentSourceLoginState: key=\(source.key), logged=\(String(describing: currentSourceIsLogged))")
        } catch {
            currentSourceIsLogged = nil
            currentSourceLoginStateLabel = "Unknown"
            loginDebugLog("refreshCurrentSourceLoginState failed: \(error.localizedDescription)", level: .warn)
        }
    }

    // MARK: - Login Actions

    func loginWithAccount() async {
        guard let source = sourceManagerViewModel?.selectedSource else {
            status = "Source not initialized"
            return
        }
        await loginWithAccount(for: source)
    }

    func loginWithAccount(for source: InstalledSource) async {
        guard let sourceStore else {
            status = "Source not initialized"
            return
        }
        guard supportsAccountLogin else {
            status = "Account login is not supported by this source"
            return
        }
        guard !loginAccount.isEmpty, !loginPassword.isEmpty else {
            status = "Please input account and password"
            return
        }
        do {
            let script = try await sourceStore.readScript(fileName: source.scriptFileName)
            let engine = try sourceManagerViewModel?.getOrCreateEngine(sourceKey: source.key, script: script)
            guard let engine else { return }
            let account = loginAccount
            let password = loginPassword
            let result = try await self.runEngine {
                try engine.loginSource(account: account, password: password)
            }
            await refreshCurrentSourceLoginState(for: source)
            loginDebugLog("account login ok: key=\(source.key), result=\(result)", level: .info)
            status = "Login success: \(result)"
        } catch {
            loginDebugLog("loginWithAccount failed: \(error.localizedDescription)", level: .error)
            status = "Login failed: \(error.localizedDescription)"
        }
    }

    func loginWithCookies() async {
        guard let source = sourceManagerViewModel?.selectedSource else {
            status = "Source not initialized"
            return
        }
        await loginWithCookies(for: source)
    }

    func loginWithCookies(for source: InstalledSource) async {
        guard let sourceStore else {
            status = "Source not initialized"
            return
        }
        guard supportsCookieLogin else {
            status = "Cookie login is not supported by this source"
            return
        }
        guard cookieLoginFields.count == cookieLoginValues.count else {
            status = "Cookie form state invalid"
            return
        }
        if cookieLoginValues.contains(where: { $0.isEmpty }) {
            status = "Please fill all cookie fields"
            return
        }
        do {
            let script = try await sourceStore.readScript(fileName: source.scriptFileName)
            let engine = try sourceManagerViewModel?.getOrCreateEngine(sourceKey: source.key, script: script)
            guard let engine else { return }
            let values = cookieLoginValues
            let isValid = try await self.runEngine {
                try engine.validateCookieLogin(values: values)
            }
            loginDebugLog("cookie login: key=\(source.key), valid=\(isValid)", level: isValid ? .info : .warn)
            if isValid {
                WebLoginCookieStore.saveCookieFormValues(
                    sourceKey: source.key,
                    fields: cookieLoginFields,
                    values: cookieLoginValues
                )
            }
            await refreshCurrentSourceLoginState(for: source)
            status = isValid ? "Cookie login success" : "Cookie login failed"
        } catch {
            loginDebugLog("loginWithCookies failed: \(error.localizedDescription)", level: .error)
            status = "Cookie login failed: \(error.localizedDescription)"
        }
    }

    func openWebLogin() async {
        guard let source = sourceManagerViewModel?.selectedSource else {
            status = "Source not initialized"
            return
        }
        await openWebLogin(for: source)
    }

    func openWebLogin(for source: InstalledSource) async {
        activeLoginSourceKey = source.key
        let targetURL = validatedLoginURL()
        loginDebugLog("openWebLogin tapped: supportsWebLogin=\(supportsWebLogin), loginURL=\(loginURL), validated=\(targetURL.absoluteString)", level: .info)
        guard targetURL.absoluteString != "about:blank" else {
            await prepareLoginState(for: source)
            let refreshedURL = validatedLoginURL()
            loginDebugLog("openWebLogin after refresh: loginURL=\(loginURL), validated=\(refreshedURL.absoluteString)", level: .info)
            guard refreshedURL.absoluteString != "about:blank" else {
                status = "Web login URL is invalid or empty"
                loginDebugLog("openWebLogin abort: URL still invalid after refresh", level: .warn)
                return
            }
            if loginURL != refreshedURL.absoluteString {
                loginURL = refreshedURL.absoluteString
            }
            loginDebugLog("openWebLogin fallback after refresh: url=\(refreshedURL.absoluteString)", level: .warn)
            showLogin = true
            loginDebugLog("openWebLogin set showLogin=true (fallback path)", level: .info)
            return
        }
        if !supportsWebLogin {
            loginDebugLog("openWebLogin: source does not declare web login, but URL is valid; opening anyway", level: .warn)
        }
        if showLogin {
            loginDebugLog("openWebLogin detected showLogin already true; forcing sheet re-present", level: .warn)
            showLogin = false
            await Task.yield()
        }
        loginDebugLog("openWebLogin: url=\(targetURL.absoluteString)", level: .info)
        showLogin = true
        loginDebugLog("openWebLogin set showLogin=true", level: .info)
    }

    func onLoginCookieCaptured() {
        WebLoginCookieStore.persistCookies()
        loginDebugLog("onLoginCookieCaptured", level: .info)
        status = "Cookies persisted, waiting web login check..."
    }

    func onWebLoginPageChanged(url: String, title: String) {
        let sourceKey = activeLoginSourceKey.isEmpty
            ? (sourceManagerViewModel?.selectedSourceKey ?? "")
            : activeLoginSourceKey
        guard let source = sourceManagerViewModel?.installedSource(for: sourceKey),
              let engine = sourceManagerViewModel?.sourceEngines[source.key]
        else { return }
        Task {
            do {
                let ok = try await self.runEngine {
                    try engine.checkWebLoginStatus(url: url, title: title)
                }
                loginDebugLog("onWebLoginPageChanged: key=\(source.key), url=\(url), matched=\(ok)")
                guard ok else { return }
                try await self.runEngine {
                    try engine.onWebLoginSuccess()
                }
                WebLoginCookieStore.persistCookies()
                hydrateCookieFieldsFromStore(sourceKey: source.key)
                await refreshCurrentSourceLoginState(for: source)
                showLogin = false
                loginDebugLog("onWebLoginPageChanged set showLogin=false after success", level: .info)
                status = "Web login success"
            } catch {
                loginDebugLog("onWebLoginPageChanged failed: \(error.localizedDescription)", level: .error)
                status = "Web login check failed: \(error.localizedDescription)"
            }
        }
    }

    func validatedLoginURL() -> URL {
        if let normalized = normalizedHTTPURLString(loginURL),
           let url = URL(string: normalized),
           url.scheme?.hasPrefix("http") == true {
            return url
        }
        return URL(string: "about:blank")!
    }

    // MARK: - Search Options

    func updateSearchOption(at index: Int, value: String) {
        guard searchOptionValues.indices.contains(index) else { return }
        searchOptionValues[index] = value
    }

    func updateCookieField(at index: Int, value: String) {
        guard cookieLoginValues.indices.contains(index) else { return }
        cookieLoginValues[index] = value
    }

    // MARK: - Private Helpers

    private func computeLoggedStateDetail(
        engine: ComicSourceScriptEngine,
        sourceKey: String
    ) async throws -> (isLogged: Bool?, label: String) {
        let raw = try await self.runEngine {
            try engine.getIsLogged()
        }
        if raw == true { return (true, "Logged In (Session)") }

        guard supportsCookieLogin, !cookieLoginFields.isEmpty else {
            if raw == false { return (false, "Logged Out") }
            return (nil, "Unknown")
        }
        hydrateCookieFieldsFromStore(sourceKey: sourceKey)
        let values = cookieLoginValues
        guard values.count == cookieLoginFields.count else {
            return (raw, raw == nil ? "Unknown" : "Logged Out")
        }
        guard values.contains(where: { !$0.isEmpty }) else {
            return (raw, raw == nil ? "Unknown" : "Logged Out")
        }

        do {
            let valid = try await self.runEngine {
                try engine.validateCookieLogin(values: values)
            }
            if valid { return (true, "Logged In (Cookie)") }
        } catch {
            loginDebugLog("computeLoggedState cookie validate failed: \(error.localizedDescription)", level: .debug)
        }
        if raw == false { return (false, "Logged Out") }
        return (raw, raw == nil ? "Unknown" : "Logged Out")
    }

    private func hydrateCookieFieldsFromStore(sourceKey: String) {
        guard !cookieLoginFields.isEmpty else { return }
        if let saved = WebLoginCookieStore.loadCookieFormValues(sourceKey: sourceKey, fields: cookieLoginFields),
           saved.count == cookieLoginFields.count {
            cookieLoginValues = saved
            return
        }
        let hints = cookieHostHints()
        let extracted = WebLoginCookieStore.extractCookieValues(fields: cookieLoginFields, hostHints: hints)
        if extracted.count == cookieLoginFields.count, extracted.contains(where: { !$0.isEmpty }) {
            cookieLoginValues = extracted
            WebLoginCookieStore.saveCookieFormValues(sourceKey: sourceKey, fields: cookieLoginFields, values: extracted)
        }
    }

    private func cookieHostHints() -> [String] {
        var hints: [String] = []
        let urls = [loginURL, registerURL]
        for value in urls {
            guard let host = URL(string: value)?.host else { continue }
            hints.append(host)
        }
        if let key = sourceManagerViewModel?.selectedSourceKey, key.lowercased().contains("ehentai") {
            hints.append(contentsOf: ["e-hentai.org", "forums.e-hentai.org", "exhentai.org"])
        }
        return Array(Set(hints))
    }

    private func resetLoginState() {
        supportsWebLogin = false
        supportsAccountLogin = false
        supportsCookieLogin = false
        currentSourceIsLogged = nil
        currentSourceLoginStateLabel = "Unknown"
        registerURL = ""
        cookieLoginFields = []
        cookieLoginValues = []
        loginURL = ""
        searchOptionGroups = []
        searchOptionValues = []
        searchFeatureProfile = .empty
    }

    private func normalizedHTTPURLString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true {
            return trimmed
        }

        if trimmed.hasPrefix("//"),
           let url = URL(string: "https:\(trimmed)"),
           url.scheme?.hasPrefix("http") == true {
            return url.absoluteString
        }

        if !trimmed.contains("://"),
           let url = URL(string: "https://\(trimmed)"),
           url.scheme?.hasPrefix("http") == true {
            return url.absoluteString
        }

        return nil
    }

    // MARK: - Engine Execution

    private func runEngine<T>(_ work: @escaping () throws -> T) async throws -> T {
        guard let queue = engineExecutionQueue else {
            throw ScriptEngineError.buildContextFailed
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
