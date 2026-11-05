#if canImport(UIKit)
    import UIKit

    /// The simple (fixed) billing-address form (design §5): exactly three controls — a Country dropdown
    /// driven by the local system region list, a free-text Address (line1) field, and a free-text Postal
    /// code field.
    ///
    /// Unlike `DynamicAddressFormView`, this form uses no backend metadata and no field linkage: country
    /// names come from the system `Locale`, labels from our `.strings`, and it fills only
    /// `country` / `line1` / `postalCode` in `AddressInput` (everything else stays nil). `addressInput`
    /// reads the current control values on demand.
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    final class SimpleAddressFormView: UIView {
        private let appearance: ResolvedAppearance

        private let countryButton = UIButton(type: .system)
        private let line1Field: FloatingLabelTextField
        private let postalField: FloatingLabelTextField

        private var selectedCountryCode: String?
        private let countries: [(code: String, name: String)]

        /// Creates the simple address form.
        ///
        /// - Parameters:
        ///   - appearance: The resolved appearance providing colors, fonts, corner radius, border width.
        ///   - localize: The localization closure for the three field labels.
        init(appearance: ResolvedAppearance, localize: @escaping (String) -> String) {
            self.appearance = appearance
            self.countries = Self.systemCountries()
            self.line1Field = FloatingLabelTextField(appearance: appearance)
            self.postalField = FloatingLabelTextField(appearance: appearance)
            super.init(frame: .zero)
            configureSubviews(localize: localize)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        /// The user-entered address; fills only `country` / `line1` / `postalCode`.
        var addressInput: AddressInput {
            AddressInput(
                country: selectedCountryCode,
                line1: nonEmpty(line1Field.text),
                postalCode: nonEmpty(postalField.text)
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
            for field in [line1Field, postalField] {
                field.font = appearance.cardFieldFont
                field.textColor = appearance.text
                field.autocorrectionType = .no
                field.translatesAutoresizingMaskIntoConstraints = false
            }
            postalField.keyboardType = .numbersAndPunctuation

            // Each control is its own bordered box; text fields highlight their border on focus.
            let countryField = FieldContainerView(appearance: appearance, control: countryButton)
            let line1Container = FieldContainerView(appearance: appearance, control: line1Field)
            let postalContainer = FieldContainerView(appearance: appearance, control: postalField)

            let stack = UIStackView(arrangedSubviews: [countryField, line1Container, postalContainer])
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
            countryButton.contentHorizontalAlignment = .leading
            countryButton.tintColor = appearance.text
            countryButton.setTitleColor(appearance.textSecondary, for: .normal)
            countryButton.titleLabel?.font = appearance.cardFieldFont
            countryButton.setTitle(localize("sunbay.address.country"), for: .normal)
            countryButton.translatesAutoresizingMaskIntoConstraints = false

            let actions = countries.map { entry in
                UIAction(title: entry.name) { [weak self] _ in
                    self?.selectedCountryCode = entry.code
                    self?.countryButton.setTitle(entry.name, for: .normal)
                    self?.countryButton.setTitleColor(self?.appearance.text, for: .normal)
                }
            }
            countryButton.menu = UIMenu(children: actions)
            countryButton.showsMenuAsPrimaryAction = true
        }
    }
#endif
