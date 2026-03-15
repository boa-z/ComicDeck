import Foundation

enum TrackerError: LocalizedError {
    case notPrepared
    case missingAccessToken(TrackerProvider)
    case invalidConfiguration(String)
    case providerUnavailable(TrackerProvider)
    case remoteFailure(String)
    case oauthCancelled
    case oauthInvalidCallback

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "Tracker service is not ready."
        case let .missingAccessToken(provider):
            return "No access token stored for \(provider.title)."
        case let .invalidConfiguration(message):
            return message
        case let .providerUnavailable(provider):
            return "\(provider.title) is not available yet."
        case let .remoteFailure(message):
            return message
        case .oauthCancelled:
            return "OAuth sign-in was cancelled."
        case .oauthInvalidCallback:
            return "OAuth callback did not include a valid access token."
        }
    }
}
