import Foundation

/// 结账 UI 的外观配置。
///
/// 该类型是公共 API 的一部分。首个版本仅定义并存储这些字段，**不消费**它们
/// （无任何行为）；全部字段均可选。
public struct Appearance: Sendable, Equatable {
    /// 配色模式。
    public enum ColorScheme: String, Sendable {
        /// 浅色。
        case light
        /// 深色。
        case dark
        /// 跟随系统。
        case auto
    }

    /// 主色。
    public let colorPrimary: String?
    /// 背景色。
    public let colorBackground: String?
    /// 文本色。
    public let colorText: String?
    /// 边框色。
    public let colorBorder: String?
    /// 危险 / 错误色。
    public let colorDanger: String?
    /// 圆角半径。
    public let borderRadius: String?
    /// 字体族。
    public let fontFamily: String?
    /// 配色模式。
    public let colorScheme: ColorScheme?

    /// 创建一个外观配置；全部参数默认为 nil。
    ///
    /// - Parameters:
    ///   - colorPrimary: 主色。
    ///   - colorBackground: 背景色。
    ///   - colorText: 文本色。
    ///   - colorBorder: 边框色。
    ///   - colorDanger: 危险 / 错误色。
    ///   - borderRadius: 圆角半径。
    ///   - fontFamily: 字体族。
    ///   - colorScheme: 配色模式。
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
