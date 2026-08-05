import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "自动"
        case .light: return "日间"
        case .dark: return "夜间"
        }
    }

    var description: String {
        switch self {
        case .system: return "跟随 iPhone 的外观设置"
        case .light: return "始终使用浅色外观"
        case .dark: return "始终使用深色外观"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
