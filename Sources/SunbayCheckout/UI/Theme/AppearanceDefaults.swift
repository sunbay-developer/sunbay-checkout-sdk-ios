#if canImport(UIKit)
    import UIKit

    /// The SDK's built-in design-token colors, a Theme-layer primitive consumed by every later UI task.
    ///
    /// Two groups:
    /// - **Brand / status tokens** (`brandPrimary`, `danger`, `success`) are dynamic `UIColor`s built with
    ///   `UIColor { traitCollection in ... }`, resolving a paired light/dark value from the fixed token hex
    ///   strings. These are the SDK's own palette, independent of the system appearance.
    /// - **Semantic accessors** (`background`, `componentBackground`, `text`, `textSecondary`, `border`) map
    ///   onto the standard system dynamic colors so the SDK UI inherits the platform's light/dark behavior.
    ///
    /// Token values (verbatim from the plan):
    /// - brand `#ff6000` (shared across light and dark)
    /// - danger `#e5484d` (light) / `#ff6369` (dark)
    /// - success `#16a34a` (light) / `#3dd68c` (dark)
    ///
    /// iOS-only: `UIColor` and `UITraitCollection` belong to UIKit, so this is gated by
    /// `#if canImport(UIKit)` and does not compile under the macOS host (`swift test`).
    enum AppearanceDefaults {
        // MARK: - Brand / status tokens

        /// The brand accent color (`#ff6000`), identical in light and dark.
        static let brandPrimary = UIColor { _ in
            UIColor(sunbayHex: "#ff6000") ?? .systemOrange
        }

        /// The error / destructive color: `#e5484d` in light, `#ff6369` in dark.
        static let danger = UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark
                ? (UIColor(sunbayHex: "#ff6369") ?? .systemRed)
                : (UIColor(sunbayHex: "#e5484d") ?? .systemRed)
        }

        /// The success / confirmation color: `#16a34a` in light, `#3dd68c` in dark.
        static let success = UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark
                ? (UIColor(sunbayHex: "#3dd68c") ?? .systemGreen)
                : (UIColor(sunbayHex: "#16a34a") ?? .systemGreen)
        }

        // MARK: - Semantic accessors (mapped to system dynamic colors)

        /// The primary surface color (screen / sheet background).
        static var background: UIColor { .systemBackground }

        /// The background for grouped components layered on top of `background`.
        static var componentBackground: UIColor { .secondarySystemBackground }

        /// The primary text / label color.
        static var text: UIColor { .label }

        /// The secondary (de-emphasized) text / label color.
        static var textSecondary: UIColor { .secondaryLabel }

        /// The hairline separator / border color.
        static var border: UIColor { .separator }
    }
#endif
