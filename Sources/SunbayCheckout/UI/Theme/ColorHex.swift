#if canImport(UIKit)
    import UIKit

    /// Tolerant hex-string → `UIColor` parsing, a Theme-layer primitive used by the UI layer
    /// (design tokens, merchant-supplied appearance overrides).
    ///
    /// Accepts `#RGB`, `#RRGGBB`, and `#RRGGBBAA`:
    /// - The leading `#` is optional.
    /// - Parsing is case-insensitive.
    /// - `#RGB` is expanded to `#RRGGBB` by doubling each nibble (e.g. `f60` → `ff6600`).
    /// - `#RRGGBBAA` carries an explicit alpha channel; the shorter forms default to fully opaque.
    ///
    /// Any input that is not one of those exact lengths, or that contains a non-hex character,
    /// returns `nil` rather than a fallback color — callers decide how to handle invalid values.
    ///
    /// iOS-only: `UIColor` belongs to UIKit, so this is gated by `#if canImport(UIKit)` and does
    /// not compile under the macOS host (`swift test`). RED/GREEN is verified on the iOS Simulator.
    extension UIColor {
        /// Creates a color from a tolerant hex string, or returns `nil` if the string is not a
        /// valid `#RGB` / `#RRGGBB` / `#RRGGBBAA` value.
        ///
        /// - Parameter sunbayHex: A hex color string. The leading `#` is optional and the input is
        ///   case-insensitive.
        convenience init?(sunbayHex: String) {
            // Strip an optional single leading '#' and normalize case.
            var hex = sunbayHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if hex.hasPrefix("#") {
                hex.removeFirst()
            }

            // Expand the 3-digit shorthand (#RGB) to the 6-digit form by doubling each nibble.
            if hex.count == 3 {
                hex = hex.map { "\($0)\($0)" }.joined()
            }

            // Only 6-digit (RRGGBB) and 8-digit (RRGGBBAA) forms are valid at this point.
            guard hex.count == 6 || hex.count == 8 else {
                return nil
            }

            // Reject any non-hex character before attempting to parse.
            guard hex.allSatisfy({ $0.isHexDigit }) else {
                return nil
            }

            guard let value = UInt64(hex, radix: 16) else {
                return nil
            }

            let red: CGFloat
            let green: CGFloat
            let blue: CGFloat
            let alpha: CGFloat

            if hex.count == 8 {
                red = CGFloat((value & 0xFF00_0000) >> 24) / 255.0
                green = CGFloat((value & 0x00FF_0000) >> 16) / 255.0
                blue = CGFloat((value & 0x0000_FF00) >> 8) / 255.0
                alpha = CGFloat(value & 0x0000_00FF) / 255.0
            } else {
                red = CGFloat((value & 0xFF0000) >> 16) / 255.0
                green = CGFloat((value & 0x00FF00) >> 8) / 255.0
                blue = CGFloat(value & 0x0000FF) / 255.0
                alpha = 1.0
            }

            self.init(red: red, green: green, blue: blue, alpha: alpha)
        }
    }
#endif
