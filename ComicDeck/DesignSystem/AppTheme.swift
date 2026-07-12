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
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 28
    static let screen: CGFloat = 16
    static let section: CGFloat = 24
    static let stack: CGFloat = 10
    static let row: CGFloat = 12
    static let chip: CGFloat = 8
    static let touch: CGFloat = 44
}

struct AppRadius {
    static let xs: CGFloat = 8
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let lg: CGFloat = 18
    static let xl: CGFloat = 24
    static let pill: CGFloat = 999
}

enum AppSurface {
    static let background = PlatformColors.secondarySystemBackground
    static let grouped = PlatformColors.systemGroupedBackground
    static let card = PlatformColors.systemBackground
    static let elevated = PlatformColors.tertiarySystemBackground
    static let subtle = PlatformColors.secondarySystemFill
    static let readerOverlay = Color.black.opacity(0.42)
    static let border = Color.primary.opacity(0.08)
    static let borderStrong = Color.primary.opacity(0.12)
    static let scrim = Color.black.opacity(0.08)
}

enum AppTint {
    static let accent = Color.accentColor
    static let success = Color.green
    static let warning = Color.orange
    static let danger = Color.red
    static let info = Color.blue
}

enum AppMotion {
    static let quick: Animation = .easeOut(duration: 0.18)
    static let standard: Animation = .easeInOut(duration: 0.24)
    static let soft: Animation = .spring(response: 0.32, dampingFraction: 0.86)
}

enum AppTypography {
    static let sectionTitle = Font.title3.weight(.semibold)
    static let cardTitle = Font.headline
    static let body = Font.body
    static let secondary = Font.subheadline
    static let meta = Font.caption
    static let badge = Font.caption.weight(.semibold)
}

enum AppCoverSize {
    static let list = CGSize(width: 68, height: 96)
    static let listCompact = CGSize(width: 56, height: 80)
    static let grid = CGSize(width: 140, height: 196)
    static let spotlight = CGSize(width: 72, height: 102)
    static let shelf = CGSize(width: 128, height: 182)
}

struct AppCardStyle: ViewModifier {
    var padding: CGFloat = AppSpacing.md
    var cornerRadius: CGFloat = AppRadius.md
    var elevated: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(elevated ? AppSurface.elevated : AppSurface.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(elevated ? AppSurface.borderStrong : AppSurface.border.opacity(0.7))
            )
            .shadow(
                color: Color.black.opacity(elevated ? 0.08 : 0.045),
                radius: elevated ? 14 : 10,
                y: elevated ? 6 : 4
            )
    }
}

struct AppScreenBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                LinearGradient(
                    colors: [
                        AppSurface.grouped,
                        AppSurface.background.opacity(0.82)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
    }
}

struct AppSoftPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(AppMotion.quick, value: configuration.isPressed)
    }
}

struct AppIconBadge: View {
    let systemImage: String
    var tint: Color = AppTint.accent
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: systemImage)
            .font(.headline)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct AppSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var trailing: AnyView? = nil

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = nil
    }

    init<Trailing: View>(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTypography.sectionTitle)
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(AppTypography.meta)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let trailing {
                trailing
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct AppMetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    var tint: Color = AppTint.accent

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(title)
                .font(AppTypography.badge)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(subtitle)
                .font(AppTypography.meta)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(tint.opacity(0.12))
        )
        .accessibilityElement(children: .combine)
    }
}

struct AppActionChip: View {
    let title: String
    let systemImage: String
    var prominent: Bool = false
    var expands: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
                .lineLimit(1)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(prominent ? Color.white : .primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 40)
        .frame(maxWidth: expands ? .infinity : nil)
        .background(
            prominent ? AppTint.accent : AppSurface.subtle,
            in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
    }
}

struct AppStatusPill: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = AppTint.accent

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
                .lineLimit(1)
        }
        .font(AppTypography.badge)
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct AppEmptyStateCard: View {
    let title: String
    let message: String
    var systemImage: String = "tray"
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(AppTint.accent)
                .frame(width: 52, height: 52)
                .background(AppTint.accent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(spacing: AppSpacing.xs) {
                Text(title)
                    .font(AppTypography.cardTitle)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(AppTypography.secondary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.lg)
        .appCardStyle(padding: AppSpacing.lg)
        .accessibilityElement(children: .combine)
    }
}

struct AppLoadingStateCard: View {
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            ProgressView()
                .controlSize(.regular)
            Text(title)
                .font(AppTypography.secondary)
                .foregroundStyle(.secondary)
            if let message, !message.isEmpty {
                Text(message)
                    .font(AppTypography.meta)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .appCardStyle(padding: AppSpacing.lg)
        .accessibilityElement(children: .combine)
    }
}

struct AppInlineStatusRow: View {
    let text: String
    var isLoading: Bool = false

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Text(text)
                .font(AppTypography.meta)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(AppSurface.subtle.opacity(0.7), in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func appCardStyle(padding: CGFloat = AppSpacing.md, cornerRadius: CGFloat = AppRadius.md, elevated: Bool = false) -> some View {
        modifier(AppCardStyle(padding: padding, cornerRadius: cornerRadius, elevated: elevated))
    }

    func appScreenBackground() -> some View {
        modifier(AppScreenBackground())
    }

    func appSoftPress() -> some View {
        buttonStyle(AppSoftPressButtonStyle())
    }

    func appMinTouchTarget(_ size: CGFloat = AppSpacing.touch) -> some View {
        frame(minWidth: size, minHeight: size)
        .contentShape(Rectangle())
    }
}
