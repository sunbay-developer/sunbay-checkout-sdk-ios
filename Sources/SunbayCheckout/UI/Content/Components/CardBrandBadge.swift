#if canImport(UIKit)
    import UIKit

    /// A small bordered text badge that stands in for a card-brand logo (no logo, or it failed to load).
    ///
    /// Shared by the card-number field's brand icons and the saved-card rows, so both draw the same badge
    /// in the same 30x24 slot.
    enum CardBrandBadge {
        static let size = CGSize(width: 30, height: 24)

        private static let labels = [
            "visa": "VISA", "mastercard": "MC", "amex": "AMEX", "americanexpress": "AMEX", "discover": "DISC",
            "jcb": "JCB", "unionpay": "UP", "dinersclub": "DINERS", "diners": "DINERS", "maestro": "MAESTRO",
        ]

        /// The badge text for a scheme or brand name. Case, spaces, `_` and `-` are ignored
        /// (`"MASTERCARD"` and `"master_card"` both give `MC`); an unknown brand gives its first 5 letters.
        static func text(for brand: String) -> String {
            let key = brand.lowercased().filter { $0 != " " && $0 != "_" && $0 != "-" }
            return labels[key] ?? String(key.prefix(5)).uppercased()
        }

        /// Draws the badge for `brand` with the appearance's border and secondary text colors.
        static func image(brand: String, appearance: ResolvedAppearance, traits: UITraitCollection) -> UIImage {
            let text = text(for: brand)
            let border = appearance.border.resolvedColor(with: traits)
            let color = appearance.textSecondary.resolvedColor(with: traits)
            return UIGraphicsImageRenderer(size: size).image { _ in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 3)
                path.lineWidth = 1
                border.setStroke()
                path.stroke()
                var fontSize: CGFloat = 9
                var attributes: [NSAttributedString.Key: Any] = [:]
                var textSize = CGSize.zero
                repeat {
                    attributes = [.font: UIFont.systemFont(ofSize: fontSize, weight: .bold), .foregroundColor: color]
                    textSize = (text as NSString).size(withAttributes: attributes)
                    fontSize -= 0.5
                } while textSize.width > size.width - 4 && fontSize > 4
                (text as NSString).draw(
                    at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                    withAttributes: attributes)
            }
        }
    }
#endif
