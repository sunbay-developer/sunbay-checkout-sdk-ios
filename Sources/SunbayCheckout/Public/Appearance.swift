import Foundation

/// Appearance configuration for the checkout UI.
///
/// This type is part of the public API. The first version only defines and stores these
/// fields; it does **not** consume them (no behavior). All fields are optional.
public struct Appearance: Sendable, Equatable {
    /// Color scheme.
    public enum ColorScheme: String, Sendable {
        /// Light.
        case light
        /// Dark.
        case dark
        /// Follow the system.
        case auto
    }

    /// Primary color.
    public let colorPrimary: String?
    /// Background color.
    public let colorBackground: String?
    /// Text color.
    public let colorText: String?
    /// Border color.
    public let colorBorder: String?
    /// Danger / error color.
    public let colorDanger: String?
    /// Border radius.
    public let borderRadius: String?
    /// Font family.
    public let fontFamily: String?
    /// Color scheme.
    public let colorScheme: ColorScheme?

    /// Creates an appearance configuration; all parameters default to nil.
    ///
    /// - Parameters:
    ///   - colorPrimary: Primary color.
    ///   - colorBackground: Background color.
    ///   - colorText: Text color.
    ///   - colorBorder: Border color.
    ///   - colorDanger: Danger / error color.
    ///   - borderRadius: Border radius.
    ///   - fontFamily: Font family.
    ///   - colorScheme: Color scheme.
    public init(
        colorPrimary: String? = nil,
        colorBackground: String? = nil,
        colorText: String? = nil,
        colorBorder: String? = nil,
        colorDanger: String? = nil,
        borderRadius: String? = nil,
        fontFamily: String? = nil,
        colorScheme: ColorScheme? = nil
    ) {
        self.colorPrimary = colorPrimary
        self.colorBackground = colorBackground
        self.colorText = colorText
        self.colorBorder = colorBorder
        self.colorDanger = colorDanger
        self.borderRadius = borderRadius
        self.fontFamily = fontFamily
        self.colorScheme = colorScheme
    }
}
