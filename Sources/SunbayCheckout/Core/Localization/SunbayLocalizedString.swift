import Foundation

/// The localized-strings table bundled with the SDK.
private let localizableTable = "Localizable"

/// Looks up a localized string for `key` in `bundle`'s `Localizable` table.
///
/// When `key` is absent from the table, the key itself is returned (never an
/// empty string). This relies on the sentinel-default pattern: passing the key
/// as the `value:` argument means a missing lookup resolves to the key.
///
/// - Parameters:
///   - key: The lookup key, e.g. `"sunbay.sheet.pay"`.
///   - bundle: The bundle whose `Localizable` table is searched. Task 2's
///     resolver supplies a language-specific sub-bundle here.
///   - comment: A note for translators. Unused at runtime; present to mirror
///     `NSLocalizedString`'s shape.
/// - Returns: The localized value, or `key` when no entry exists.
func SunbayLocalizedString(_ key: String, bundle: Bundle, _ comment: String) -> String {
    bundle.localizedString(forKey: key, value: key, table: localizableTable)
}

/// The SDK's development-localization (`en`) sub-bundle, when present.
///
/// Resolving against this sub-bundle keeps the convenience overload
/// deterministic on hosts whose preferred language is not `en`. Falls back to
/// `Bundle.module` when the sub-bundle cannot be located.
private let developmentLocalizationBundle: Bundle = {
    if let path = Bundle.module.path(forResource: "en", ofType: "lproj"),
       let bundle = Bundle(path: path) {
        return bundle
    }
    return Bundle.module
}()

/// Convenience overload that resolves against the SDK's own resources.
///
/// Uses the `en` development localization deterministically so lookups return
/// the expected development-language value regardless of the host's preferred
/// language.
func SunbayLocalizedString(_ key: String, _ comment: String) -> String {
    SunbayLocalizedString(key, bundle: developmentLocalizationBundle, comment)
}
