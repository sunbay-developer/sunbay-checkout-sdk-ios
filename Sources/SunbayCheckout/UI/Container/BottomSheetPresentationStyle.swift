#if canImport(UIKit)
    import UIKit

    /// How the payment sheet is presented, chosen from the device idiom (Stripe parity).
    ///
    /// - `.customBottomSheet`: iPhone (and any non-pad/mac/vision idiom) — full-width, edge-attached
    ///   sheet driven by `BottomSheetPresentationController`.
    /// - `.formSheet`: iPad, Mac (Catalyst / Designed-for-iPad) and visionOS — the system form sheet,
    ///   non-dismissible by the system (`isModalInPresentation = true`); `Appearance.sheetSizing` does
    ///   not apply there because the system sizes the form sheet.
    enum BottomSheetPresentationStyle: Equatable {
        case customBottomSheet
        case formSheet

        /// `UIUserInterfaceIdiom.vision` (iOS SDK 17+) raw value; spelled numerically so the package
        /// does not depend on the SDK symbol.
        private static let visionIdiomRawValue = 6

        /// Resolves the style for an idiom.
        static func resolve(idiom: UIUserInterfaceIdiom) -> BottomSheetPresentationStyle {
            #if os(visionOS)
                return .formSheet
            #else
                if idiom == .pad || idiom == .mac || idiom.rawValue == visionIdiomRawValue {
                    return .formSheet
                }
                return .customBottomSheet
            #endif
        }
    }
#endif
