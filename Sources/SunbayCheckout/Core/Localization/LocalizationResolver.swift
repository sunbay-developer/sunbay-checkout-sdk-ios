import Foundation

/// Resolves which `.lproj` bundle the SDK should localize against, following a
/// fixed precedence chain, and exposes convenience lookups bound to that bundle.
///
/// Resolution order: `explicitLocale`, then each entry of `systemLanguages` in
/// order, then an `en-US` default. The first candidate that maps to a real
/// `.lproj` sub-bundle of `Bundle.module` wins; if none do, `Bundle.module`
/// itself is used (which carries the `en` development localization).
struct LocalizationResolver {
    /// An app-supplied locale that overrides system preferences, if any.
    private let explicitLocale: String?

    /// The host's ordered preferred languages, most-preferred first.
    private let systemLanguages: [String]

    /// External locale code -> on-disk `.lproj` folder name.
    ///
    /// Kept as a static dictionary so adding a language later is a single entry.
    private static let externalCodeToLprojName: [String: String] = [
        "en": "en",
        "zh-Hans": "zh-Hans",
        "zh": "zh-Hans"
    ]

    init(explicitLocale: String?, systemLanguages: [String] = Locale.preferredLanguages) {
        self.explicitLocale = explicitLocale
        self.systemLanguages = systemLanguages
    }

    /// Maps an external locale code to the SDK's `.lproj` folder name.
    ///
    /// Tries the full code (`en-US`) first, then falls back to the primary
    /// subtag (`zh-CN` -> `zh`) so regional variants resolve to a base language.
    /// Returns `nil` when neither the full code nor its primary subtag matches.
    static func lprojName(forExternalCode code: String) -> String? {
        let normalized = code.replacingOccurrences(of: "_", with: "-")
        if let name = externalCodeToLprojName[normalized] {
            return name
        }
        if let dash = normalized.firstIndex(of: "-") {
            let primary = String(normalized[normalized.startIndex..<dash])
            if let name = externalCodeToLprojName[primary] {
                return name
            }
        }
        return nil
    }

    /// Returns the resolved `.lproj` sub-bundle, or `Bundle.module` as the
    /// `en` default when no candidate resolves to a real `.lproj` path.
    func resolvedBundle() -> Bundle {
        // Resolution order: explicit locale, then system languages, then the
        // en-US default.
        // Session-language tier (spec 1.3 step 2) would slot in here, between
        // explicitLocale and systemLanguages; it has no data source in v1.
        var candidates: [String] = []
        if let explicitLocale = explicitLocale {
            candidates.append(explicitLocale)
        }
        candidates.append(contentsOf: systemLanguages)
        candidates.append("en-US")

        for code in candidates {
            guard let lprojName = LocalizationResolver.lprojName(forExternalCode: code),
                  let path = Bundle.module.path(forResource: lprojName, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                continue
            }
            return bundle
        }
        return Bundle.module
    }

    /// Looks up `key` in the resolved bundle's `Localizable` table.
    func localized(_ key: String, _ comment: String) -> String {
        SunbayLocalizedString(key, bundle: resolvedBundle(), comment)
    }

    /// Comment-dropping convenience that Task 3 hands to the PaymentSheet VC.
    var localizedNoComment: (String) -> String {
        { key in self.localized(key, "") }
    }
}
