import AuthenticationServices
import Foundation

@MainActor
final class AniListOAuthSession: NSObject {
    static let callbackScheme = "comicdeck"
    static let redirectURI = "comicdeck://anilist-auth"

    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<String, Error>?

    func authorize(clientID: String) async throws -> String {
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty else {
            throw TrackerError.invalidConfiguration("AniList OAuth client ID cannot be empty.")
        }
        guard var components = URLComponents(string: "https://anilist.co/api/v2/oauth/authorize") else {
            throw TrackerError.invalidConfiguration("AniList authorization URL is invalid.")
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: trimmedClientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code")
        ]
        guard let url = components.url else {
            throw TrackerError.invalidConfiguration("AniList authorization URL is invalid.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Self.callbackScheme
            ) { [weak self] callbackURL, error in
                guard let self else { return }
                defer {
                    self.session = nil
                    self.continuation = nil
                }
                if let authError = error as? ASWebAuthenticationSessionError,
                   authError.code == .canceledLogin {
                    continuation.resume(throwing: TrackerError.oauthCancelled)
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard
                    let callbackURL,
                    let code = Self.extractAuthorizationCode(from: callbackURL)
                else {
                    continuation.resume(throwing: TrackerError.oauthInvalidCallback)
                    return
                }
                continuation.resume(returning: code)
            }
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                self.session = nil
                self.continuation = nil
                continuation.resume(throwing: TrackerError.remoteFailure("AniList OAuth session could not be started."))
            }
        }
    }

    private static func extractAuthorizationCode(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "code" })?.value
    }
}

extension AniListOAuthSession: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
