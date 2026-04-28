import Foundation

enum ReaderMode: String, CaseIterable, Identifiable {
    case ltr
    case rtl
    case vertical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ltr: return AppLocalization.text("reader.mode.ltr", "LTR")
        case .rtl: return AppLocalization.text("reader.mode.rtl", "RTL")
        case .vertical: return AppLocalization.text("reader.mode.vertical", "Vertical")
        }
    }

    var icon: String {
        switch self {
        case .ltr: return "textformat.size"
        case .rtl: return "textformat.size.larger"
        case .vertical: return "rectangle.split.1x2"
        }
    }
}

enum ReaderBackgroundMode: String, CaseIterable, Identifiable {
    case system
    case auto
    case white
    case black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return AppLocalization.text("reader.background.system", "System")
        case .auto: return AppLocalization.text("reader.background.auto", "Auto")
        case .white: return AppLocalization.text("reader.background.white", "White")
        case .black: return AppLocalization.text("reader.background.black", "Black")
        }
    }
}

enum TapZonePreset: String, CaseIterable, Identifiable {
    case auto
    case leftRight = "left-right"
    case lShaped = "l-shaped"
    case kindle
    case edge
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return AppLocalization.text("reader.tap.auto", "Automatic")
        case .leftRight: return AppLocalization.text("reader.tap.left_right", "Left/Right")
        case .lShaped: return AppLocalization.text("reader.tap.l_shaped", "L-shaped")
        case .kindle: return AppLocalization.text("reader.tap.kindle", "Kindle")
        case .edge: return AppLocalization.text("reader.tap.edge", "Edge")
        case .disabled: return AppLocalization.text("reader.tap.disabled", "Disabled")
        }
    }
}
