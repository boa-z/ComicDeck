import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum ComicBrowseDisplayMode: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return "List"
        case .grid: return "Grid"
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }
}

struct AppSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let screen: CGFloat = 16
    static let section: CGFloat = 20
}

struct AppRadius {
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let lg: CGFloat = 20
}

enum AppSurface {
    static let background = Color(uiColor: .secondarySystemBackground)
    static let grouped = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .systemBackground)
    static let elevated = Color(uiColor: .tertiarySystemBackground)
    static let subtle = Color(uiColor: .secondarySystemFill)
    static let readerOverlay = Color.black.opacity(0.42)
    static let border = Color.primary.opacity(0.08)
}

enum AppTint {
    static let accent = Color.accentColor
    static let success = Color.green
    static let warning = Color.orange
    static let danger = Color.red
}

struct AppCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(AppSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(AppSurface.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.04))
            )
            .shadow(color: Color.black.opacity(0.04), radius: 10, y: 4)
    }
}

extension View {
    func appCardStyle() -> some View {
        modifier(AppCardStyle())
    }
}
