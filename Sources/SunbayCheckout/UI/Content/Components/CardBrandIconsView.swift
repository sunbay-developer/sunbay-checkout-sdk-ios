#if canImport(UIKit)
    import UIKit

    /// The brand icons at the trailing edge of the card-number field (mirrors the HPP page).
    ///
    /// - Number empty: the first `visibleCount` brands are fixed and the remaining ones rotate in one extra
    ///   slot (every `interval` seconds, cross-faded). With `visibleCount` or fewer brands all are shown and
    ///   nothing rotates.
    /// - Number non-empty: only the icon of the recognized brand; nothing when no brand is recognized or
    ///   the recognized brand is not among the session's brands.
    /// - When no brand is available at all (no brands in the session) the empty state falls back to
    ///   the system card glyph. A single logo that fails to load or decode becomes a text badge.
    ///
    /// Presentational only: it receives the scheme, never card digits.
    final class CardBrandIconsView: UIView {
        /// Every brand gets the same fixed slot (logos aspect-fit inside), so a wide logo rotating in
        /// never changes the row width or pushes the other icons.
        private static let iconSize = CGSize(width: 30, height: 24)
        private static let spacing: CGFloat = 2
        private static let fallbackSize = CGSize(width: 28, height: 21)

        private let appearance: ResolvedAppearance
        private let loader: CardBrandLogoLoader
        private let interval: TimeInterval
        private let visibleCount: Int

        private var items: [CardBrandItem] = []
        private var images: [String: UIImage] = [:]
        private var resolved: Set<String> = []
        private var isEmpty = true
        private var scheme: String?
        private var rotatingIndex = 0
        private var timer: Timer?
        private var generation = 0

        private let stack = UIStackView()
        private let slotView = UIImageView()
        private var shown: [String] = []
        private var fallbackShown = false

        init(
            appearance: ResolvedAppearance, loader: CardBrandLogoLoader? = nil,
            interval: TimeInterval = 2, visibleCount: Int = 2
        ) {
            self.appearance = appearance
            self.loader = loader ?? CardBrandLogoLoader()
            self.interval = interval
            self.visibleCount = visibleCount
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            stack.axis = .horizontal
            stack.spacing = Self.spacing
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            setContentHuggingPriority(.required, for: .horizontal)
            setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        deinit { timer?.invalidate() }

        // MARK: - Public API

        /// Sets the session's brands (backend order) and starts loading their logos.
        func configure(items: [CardBrandItem]) {
            generation += 1
            let mine = generation
            self.items = items
            images = [:]
            resolved = []
            rotatingIndex = 0
            for item in items {
                loader.image(for: item.logoURL) { [weak self] image in
                    guard let self, self.generation == mine else { return }
                    self.resolved.insert(item.scheme)
                    // A logo that cannot be fetched or decoded (for example an SVG, which UIKit cannot
                    // decode) is replaced by a text badge, so the brand is never silently missing.
                    self.images[item.scheme] = image ?? self.makeBadge(for: item)
                    self.render()
                }
            }
            render()
        }

        /// Updates what the number field currently holds: whether it is empty and the recognized scheme.
        func update(isEmpty: Bool, scheme: String?) {
            guard isEmpty != self.isEmpty || scheme != self.scheme else { return }
            self.isEmpty = isEmpty
            self.scheme = scheme
            render()
        }

        override var intrinsicContentSize: CGSize {
            if fallbackShown { return Self.fallbackSize }
            guard !shown.isEmpty else { return CGSize(width: 0, height: Self.iconSize.height) }
            let count = CGFloat(shown.count)
            return CGSize(
                width: count * Self.iconSize.width + (count - 1) * Self.spacing, height: Self.iconSize.height)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateTimer()
        }

        // MARK: - Rendering

        private var loadedItems: [CardBrandItem] { items.filter { images[$0.scheme] != nil } }

        private var rotatingItems: [CardBrandItem] {
            let loaded = loadedItems
            return loaded.count > visibleCount ? Array(loaded.dropFirst(visibleCount)) : []
        }

        private func render() {
            stack.arrangedSubviews.forEach {
                stack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            shown = []
            fallbackShown = false

            if !isEmpty {
                if let match = CardBrandItem.item(matching: scheme, in: items), let image = images[match.scheme] {
                    stack.addArrangedSubview(makeIcon(image))
                    shown = [match.scheme]
                }
            } else {
                let loaded = loadedItems
                if loaded.isEmpty {
                    stack.addArrangedSubview(makeFallback())
                    fallbackShown = true
                } else {
                    for item in loaded.prefix(visibleCount) {
                        stack.addArrangedSubview(makeIcon(images[item.scheme]!))
                        shown.append(item.scheme)
                    }
                    let rotating = rotatingItems
                    if !rotating.isEmpty {
                        let current = rotating[rotatingIndex % rotating.count]
                        configure(slot: slotView, with: images[current.scheme]!)
                        stack.addArrangedSubview(slotView)
                        shown.append(current.scheme)
                    }
                }
            }
            invalidateIntrinsicContentSize()
            updateTimer()
        }

        private func makeIcon(_ image: UIImage) -> UIImageView {
            let view = UIImageView()
            configure(slot: view, with: image)
            return view
        }

        private func configure(slot view: UIImageView, with image: UIImage) {
            view.image = image
            view.contentMode = .scaleAspectFit
            view.translatesAutoresizingMaskIntoConstraints = false
            view.constraints.forEach { view.removeConstraint($0) }
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: Self.iconSize.width),
                view.heightAnchor.constraint(equalToConstant: Self.iconSize.height),
            ])
        }

        private static let badgeLabels = [
            "visa": "VISA", "mastercard": "MC", "amex": "AMEX", "discover": "DISC", "jcb": "JCB",
            "unionpay": "UP", "dinersclub": "DINERS", "maestro": "MAESTRO",
        ]

        /// A small bordered text badge standing in for a logo that could not be loaded or decoded.
        private func makeBadge(for item: CardBrandItem) -> UIImage {
            let text = Self.badgeLabels[item.scheme] ?? String(item.scheme.prefix(5)).uppercased()
            let size = Self.iconSize
            let border = appearance.border
            let color = appearance.textSecondary
            let traits = traitCollection
            return UIGraphicsImageRenderer(size: size).image { _ in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 3)
                path.lineWidth = 1
                border.resolvedColor(with: traits).setStroke()
                path.stroke()
                var fontSize: CGFloat = 9
                var attributes: [NSAttributedString.Key: Any] = [:]
                var textSize = CGSize.zero
                repeat {
                    attributes = [
                        .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                        .foregroundColor: color.resolvedColor(with: traits),
                    ]
                    textSize = (text as NSString).size(withAttributes: attributes)
                    fontSize -= 0.5
                } while textSize.width > size.width - 4 && fontSize > 4
                (text as NSString).draw(
                    at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                    withAttributes: attributes)
            }
        }

        private func makeFallback() -> UIImageView {
            let view = UIImageView(image: UIImage(systemName: "creditcard"))
            view.tintColor = appearance.textSecondary
            view.contentMode = .scaleAspectFit
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: Self.fallbackSize.width),
                view.heightAnchor.constraint(equalToConstant: Self.fallbackSize.height),
            ])
            return view
        }

        // MARK: - Rotation

        private var shouldRotate: Bool { isEmpty && window != nil && rotatingItems.count > 0 && loadedItems.count > visibleCount }

        private func updateTimer() {
            if shouldRotate {
                guard timer == nil else { return }
                let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.advance() }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            } else {
                timer?.invalidate()
                timer = nil
            }
        }

        private func advance() {
            let rotating = rotatingItems
            guard isEmpty, rotating.count > 0 else { return }
            rotatingIndex = (rotatingIndex + 1) % rotating.count
            let next = images[rotating[rotatingIndex].scheme]!
            if shown.count > visibleCount { shown[shown.count - 1] = rotating[rotatingIndex].scheme }
            if UIAccessibility.isReduceMotionEnabled {
                slotView.image = next
            } else {
                UIView.transition(with: slotView, duration: 0.3, options: .transitionCrossDissolve) {
                    self.slotView.image = next
                }
            }
        }

        #if DEBUG
            /// Test readout: schemes of the icons currently shown (fixed ones first, then the rotating one).
            var visibleSchemesForTest: [String] { shown }
            /// Test readout: whether the system card glyph fallback is shown.
            var showsFallbackForTest: Bool { fallbackShown }
            /// Test readout: whether the rotation timer is running.
            var isRotatingForTest: Bool { timer != nil }
            /// Test readout: how many brand logo loads have finished (success or failure).
            var resolvedCountForTest: Int { resolved.count }
            /// Test seam: performs one rotation step without waiting for the timer.
            func advanceForTest() { advance() }
        #endif
    }
#endif
