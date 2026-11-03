#if canImport(UIKit)
    import UIKit

    /// The grouped card-entry form (design §5, screens 3/4): a card-number row (with a trailing card /
    /// error icon), a hairline divider, then a `MM/YY | CVC` row split by a vertical divider — all
    /// inside one rounded, bordered, optionally-shadowed group.
    ///
    /// ## Responsibility boundary
    /// `CardFormView` absorbs the former `CardField`'s only real logic — assembling a `CardInput` from
    /// the three fields — and is the single UI owner of the PCI keyboard/autofill hardening via
    /// `CardFieldSecurity.apply(...)`. It performs only light display formatting (4-digit PAN grouping,
    /// auto-insert `/` in expiry, CVC length cap); it does **not** encrypt, validate business rules, or
    /// log / persist any card data. Plaintext only ever lives inside the fields and the returned
    /// `CardInput`, which the caller discards immediately after encryption (security-and-pci.md §4).
    ///
    /// ## `cardInput` rules (unchanged from `CardField`)
    /// Returns non-`nil` only when PAN / expiry / CVC are all non-empty after trimming whitespace, and
    /// the expiry splits on `/` into two non-empty "month / year" segments; otherwise `nil`.
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    final class CardFormView: UIView {
        /// Identifies a field for `showFieldError(_:message:)`.
        enum CardFormField {
            case number
            case expiry
            case cvc
        }

        /// Invoked whenever any field's text changes (so the content VC can re-evaluate CTA state).
        var onEditingChanged: (() -> Void)?

        // MARK: - Fields

        private let panField = UITextField()
        private let expiryField = UITextField()
        private let cvvField = UITextField()

        private let brandIconView = UIImageView()
        private let errorLabel = UILabel()

        private let group = UIView()
        private let rowDivider = UIView()
        private let columnDivider = UIView()

        private let appearance: ResolvedAppearance
        private var hasFieldError = false

        // MARK: - Init

        /// Creates the card form with resolved appearance tokens and a localization closure.
        ///
        /// - Parameters:
        ///   - appearance: The resolved appearance providing colors, fonts, corner radius, border width,
        ///     and the optional group shadow.
        ///   - localize: The localization closure for placeholders and the field error label.
        init(appearance: ResolvedAppearance, localize: @escaping (String) -> String) {
            self.appearance = appearance
            super.init(frame: .zero)
            configureSubviews(localize: localize)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        // MARK: - Public API

        /// The currently assembled card plaintext input, or `nil` when incomplete.
        ///
        /// "Complete" means PAN / expiry / CVC all non-empty after trimming, and the expiry splits on
        /// `/` into two non-empty segments. The returned `CardInput` carries plaintext; the caller must
        /// discard it after use and must not log / persist it.
        var cardInput: CardInput? {
            let pan = (panField.text ?? "").trimmingCharacters(in: .whitespaces)
            let cvv = (cvvField.text ?? "").trimmingCharacters(in: .whitespaces)
            let expiry = (expiryField.text ?? "").trimmingCharacters(in: .whitespaces)

            guard !pan.isEmpty, !cvv.isEmpty, !expiry.isEmpty else { return nil }

            let parts = expiry.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let month = parts[0].trimmingCharacters(in: .whitespaces)
            let year = parts[1].trimmingCharacters(in: .whitespaces)
            guard !month.isEmpty, !year.isEmpty else { return nil }

            // Strip the display-only PAN grouping spaces before handing plaintext upstream.
            let digitsOnlyPan = pan.filter { !$0.isWhitespace }

            return CardInput(
                cardNumber: digitsOnlyPan,
                expiryMonth: month,
                expiryYear: year,
                cvv: cvv
            )
        }

        /// Shows or clears a per-field error: a non-nil `message` turns the group border danger and
        /// shows the error label; `nil` clears the error styling.
        ///
        /// - Parameters:
        ///   - field: The field the error relates to (reserved for future per-field emphasis).
        ///   - message: The localized error message, or `nil` to clear.
        func showFieldError(_ field: CardFormField, message: String?) {
            if let message, !message.isEmpty {
                hasFieldError = true
                errorLabel.text = message
                errorLabel.isHidden = false
            } else {
                hasFieldError = false
                errorLabel.text = nil
                errorLabel.isHidden = true
            }
            refreshGroupBorder()
        }

        /// Test seam: sets the three fields' text directly (bypassing formatting), so unit tests can
        /// assert `cardInput` assembly without simulating keystrokes.
        ///
        /// - Parameters:
        ///   - pan: PAN field text.
        ///   - expiry: Expiry field text (`MM/YY`).
        ///   - cvv: CVC field text.
        func setFieldsForTest(pan: String, expiry: String, cvv: String) {
            panField.text = pan
            expiryField.text = expiry
            cvvField.text = cvv
        }

        // MARK: - Layout

        private func configureSubviews(localize: @escaping (String) -> String) {
            CardFieldSecurity.apply(toPAN: panField, expiry: expiryField, cvv: cvvField)

            for field in [panField, expiryField, cvvField] {
                field.font = appearance.cardFieldFont
                field.textColor = appearance.text
                field.delegate = self
                field.translatesAutoresizingMaskIntoConstraints = false
                field.addTarget(self, action: #selector(handleEditingChanged), for: .editingChanged)
            }

            panField.placeholder = localize("sunbay.card.number")
            expiryField.placeholder = localize("sunbay.card.expiry")
            cvvField.placeholder = localize("sunbay.card.cvc")

            brandIconView.image = UIImage(systemName: "creditcard")
            brandIconView.tintColor = appearance.textSecondary
            brandIconView.contentMode = .scaleAspectFit
            brandIconView.setContentHuggingPriority(.required, for: .horizontal)
            brandIconView.translatesAutoresizingMaskIntoConstraints = false

            group.backgroundColor = appearance.componentBackground
            group.layer.cornerRadius = appearance.cornerRadius
            group.translatesAutoresizingMaskIntoConstraints = false
            addSubview(group)

            rowDivider.backgroundColor = appearance.border
            columnDivider.backgroundColor = appearance.border
            rowDivider.translatesAutoresizingMaskIntoConstraints = false
            columnDivider.translatesAutoresizingMaskIntoConstraints = false
            group.addSubview(rowDivider)
            group.addSubview(columnDivider)

            group.addSubview(panField)
            group.addSubview(brandIconView)
            group.addSubview(expiryField)
            group.addSubview(cvvField)

            errorLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
            errorLabel.textColor = appearance.danger
            errorLabel.numberOfLines = 0
            errorLabel.isHidden = true
            errorLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(errorLabel)

            let rowHeight: CGFloat = appearance.density == .compact ? 44 : 52

            NSLayoutConstraint.activate([
                group.topAnchor.constraint(equalTo: topAnchor),
                group.leadingAnchor.constraint(equalTo: leadingAnchor),
                group.trailingAnchor.constraint(equalTo: trailingAnchor),

                // Card number row.
                panField.topAnchor.constraint(equalTo: group.topAnchor),
                panField.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 12),
                panField.heightAnchor.constraint(equalToConstant: rowHeight),
                panField.trailingAnchor.constraint(equalTo: brandIconView.leadingAnchor, constant: -8),

                brandIconView.centerYAnchor.constraint(equalTo: panField.centerYAnchor),
                brandIconView.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -12),
                brandIconView.widthAnchor.constraint(equalToConstant: 24),
                brandIconView.heightAnchor.constraint(equalToConstant: 18),

                // Horizontal divider between the two rows.
                rowDivider.topAnchor.constraint(equalTo: panField.bottomAnchor),
                rowDivider.leadingAnchor.constraint(equalTo: group.leadingAnchor),
                rowDivider.trailingAnchor.constraint(equalTo: group.trailingAnchor),
                rowDivider.heightAnchor.constraint(equalToConstant: 1),

                // Expiry | CVC row.
                expiryField.topAnchor.constraint(equalTo: rowDivider.bottomAnchor),
                expiryField.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 12),
                expiryField.heightAnchor.constraint(equalToConstant: rowHeight),
                expiryField.bottomAnchor.constraint(equalTo: group.bottomAnchor),

                columnDivider.topAnchor.constraint(equalTo: rowDivider.bottomAnchor, constant: 8),
                columnDivider.bottomAnchor.constraint(equalTo: group.bottomAnchor, constant: -8),
                columnDivider.widthAnchor.constraint(equalToConstant: 1),
                columnDivider.centerXAnchor.constraint(equalTo: group.centerXAnchor),
                columnDivider.leadingAnchor.constraint(equalTo: expiryField.trailingAnchor, constant: 8),

                cvvField.topAnchor.constraint(equalTo: rowDivider.bottomAnchor),
                cvvField.leadingAnchor.constraint(equalTo: columnDivider.trailingAnchor, constant: 8),
                cvvField.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -12),
                cvvField.bottomAnchor.constraint(equalTo: group.bottomAnchor),
                cvvField.heightAnchor.constraint(equalToConstant: rowHeight),

                // Error label below the group.
                errorLabel.topAnchor.constraint(equalTo: group.bottomAnchor, constant: 6),
                errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                errorLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])

            refreshGroupBorder()
        }

        // MARK: - Trait handling

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            refreshGroupBorder()
        }

        /// Re-applies the group's border (danger when a field error is showing, otherwise the neutral
        /// border) and the optional shadow, re-resolving `cgColor` against the current trait.
        private func refreshGroupBorder() {
            let borderColor = (hasFieldError ? appearance.danger : appearance.border)
                .resolvedColor(with: traitCollection)
            ThemeableView.applyDynamicLayerColors(
                to: group.layer,
                border: borderColor,
                borderWidth: max(appearance.borderWidth, 1),
                shadow: appearance.shadow
            )
        }

        // MARK: - Editing

        @objc private func handleEditingChanged() {
            onEditingChanged?()
        }
    }

    // MARK: - Light display formatting

    extension CardFormView: UITextFieldDelegate {
        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let current = textField.text ?? ""
            guard let swiftRange = Range(range, in: current) else { return true }
            let updated = current.replacingCharacters(in: swiftRange, with: string)

            switch textField {
            case panField:
                textField.text = Self.formatPAN(updated)
                sendEditingChanged(textField)
                return false
            case expiryField:
                textField.text = Self.formatExpiry(updated)
                sendEditingChanged(textField)
                return false
            case cvvField:
                let digits = updated.filter(\.isNumber)
                textField.text = String(digits.prefix(4))
                sendEditingChanged(textField)
                return false
            default:
                return true
            }
        }

        private func sendEditingChanged(_ textField: UITextField) {
            textField.sendActions(for: .editingChanged)
        }

        /// Groups PAN digits into blocks of four separated by a single space (display only), capped at
        /// 19 digits (the longest supported PAN).
        static func formatPAN(_ raw: String) -> String {
            let digits = String(raw.filter(\.isNumber).prefix(19))
            var grouped = ""
            for (index, character) in digits.enumerated() {
                if index != 0, index % 4 == 0 { grouped.append(" ") }
                grouped.append(character)
            }
            return grouped
        }

        /// Formats expiry as `MM/YY`, auto-inserting the `/` after the month (display only), capped at
        /// four digits.
        static func formatExpiry(_ raw: String) -> String {
            let digits = String(raw.filter(\.isNumber).prefix(4))
            guard digits.count > 2 else { return digits }
            let month = digits.prefix(2)
            let year = digits.dropFirst(2)
            return "\(month)/\(year)"
        }
    }
#endif
