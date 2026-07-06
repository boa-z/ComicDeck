import Foundation

@MainActor
enum RelativeTimeText {
    private static let shortFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let fullFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    static func short(for timestamp: Int64, relativeTo referenceDate: Date = .now) -> String {
        short(from: Date(timeIntervalSince1970: TimeInterval(timestamp)), relativeTo: referenceDate)
    }

    static func short(from date: Date, relativeTo referenceDate: Date = .now) -> String {
        shortFormatter.localizedString(for: date, relativeTo: referenceDate)
    }

    static func full(from date: Date, relativeTo referenceDate: Date = .now) -> String {
        fullFormatter.localizedString(for: date, relativeTo: referenceDate)
    }
}
