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

        /// Invoked with the card-number digits after every change (feeds BIN recognition). The owner must
        /// only forward the leading BIN digits and must never log them.
        var onPANDigitsChanged: ((String) -> Void)?

        // MARK: - Fields

        private let panField: FloatingLabelTextField
        private let expiryField: FloatingLabelTextField
        private let cvvField: FloatingLabelTextField

        private let brandIconsView: CardBrandIconsView
        private let cvvIconView = UIImageView()
        private let errorLabel = UILabel()

        private let group = UIView()
        private let rowDivider = UIView()
        private let columnDivider = UIView()

        private let appearance: ResolvedAppearance
        private var localize: (String) -> String = { $0 }
        private var hasFieldError = false
        private var hasFocus = false

        // MARK: - Card brand rules

        /// The rules document in effect for this form (fixed while the form is on screen).
        private let ruleSet: CardRuleSet
        /// The scheme guessed locally from the typed prefix.
        private var localScheme: String?
        /// The scheme recognized by the backend; wins over the local guess.
        private var backendScheme: String?
        /// The effective rules for the card being typed.
        private var rules: CardRules { ruleSet.rules(forScheme: backendScheme ?? localScheme) }

        // MARK: - Init

        /// Creates the card form with resolved appearance tokens and a localization closure.
        ///
        /// - Parameters:
        ///   - appearance: The resolved appearance providing colors, fonts, corner radius, border width,
        ///     and the optional group shadow.
        ///   - localize: The localization closure for placeholders and the field error label.
        ///   - ruleSet: The card-brand rules (grouping, auto-advance, security-code length). Defaults to
        ///     the cached remote rules, else the bundled ones.
        ///   - brandItems: The session's card brands (logos), shown in the number field like the HPP page.
        ///   - logoLoader: Loads the brand logos; defaults to an in-memory loader (replaceable in tests).
        init(
            appearance: ResolvedAppearance, localize: @escaping (String) -> String,
            ruleSet: CardRuleSet = CardRulesProvider.activeRuleSet(),
            brandItems: [CardBrandItem] = [], logoLoader: CardBrandLogoLoader? = nil
        ) {
            self.ruleSet = ruleSet
            self.appearance = appearance
            self.brandIconsView = CardBrandIconsView(appearance: appearance, loader: logoLoader)
            self.panField = FloatingLabelTextField(appearance: appearance)
            self.expiryField = FloatingLabelTextField(appearance: appearance)
            self.cvvField = FloatingLabelTextField(appearance: appearance)
            super.init(frame: .zero)
            configureSubviews(localize: localize)
            brandIconsView.configure(items: brandItems)
            refreshBrandIcons()
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

            // Expiry is shown as `MM/YY`; the backend contract wants the month and a 4-digit year
            // separately. Reject malformed or already-expired values client-side.
            guard let (month, year) = ExpiryFormatter.components(from: expiry),
                ExpiryFormatter.isValid(month: month, year: year)
            else { return nil }

            // Strip the display-only PAN grouping spaces before handing plaintext upstream.
            let digitsOnlyPan = pan.filter { !$0.isWhitespace }

            // Lenient client-side checks (contract principle 3): the impossible is rejected, the rest is
            // left to the backend. No brand-length enforcement. The Luhn check applies to every card
            // except UnionPay, whose numbers are not always Luhn-valid.
            guard (12...19).contains(digitsOnlyPan.count), digitsOnlyPan.allSatisfy(\.isASCIIDigit),
                (3...4).contains(cvv.count), cvv.allSatisfy(\.isASCIIDigit)
            else { return nil }
            if rules.scheme != "unionpay", !CardScanParser.luhnValid(digitsOnlyPan) { return nil }

            return CardInput(
                cardNumber: digitsOnlyPan,
                expiryMonth: month,
                expiryYear: year,
                cvv: cvv
            )
        }

        /// Applies the scheme recognized by the backend (nil drops it, falling back to the local guess).
        /// Re-groups the number without changing any digit, keeping the caret beside the same digit.
        func setBackendScheme(_ scheme: String?) {
            guard scheme != backendScheme else { return }
            backendScheme = scheme
            reapplyRules()
            refreshBrandIcons()
        }

        /// Shows the brand icons for the current number: the carousel while empty, else the matched brand.
        private func refreshBrandIcons() {
            brandIconsView.update(
                isEmpty: !(panField.text ?? "").contains(where: \.isASCIIDigit),
                scheme: backendScheme ?? localScheme)
        }

        /// Re-groups the number field and refreshes the security-code hints after the rules changed.
        private func reapplyRules() {
            let caret = panField.selectedTextRange.map {
                panField.offset(from: panField.beginningOfDocument, to: $0.start)
            } ?? (panField.text as NSString?)?.length ?? 0
            let edit = PANFormatter.reformat(panField.text ?? "", caret: caret, rules: rules)
            if edit.text != panField.text {
                panField.text = edit.text
                if panField.isFirstResponder { Self.setCaret(in: panField, offset: edit.caret) }
            }
            applyRulesToSecurityCode()
        }

        /// The security-code example follows the brand (`1234` for Amex, else `123`).
        private func applyRulesToSecurityCode() {
            cvvField.floatedPlaceholder = rules.cvvPlaceholder
            // English follows the brand's own name (CVC by default, CVV for Visa…); the localized format
            // lets other languages keep a single word (zh: 安全码).
            let format = localize("sunbay.card.cvc.titleFormat")
            cvvField.title = format.contains("%@") ? String(format: format, rules.cvvName) : format
        }

        /// Shows or clears a per-field error: a non-nil `message` turns the group border danger and
        /// shows the error label; `nil` clears the error styling.
        ///
        /// - Parameters:
        ///   - field: The field the error relates to (reserved for future per-field emphasis).
        ///   - message: The localized error message, or `nil` to clear.
        func showFieldError(_ field: CardFormField, message: String?) {
            let active = (message?.isEmpty == false)
            if active {
                hasFieldError = true
                errorLabel.text = message
                errorLabel.isHidden = false
            } else {
                hasFieldError = false
                errorLabel.text = nil
                errorLabel.isHidden = true
            }
            // The error is shown as a whole-group state (red border + message), so all three field
            // labels adopt the danger color to match.
            for field in [panField, expiryField, cvvField] {
                field.setErrorActive(active)
            }
            refreshGroupBorder()
        }

        /// Fills the PAN (and expiry, when present) from a scan result, running the normal display
        /// formatting, then moves focus to the CVC field. Plaintext only passes through the fields.
        func applyScannedCard(_ card: ScannedCard) {
            localScheme = ruleSet.detectScheme(digits: card.pan)
            panField.text = PANFormatter.format(card.pan, rules: rules)
            onPANDigitsChanged?(card.pan)
            applyRulesToSecurityCode()
            refreshBrandIcons()
            if let month = card.expiryMonth, let year = card.expiryYear {
                expiryField.text = Self.formatExpiry(month + year)
            }
            showFieldError(.number, message: nil)
            onEditingChanged?()
            cvvField.becomeFirstResponder()
        }

        #if DEBUG
            /// Test readout: whether a field error (red group + message) is currently shown.
            var hasFieldErrorForTest: Bool { hasFieldError && !errorLabel.isHidden }
        #endif

        #if DEBUG
            /// Test readouts for the brand icons and the CVV icon.
            var brandSchemesForTest: [String] { brandIconsView.visibleSchemesForTest }
            var brandLogosResolvedForTest: Int { brandIconsView.resolvedCountForTest }
            var hasCVVIconForTest: Bool { cvvIconView.image != nil && cvvIconView.superview === group }

            /// Test seam: types `text` at the end of the number field through the real delegate path
            /// (an empty string clears the field).
            func typePANForTest(_ text: String) {
                let current = panField.text ?? ""
                let range =
                    text.isEmpty
                    ? NSRange(location: 0, length: (current as NSString).length)
                    : NSRange(location: (current as NSString).length, length: 0)
                _ = textField(panField, shouldChangeCharactersIn: range, replacementString: text)
            }
        #endif

        #if DEBUG
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
        #endif

        // MARK: - Layout

        private func configureSubviews(localize: @escaping (String) -> String) {
            CardFieldSecurity.apply(toPAN: panField, expiry: expiryField, cvv: cvvField)

            for field in [panField, expiryField, cvvField] {
                field.font = FloatingLabelMetrics.fieldFont(from: appearance.cardFieldFont)
                field.textColor = appearance.text
                field.delegate = self
                KeyboardDismissal.installDoneAccessory(on: field)
                field.translatesAutoresizingMaskIntoConstraints = false
                field.addTarget(self, action: #selector(handleEditingChanged), for: .editingChanged)
                field.addTarget(self, action: #selector(handleEditingDidBegin), for: .editingDidBegin)
                field.addTarget(self, action: #selector(handleEditingDidEnd), for: .editingDidEnd)
            }

            // Backspace on an empty field steps back to the previous one.
            expiryField.onBackspaceWhenEmpty = { [weak self] in self?.panField.becomeFirstResponder() }
            cvvField.onBackspaceWhenEmpty = { [weak self] in self?.expiryField.becomeFirstResponder() }

            panField.title = localize("sunbay.card.number")
            expiryField.title = localize("sunbay.card.expiry")
            self.localize = localize
            applyRulesToSecurityCode()

            // In-field example hints, shown only once the label has floated up and the field is still
            // empty (focused + empty). Static format examples — no sensitive data.
            panField.floatedPlaceholder = localize("sunbay.card.number.placeholder")
            expiryField.floatedPlaceholder = localize("sunbay.card.expiry.placeholder")
            cvvField.floatedPlaceholder = localize("sunbay.card.cvc.placeholder")

            cvvIconView.image = UIImage(named: "cvv-icon", in: .module, compatibleWith: nil)
            cvvIconView.contentMode = .scaleAspectFit
            cvvIconView.isUserInteractionEnabled = false
            cvvIconView.isAccessibilityElement = false
            cvvIconView.translatesAutoresizingMaskIntoConstraints = false
            brandIconsView.translatesAutoresizingMaskIntoConstraints = false

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
            group.addSubview(brandIconsView)
            group.addSubview(expiryField)
            group.addSubview(cvvField)
            group.addSubview(cvvIconView)

            errorLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
            errorLabel.textColor = appearance.danger
            errorLabel.numberOfLines = 0
            errorLabel.isHidden = true
            errorLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(errorLabel)

            // Taller rows than a bare field: the floating label occupies a top band inside each field,
            // so the row must fit label + text without clipping.
            let rowHeight: CGFloat = appearance.density == .compact ? 48 : 56

            NSLayoutConstraint.activate([
                group.topAnchor.constraint(equalTo: topAnchor),
                group.leadingAnchor.constraint(equalTo: leadingAnchor),
                group.trailingAnchor.constraint(equalTo: trailingAnchor),

                // Card number row.
                panField.topAnchor.constraint(equalTo: group.topAnchor),
                panField.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 12),
                panField.heightAnchor.constraint(equalToConstant: rowHeight),
                panField.trailingAnchor.constraint(equalTo: brandIconsView.leadingAnchor, constant: -8),

                brandIconsView.centerYAnchor.constraint(equalTo: panField.centerYAnchor),
                brandIconsView.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -12),

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
                cvvField.trailingAnchor.constraint(equalTo: cvvIconView.leadingAnchor, constant: -8),
                cvvField.bottomAnchor.constraint(equalTo: group.bottomAnchor),
                cvvField.heightAnchor.constraint(equalToConstant: rowHeight),

                cvvIconView.centerYAnchor.constraint(equalTo: cvvField.centerYAnchor),
                cvvIconView.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -12),
                cvvIconView.widthAnchor.constraint(equalToConstant: 34),
                cvvIconView.heightAnchor.constraint(equalToConstant: 20),

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

        /// Re-applies the group's border and the optional shadow, re-resolving `cgColor` against the
        /// current trait. Border color priority: error (danger) > focus (primary) > neutral (border).
        private func refreshGroupBorder() {
            let borderColor: UIColor
            if hasFieldError {
                borderColor = appearance.danger
            } else if hasFocus {
                borderColor = appearance.primary
            } else {
                borderColor = appearance.border
            }
            ThemeableView.applyDynamicLayerColors(
                to: group.layer,
                border: borderColor.resolvedColor(with: traitCollection),
                borderWidth: max(appearance.borderWidth, 1),
                shadow: appearance.shadow
            )
        }

        // MARK: - Editing

        @objc private func handleEditingChanged() {
            onEditingChanged?()
        }

        @objc private func handleEditingDidBegin() {
            hasFocus = true
            refreshGroupBorder()
        }

        /// Recomputes focus when a field ends editing: the group stays highlighted while any of the
        /// three card fields is still the first responder (so tabbing between them doesn't flicker).
        @objc private func handleEditingDidEnd() {
            hasFocus = panField.isFirstResponder || expiryField.isFirstResponder || cvvField.isFirstResponder
            refreshGroupBorder()
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
                // Guess the scheme from the digits the field will hold after this edit, so the edit is
                // formatted with the right grouping straight away.
                let probe = updated.filter(\.isASCIIDigit)
                localScheme = ruleSet.detectScheme(digits: probe)
                guard
                    let edit = PANFormatter.apply(
                        current: current, range: range, replacement: string, rules: rules)
                else { return false }
                textField.text = edit.text
                Self.setCaret(in: textField, offset: edit.caret)
                applyRulesToSecurityCode()
                refreshBrandIcons()
                sendEditingChanged(textField)
                onPANDigitsChanged?(edit.text.filter(\.isASCIIDigit))
                // Move on to the expiry field when the number reaches its brand's length, but only when
                // typing at the end, so editing a digit in the middle never steals focus.
                if !string.isEmpty, edit.caretAtEnd, shouldAdvanceFromPAN(edit.text) {
                    expiryField.becomeFirstResponder()
                }
                return false
            case expiryField:
                guard
                    let edit = ExpiryFormatter.apply(
                        current: current, range: range, replacement: string)
                else { return false }
                textField.text = edit.text
                Self.setCaret(in: textField, offset: edit.caret)
                sendEditingChanged(textField)
                // A full, month-valid MM/YY moves on to the CVC field.
                if edit.isComplete, !string.isEmpty, edit.caret == (edit.text as NSString).length {
                    cvvField.becomeFirstResponder()
                }
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

        /// Places the caret at a UTF-16 offset in the field.
        static func setCaret(in textField: UITextField, offset: Int) {
            guard let position = textField.position(from: textField.beginningOfDocument, offset: offset) else { return }
            textField.selectedTextRange = textField.textRange(from: position, to: position)
        }

        /// Whether focus should move on from the number field. With a known scheme: the digit count equals
        /// the brand's `autoAdvanceLength` (omitted for variable-length brands). Without one: the local
        /// heuristic fallback.
        private func shouldAdvanceFromPAN(_ display: String) -> Bool {
            let rules = self.rules
            if rules.scheme != nil {
                return display.filter(\.isASCIIDigit).count == rules.autoAdvanceLength
            }
            return Self.isCompletePAN(display)
        }

        /// Fallback heuristic when no scheme is known: whether the (display) number is complete for its brand. Only brands
        /// with a fixed length qualify, so variable-length numbers (e.g. UnionPay) are never
        /// cut off mid-entry: Amex 15; Visa / Mastercard / Discover / JCB 16. Must pass Luhn.
        static func isCompletePAN(_ display: String) -> Bool {
            let digits = display.filter(\.isNumber)
            guard CardScanParser.luhnValid(digits) else { return false }
            if digits.hasPrefix("34") || digits.hasPrefix("37") { return digits.count == 15 }
            if digits.hasPrefix("4") || digits.hasPrefix("5") || digits.hasPrefix("6011")
                || digits.hasPrefix("65") || digits.hasPrefix("35") || digits.hasPrefix("2")
            {
                return digits.count == 16
            }
            return false
        }

        /// Groups PAN digits into blocks of four separated by a single space (display only), capped at
        /// 19 digits (the longest supported PAN).
        static func formatPAN(_ raw: String) -> String { PANFormatter.format(raw) }

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
