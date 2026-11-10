#if canImport(UIKit)
    import UIKit

    /// The simple (fixed) billing-address form (design §5): exactly three controls — a Country dropdown
    /// driven by the local system region list, a free-text Address (line1) field, and a free-text Postal
    /// code field.
    ///
    /// Unlike `DynamicAddressFormView`, this form uses no backend metadata and no field linkage: country
    /// names come from the system `Locale`, labels from our `.strings`, and it fills only
    /// `country` / `line1` / `postalCode` in `AddressInput` (everything else stays nil). `addressInput`
    /// reads the current control values on demand. When `options.collectName` is on (shipping), a first /
    /// last name row is shown above the country dropdown and returned in `firstName` / `lastName`.
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    final class SimpleAddressFormView: UIView {
        private let appearance: ResolvedAppearance
        private let options: AddressFormOptions

        private let firstNameField: FloatingLabelTextField
        private let lastNameField: FloatingLabelTextField
        private let countryField: FloatingLabelMenuField
        private let line1Field: FloatingLabelTextField
        private let postalField: FloatingLabelTextField
        private let phoneField: FloatingLabelTextField

        private var selectedCountryCode: String?
        private let countries: [(code: String, name: String)]

        /// Creates the simple address form.
        ///
        /// - Parameters:
        ///   - appearance: The resolved appearance providing colors, fonts, corner radius, border width.
        ///   - localize: The localization closure for the field labels.
        ///   - options: Per-form switches (names are collected when `collectName` is on); defaults to billing.
        init(
            appearance: ResolvedAppearance,
            localize: @escaping (String) -> String,
            options: AddressFormOptions = .billing
        ) {
            self.appearance = appearance
            self.options = options
            self.firstNameField = FloatingLabelTextField(appearance: appearance)
            self.lastNameField = FloatingLabelTextField(appearance: appearance)
            self.countries = Self.systemCountries()
            self.countryField = FloatingLabelMenuField(
                appearance: appearance, title: localize("sunbay.address.country"))
            self.line1Field = FloatingLabelTextField(appearance: appearance)
            self.postalField = FloatingLabelTextField(appearance: appearance)
            self.phoneField = FloatingLabelTextField(appearance: appearance)
            super.init(frame: .zero)
            configureSubviews(localize: localize)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        /// The user-entered address; fills `country` / `line1` / `postalCode`, plus `firstName` /
        /// `lastName` when names are collected and `phone` when the phone is collected.
        var addressInput: AddressInput {
            AddressInput(
                country: selectedCountryCode,
                line1: nonEmpty(line1Field.text),
                postalCode: nonEmpty(postalField.text),
                firstName: options.collectName ? nonEmpty(firstNameField.text) : nil,
                lastName: options.collectName ? nonEmpty(lastNameField.text) : nil,
                phone: options.collectPhone ? nonEmpty(phoneField.text) : nil
            )
        }

        private func nonEmpty(_ text: String?) -> String? {
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }

        /// The local system country list (code + localized display name), sorted by name.
        private static func systemCountries() -> [(code: String, name: String)] {
            let locale = Locale.current
            return Locale.isoRegionCodes
                .compactMap { code -> (code: String, name: String)? in
                    guard let name = locale.localizedString(forRegionCode: code) else { return nil }
                    return (code: code, name: name)
                }
                .sorted { $0.name < $1.name }
        }

        private func configureSubviews(localize: @escaping (String) -> String) {
            configureCountryButton(localize: localize)

            line1Field.title = localize("sunbay.address.line1")
            postalField.title = localize("sunbay.address.postalCode")
            // In-field example hints, shown only when the label has floated up and the field is empty.
            line1Field.floatedPlaceholder = localize("sunbay.address.line1.placeholder")
            postalField.floatedPlaceholder = localize("sunbay.address.postalCode.placeholder")
            firstNameField.title = localize("sunbay.address.firstName")
            lastNameField.title = localize("sunbay.address.lastName")
            phoneField.title = localize("sunbay.address.phone")
            for field in [firstNameField, lastNameField, line1Field, postalField, phoneField] {
                field.font = FloatingLabelMetrics.fieldFont(from: appearance.cardFieldFont)
                field.textColor = appearance.text
                field.autocorrectionType = .no
                field.translatesAutoresizingMaskIntoConstraints = false
            }
            for field in [firstNameField, lastNameField] {
                field.autocapitalizationType = .words
            }
            firstNameField.textContentType = .givenName
            lastNameField.textContentType = .familyName
            postalField.keyboardType = .numbersAndPunctuation
            KeyboardDismissal.installDoneAccessory(on: postalField)
            phoneField.keyboardType = .phonePad
            phoneField.textContentType = .telephoneNumber
            KeyboardDismissal.installDoneAccessory(on: phoneField)

            // Each control is its own bordered box; text fields highlight their border on focus.
            let countryContainer = FieldContainerView(appearance: appearance, control: countryField)
            let line1Container = FieldContainerView(appearance: appearance, control: line1Field)
            let postalContainer = FieldContainerView(appearance: appearance, control: postalField)

            var rows: [UIView] = [countryContainer, line1Container, postalContainer]
            if options.collectName {
                let nameRow = UIStackView(arrangedSubviews: [
                    FieldContainerView(appearance: appearance, control: firstNameField),
                    FieldContainerView(appearance: appearance, control: lastNameField),
                ])
                nameRow.axis = .horizontal
                nameRow.spacing = 8
                nameRow.distribution = .fillEqually
                rows.insert(nameRow, at: 0)
            }

            if options.collectPhone {
                rows.append(FieldContainerView(appearance: appearance, control: phoneField))
            }

            let stack = UIStackView(arrangedSubviews: rows)
            stack.axis = .vertical
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)

            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        private func configureCountryButton(localize: @escaping (String) -> String) {
            let actions = countries.map { entry in
                UIAction(title: entry.name) { [weak self] _ in
                    self?.selectedCountryCode = entry.code
                    self?.countryField.setSelected(title: entry.name)
                }
            }
            countryField.setMenu(UIMenu(children: actions))
        }

        // MARK: - Test seams

        /// Whether the first / last name row is rendered.
        var hasNameFieldsForTest: Bool { options.collectName }

        /// Whether the phone field is rendered.
        var hasPhoneFieldForTest: Bool { options.collectPhone }

        /// Fills the controls directly (bypassing the country menu and keystrokes).
        func fillForTest(
            country: String, line1: String, postalCode: String, firstName: String? = nil, lastName: String? = nil,
            phone: String? = nil
        ) {
            selectedCountryCode = country
            line1Field.text = line1
            postalField.text = postalCode
            firstNameField.text = firstName
            lastNameField.text = lastName
            phoneField.text = phone
        }
    }
#endif
