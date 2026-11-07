import Foundation

/// Supported UI languages for the Showcase app.
enum ShowcaseLanguage: String, CaseIterable {
    case en
    case zh

    /// Locale code handed to the SDK.
    var localeCode: String {
        switch self {
        case .en: return "en-US"
        case .zh: return "zh-CN"
        }
    }
}

/// Holds the current language and resolves localized strings.
final class LanguageStore: ObservableObject {
    @Published var language: ShowcaseLanguage

    init(language: ShowcaseLanguage = .en) {
        self.language = language
    }

    /// Returns the value for the current language, or the key itself when missing.
    func t(_ key: String) -> String {
        Strings.value(key, language)
    }
}

/// All user-visible strings. This is the only file allowed to contain Chinese text.
enum Strings {
    private static let table: [String: (en: String, zh: String)] = [
        "app.title": ("Sunbay Coffee", "Sunbay 咖啡"),
        "shop.title": ("Shop", "商品"),
        "cart.title": ("Cart", "购物车"),
        "result.title": ("Order Result", "订单结果"),
        "settings.title": ("Settings", "设置"),

        "product.latte": ("Caffe Latte", "拿铁"),
        "product.americano": ("Americano", "美式咖啡"),
        "product.coldbrew": ("Cold Brew", "冷萃咖啡"),
        "product.croissant": ("Butter Croissant", "黄油可颂"),
        "product.beans": ("Coffee Beans 250g", "咖啡豆 250g"),

        "action.add": ("Add", "添加"),
        "action.pay": ("Pay", "支付"),
        "action.continueShopping": ("Continue shopping", "继续购物"),
        "action.done": ("Done", "完成"),

        "cart.total": ("Total", "合计"),
        "cart.empty": ("Your cart is empty", "购物车是空的"),
        "cart.testCardHint": (
            "Demo: use test card 4242 4242 4242 4242, any future date, any CVC",
            "演示：请使用测试卡 4242 4242 4242 4242，任意未来日期，任意 CVC"
        ),

        "settings.appearance": ("Appearance", "外观"),
        "settings.appearance.system": ("System", "跟随系统"),
        "settings.appearance.light": ("Light", "浅色"),
        "settings.appearance.dark": ("Dark", "深色"),
        "settings.colorTheme": ("Color theme", "主题色"),
        "settings.colorTheme.orange": ("Orange", "橙色"),
        "settings.colorTheme.blue": ("Blue", "蓝色"),
        "settings.colorTheme.green": ("Green", "绿色"),
        "settings.language": ("Language", "语言"),
        "settings.language.en": ("English", "English"),
        "settings.language.zh": ("简体中文", "简体中文"),

        "shop.cartA11y": ("Cart: %d", "购物车：%d"),

        "result.orderNumber": ("Order number", "订单号"),
        "result.amount": ("Amount", "金额"),
        "result.thanks": ("Thank you for your order", "感谢您的订单"),
        "result.callback": ("Callback", "回调"),
        "result.state.succeeded": ("Payment succeeded", "支付成功"),
        "result.state.pending": ("Payment pending", "支付处理中"),
        "result.state.unknown": ("Payment status unknown", "支付状态未知"),
        "result.state.failed": ("Payment failed", "支付失败"),
        "result.state.canceled": ("Payment canceled", "支付已取消"),

        "payment.canceled": ("Payment was canceled.", "支付已取消。"),
        "payment.failed": ("Payment failed. Please try again.", "支付失败，请重试。"),
    ]

    /// All known keys.
    static let keys: [String] = table.keys.sorted()

    /// Returns the localized value, or the key itself when it is unknown.
    static func value(_ key: String, _ lang: ShowcaseLanguage) -> String {
        guard let entry = table[key] else { return key }
        switch lang {
        case .en: return entry.en
        case .zh: return entry.zh
        }
    }
}
