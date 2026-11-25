#if canImport(UIKit)
    import UIKit

    /// Placeholder rows shown while the address form waits for its metadata.
    ///
    /// Each row has the size and outline of a real address field (`FloatingLabelMetrics.minFieldHeight` tall,
    /// rows 12 pt apart, matching `DynamicAddressFormView`) with a short bar where the label sits. A light
    /// shimmer sweeps across the rows while the view is in a window, unless Reduce Motion is on.
    @MainActor
    final class AddressSkeletonView: UIView {
        private static let rowSpacing: CGFloat = 12
        private static let shimmerKey = "sunbay.skeleton.shimmer"
        /// Very light fixed gray for the placeholder bar (the same in light and dark mode).
        static let barColor = UIColor(red: 0xF0 / 255, green: 0xF0 / 255, blue: 0xF0 / 255, alpha: 1)

        private let appearance: ResolvedAppearance
        private let isReduceMotionEnabled: () -> Bool
        private let stack = UIStackView()
        private let shimmerLayer = CAGradientLayer()

        /// Number of placeholder rows (always at least 1).
        var rowCount: Int {
            didSet {
                if rowCount < 1 { rowCount = 1 }
                if rowCount != oldValue { rebuildRows() }
            }
        }

        /// Creates the skeleton.
        ///
        /// - Parameters:
        ///   - appearance: Supplies the row fill, outline and corner radius.
        ///   - rowCount: Number of placeholder rows; values below 1 become 1.
        ///   - isReduceMotionEnabled: Reads the Reduce Motion setting (replaceable in tests).
        init(
            appearance: ResolvedAppearance, rowCount: Int,
            isReduceMotionEnabled: @escaping () -> Bool = { UIAccessibility.isReduceMotionEnabled }
        ) {
            self.appearance = appearance
            self.rowCount = max(1, rowCount)
            self.isReduceMotionEnabled = isReduceMotionEnabled
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            stack.axis = .vertical
            stack.spacing = Self.rowSpacing
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            shimmerLayer.startPoint = CGPoint(x: 0, y: 0.5)
            shimmerLayer.endPoint = CGPoint(x: 1, y: 0.5)
            shimmerLayer.locations = [0, 0.5, 1]
            rebuildRows()
            NotificationCenter.default.addObserver(
                self, selector: #selector(updateShimmer),
                name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateShimmer()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            shimmerLayer.frame = bounds
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            rebuildRows()
        }

        // MARK: - Rows

        private func rebuildRows() {
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for _ in 0..<rowCount { stack.addArrangedSubview(makeRow()) }
        }

        private func makeRow() -> UIView {
            let row = UIView()
            row.backgroundColor = appearance.componentBackground
            row.layer.cornerRadius = appearance.cornerRadius
            row.layer.borderWidth = max(appearance.borderWidth, 1 / max(traitCollection.displayScale, 1))
            row.layer.borderColor = appearance.border.resolvedColor(with: traitCollection).cgColor
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: FloatingLabelMetrics.minFieldHeight).isActive = true

            let bar = UIView()
            bar.backgroundColor = Self.barColor
            bar.layer.cornerRadius = 7
            bar.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
                bar.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                bar.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
                bar.heightAnchor.constraint(equalToConstant: 14),
            ])
            return row
        }

        // MARK: - Shimmer

        @objc private func updateShimmer() {
            guard window != nil, !isReduceMotionEnabled() else {
                shimmerLayer.removeAnimation(forKey: Self.shimmerKey)
                shimmerLayer.removeFromSuperlayer()
                return
            }
            let base = appearance.componentBackground.resolvedColor(with: traitCollection)
            shimmerLayer.colors = [
                base.withAlphaComponent(0).cgColor,
                base.withAlphaComponent(0.6).cgColor,
                base.withAlphaComponent(0).cgColor,
            ]
            if shimmerLayer.superlayer == nil { layer.addSublayer(shimmerLayer) }
            shimmerLayer.frame = bounds
            guard shimmerLayer.animation(forKey: Self.shimmerKey) == nil else { return }
            let animation = CABasicAnimation(keyPath: "locations")
            animation.fromValue = [-1.0, -0.5, 0.0]
            animation.toValue = [1.0, 1.5, 2.0]
            animation.duration = 1.2
            animation.repeatCount = .infinity
            shimmerLayer.add(animation, forKey: Self.shimmerKey)
        }

        #if DEBUG
            /// Test readout: whether the shimmer animation is running.
            var isShimmeringForTest: Bool { shimmerLayer.animation(forKey: Self.shimmerKey) != nil }
        #endif
    }
#endif
