import SunbayCheckout
import SwiftUI
import UIKit

/// Merchant brand presets demonstrating SDK `Appearance` customization.
enum ThemePreset: CaseIterable {
    case orange, blue, green

    var primaryHex: String {
        switch self {
        case .orange: return "#ff6000"
        case .blue: return "#2563eb"
        case .green: return "#16a34a"
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .orange: return 10
        case .blue: return 3
        case .green: return 20
        }
    }

    /// Localization key in `Strings`.
    var nameKey: String {
        switch self {
        case .orange: return "settings.colorTheme.orange"
        case .blue: return "settings.colorTheme.blue"
        case .green: return "settings.colorTheme.green"
        }
    }
}

/// Light/dark selection for the merchant app (and the SDK sheet).
enum ModeChoice: CaseIterable {
    case system, light, dark
}

final class ThemeStore: ObservableObject {
    @Published var preset: ThemePreset = .orange
    @Published var mode: ModeChoice = .system

    /// `nil` follows the system.
    var swiftUIScheme: ColorScheme? {
        switch mode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var primary: Color { Color(UIColor(showcaseHex: preset.primaryHex) ?? .systemOrange) }
    var cornerRadius: CGFloat { preset.cornerRadius }

    /// Never returns `.automatic`: `.system` resolves through `systemIsDark`.
    func appearance(systemIsDark: Bool) -> Appearance {
        var appearance = Appearance()
        appearance.colors.primary = UIColor(showcaseHex: preset.primaryHex)
        appearance.cornerRadius = preset.cornerRadius
        switch mode {
        case .system: appearance.colorScheme = systemIsDark ? .dark : .light
        case .light: appearance.colorScheme = .light
        case .dark: appearance.colorScheme = .dark
        }
        return appearance
    }
}

extension UIColor {
    /// Parses `#RRGGBB` (the SDK's own hex initializer is internal).
    convenience init?(showcaseHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: CGFloat((v >> 16) & 0xff) / 255,
            green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255,
            alpha: 1)
    }
}
