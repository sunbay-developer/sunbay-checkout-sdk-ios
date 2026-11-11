#if canImport(UIKit)
    import Foundation
    import UIKit

    /// The full (dynamic) billing-address form (design §5, spec §7.5 / §7.3): it loads the country list
    /// and the selected country's field config from an injected `AddressMetadataService`, renders rows
    /// via `AddressFormLayoutResolver`, and rebuilds on country or locale change.
    ///
    /// ## Value preservation (spec §7.3, Review-Focus)
    /// User input is stored as **codes / raw text** in an internal `AddressInput` model (`country` code,
    /// `state` subdivision code, raw text for `line1` / `city` / `postalCode`, etc.) — never read back
    /// off the recreated controls. So when `reload(locale:)` refetches with a new locale and rebuilds
    /// the fields using the new labels/placeholders/subdivision names, the previously entered values are
    /// re-applied to the fresh controls (except fields that no longer exist). The same model drives
    /// rebuilds on a country change.
    ///
    /// ## States
    /// While fetching it shows a loading skeleton; on failure it shows an error message plus a retry
    /// button (matching the web `AddressForm.tsx` behavior); on success it shows the resolved rows. The
    /// state field is a subdivisions dropdown. `validate()` checks only the postal code, driven by the
    /// selected country's `postalCode` field config (required / `pattern`) via `PostalCodeValidator`; it
    /// returns false while metadata is loading (the tap is ignored), and never blocks after a load failure
    /// or when the country has no postal field. No
    /// other field is validated here, and there is no Google autocomplete or postal→state lookup.
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    final class DynamicAddressFormView: UIView {
        private let appearance: ResolvedAppearance
        private let options: AddressFormOptions
        private let localize: (String) -> String
        private let service: any AddressMetadataService
        /// When non-nil, only these field types are rendered (the country row is always rendered).
        private let visibleFields: Set<AddressFieldType>?

        private var locale: String?

        /// The user-entered values, stored as codes/raw text so they survive a rebuild (§7.3).
        private var model = AddressInput()

        // Loaded metadata for the current locale.
        private var countries: [AddressCountry] = []
        private var config: AddressCountryConfig?

        // UI state.
        private enum LoadState {
            case loading
            case loaded
            case failed
        }
        private var loadState: LoadState = .loading

        private let contentStack = UIStackView()
        private let skeletonView = UIView()
        private let errorContainer = UIView()
        private let errorLabel = UILabel()
        private let retryButton = UIButton(type: .system)
        /// The localization key of the postal error currently shown, if any.
        private var postalErrorKey: String?
        /// The postal error label of the current render (rebuilt with the fields).
        private var postalErrorLabel: UILabel?

        // Field controls keyed by type (rebuilt on each render).
        private var textFields: [AddressFieldType: UITextField] = [:]
        private var countryButton: FloatingLabelMenuField?
        private var stateButton: FloatingLabelMenuField?
        /// The phone field (shipping only), rebuilt below the layout rows on each render.
        private var phoneField: UITextField?

        // Test seam: a continuation completed when the in-flight load finishes (success or failure).
        private var loadFinishedForTest: (() -> Void)?

        /// Creates the dynamic address form and starts the initial fetch.
        ///
        /// - Parameters:
        ///   - appearance: The resolved appearance providing colors, fonts, corner radius, border width.
        ///   - localize: The localization closure (error / retry copy; field labels come from the backend).
        ///   - service: The address-metadata service (host-injected; mock or real adapter).
        ///   - locale: The effective locale for the initial fetch (nil uses the backend default).
        ///   - options: Per-form switches (for example whether names are collected); defaults to billing.
        ///   - visibleFields: When non-nil, restricts the rendered rows to these field types (the country
        ///     row is always rendered); nil renders every field the country config lays out.
        init(
            appearance: ResolvedAppearance,
            localize: @escaping (String) -> String,
            service: any AddressMetadataService,
            locale: String?,
            options: AddressFormOptions = .billing,
            visibleFields: Set<AddressFieldType>? = nil
        ) {
            self.options = options
            self.visibleFields = visibleFields
            self.appearance = appearance
            self.localize = localize
            self.service = service
            self.locale = locale
            super.init(frame: .zero)
            configureContainer()
            load()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        // MARK: - Public API

        /// The user-entered address values (codes / raw text).
        var addressInput: AddressInput {
            captureFieldValues()
            var input = model
            // A country without a postal field must not submit the previous country's stale value.
            if let config, config.fields[.postalCode] == nil { input.postalCode = nil }
            return input
        }

        /// Validates the postal code against the selected country's config and shows the error inline.
        ///
        /// - Returns: `false` while the metadata is still loading (the skeleton is visible, so no message is
        ///   shown and the Pay tap is simply ignored), or when the postal field is rendered and its value is
        ///   required-but-empty or does not match the country pattern. Returns `true` after a load failure
        ///   (full-mode exemption), when the country has no postal field, or when the postal field is not visible.
        func validate() -> Bool {
            if loadState == .loading { return false }
            guard loadState == .loaded, let postalConfig = config?.fields[.postalCode],
                textFields[.postalCode] != nil
            else {
                setPostalError(nil)
                return true
            }
            captureFieldValues()
            switch PostalCodeValidator.validate(model.postalCode, config: postalConfig) {
            case .valid:
                setPostalError(nil)
                return true
            case .required:
                setPostalError("sunbay.address.postalCode.required")
                return false
            case .invalidFormat:
                setPostalError("sunbay.address.postalCode.invalid")
                return false
            }
        }

        private func setPostalError(_ key: String?) {
            postalErrorKey = key
            postalErrorLabel?.text = key.map(localize)
            postalErrorLabel?.isHidden = key == nil
            (textFields[.postalCode] as? FloatingLabelTextField)?.setErrorActive(key != nil)
        }

        @objc private func handlePostalEditingChanged() {
            if postalErrorKey != nil { setPostalError(nil) }
        }

        /// Refetches with a new locale and rebuilds, preserving already-entered values (§7.3).
        ///
        /// - Parameter locale: The new effective locale (nil uses the backend default).
        func reload(locale: String?) {
            captureFieldValues() // snapshot current input before tearing down controls
            self.locale = locale
            load()
        }

        // MARK: - Loading

        private func load() {
            loadState = .loading
            renderState()

            let locale = self.locale
            let service = self.service
            let countryCode = model.country

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let list = try await service.countries(locale: locale)
                    let selected = countryCode ?? list.detectedCountry ?? list.countries.first?.code
                    var loadedConfig: AddressCountryConfig?
                    if let selected {
                        loadedConfig = try await service.countryConfig(countryCode: selected, locale: locale)
                    }
                    self.countries = list.countries
                    if self.model.country == nil { self.model.country = selected }
                    self.config = loadedConfig
                    self.loadState = .loaded
                } catch {
                    self.loadState = .failed
                }
                self.renderState()
                let finish = self.loadFinishedForTest
                self.loadFinishedForTest = nil
                finish?()
            }
        }

        /// Applies a country selection: snapshots current input, clears country-scoped code fields
        /// that no longer apply to the new country (so a stale subdivision code can't survive the
        /// rebuild), updates the model/title, and reloads that country's config. `state` is the only
        /// country-scoped code in the model; line1/city/postalCode are raw text and reasonably
        /// persist. `reload(locale:)` must NOT clear these — only a country change does.
        private func selectCountry(_ code: String, title: String, field: FloatingLabelMenuField?) {
            captureFieldValues()
            if model.country != code {
                model.state = nil
            }
            model.country = code
            field?.setSelected(title: title)
            reloadCountryConfig()
        }

        /// Reloads just the selected country's config (on a country change), preserving other values.
        private func reloadCountryConfig() {
            captureFieldValues()
            loadState = .loading
            renderState()

            let locale = self.locale
            let service = self.service
            let countryCode = model.country

            Task { @MainActor [weak self] in
                guard let self, let countryCode else { return }
                do {
                    self.config = try await service.countryConfig(countryCode: countryCode, locale: locale)
                    self.loadState = .loaded
                } catch {
                    self.loadState = .failed
                }
                self.renderState()
                let finish = self.loadFinishedForTest
                self.loadFinishedForTest = nil
                finish?()
            }
        }

        // MARK: - Rendering

        private func renderState() {
            skeletonView.isHidden = loadState != .loading
            errorContainer.isHidden = loadState != .failed
            contentStack.isHidden = loadState != .loaded

            guard loadState == .loaded else { return }
            rebuildFields()
        }

        /// Rebuilds the field controls from the current config, then re-applies stored values.
        private func rebuildFields() {
            let hadPostalError = postalErrorKey != nil
            contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            textFields.removeAll()
            postalErrorLabel = nil
            postalErrorKey = nil
            countryButton = nil
            stateButton = nil
            phoneField = nil

            contentStack.addArrangedSubview(makeCountryRow())

            if let config {
                let rows = AddressFormLayoutResolver.renderRows(config: config, collectName: options.collectName)
                for row in rows {
                    let fields = row.filter { field in
                        field.type != .country && (visibleFields?.contains(field.type) ?? true)
                    }
                    guard !fields.isEmpty else { continue }
                    contentStack.addArrangedSubview(makeRow(fields))
                }
            }

            if options.collectPhone {
                contentStack.addArrangedSubview(makePhoneRow())
            }

            // The new country has no postal field: drop the stale value rather than carry it along.
            if let config, config.fields[.postalCode] == nil { model.postalCode = nil }

            applyStoredValues()

            // After a country change / rebuild, re-check a typed or previously flagged postal code.
            if hadPostalError || !(textFields[.postalCode]?.text ?? "").isEmpty {
                _ = validate()
            }
        }

        private func makePhoneRow() -> UIView {
            let textField = FloatingLabelTextField(appearance: appearance)
            textField.title = localize("sunbay.address.phone")
            textField.autocorrectionType = .no
            textField.keyboardType = .phonePad
            textField.textContentType = .telephoneNumber
            textField.translatesAutoresizingMaskIntoConstraints = false
            KeyboardDismissal.installFormNavigation(on: textField)
            phoneField = textField
            return FieldContainerView(appearance: appearance, control: textField)
        }

        private func makeCountryRow() -> UIView {
            let field = FloatingLabelMenuField(
                appearance: appearance, title: localize("sunbay.address.country"))

            let actions = countries.map { country in
                UIAction(title: country.name) { [weak self] _ in
                    guard let self else { return }
                    self.selectCountry(country.code, title: country.name, field: field)
                }
            }
            field.setMenu(UIMenu(children: actions))
            if let code = model.country, let name = countries.first(where: { $0.code == code })?.name {
                field.setSelected(title: name)
            }
            countryButton = field

            return FieldContainerView(appearance: appearance, control: field)
        }

        private func makeRow(_ fields: [AddressFieldConfig]) -> UIView {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 8
            rowStack.distribution = .fillEqually
            // Top-align so a taller cell (postal field + inline error) does not stretch its siblings.
            rowStack.alignment = .top
            for field in fields {
                rowStack.addArrangedSubview(makeField(field))
            }
            return rowStack
        }

        private func makeField(_ field: AddressFieldConfig) -> UIView {
            if field.type == .state, let config, !config.subdivisions.isEmpty {
                return makeStateRow(field, subdivisions: config.subdivisions)
            }
            let textField = FloatingLabelTextField(appearance: appearance)
            textField.title = field.placeholder
            textField.autocorrectionType = .no
            textField.translatesAutoresizingMaskIntoConstraints = false
            if field.type == .postalCode {
                textField.keyboardType = .numbersAndPunctuation
            }
            KeyboardDismissal.installFormNavigation(on: textField)
            textFields[field.type] = textField
            let container = FieldContainerView(appearance: appearance, control: textField)
            guard field.type == .postalCode else { return container }

            // Postal cell: the field box with its inline error label below (CardFormView style).
            textField.addTarget(self, action: #selector(handlePostalEditingChanged), for: .editingChanged)
            let label = UILabel()
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            label.textColor = appearance.danger
            label.numberOfLines = 0
            label.isHidden = true
            postalErrorLabel = label
            let cell = UIStackView(arrangedSubviews: [container, label])
            cell.axis = .vertical
            cell.spacing = 4
            return cell
        }

        private func makeStateRow(_ field: AddressFieldConfig, subdivisions: [AddressSubdivision]) -> UIView {
            let menuField = FloatingLabelMenuField(appearance: appearance, title: field.placeholder)

            let actions = subdivisions.map { subdivision in
                UIAction(title: subdivision.name) { [weak self] _ in
                    self?.model.state = subdivision.code
                    menuField.setSelected(title: subdivision.name)
                }
            }
            menuField.setMenu(UIMenu(children: actions))
            if let code = model.state, let name = subdivisions.first(where: { $0.code == code })?.name {
                menuField.setSelected(title: name)
            }
            stateButton = menuField
            return FieldContainerView(appearance: appearance, control: menuField)
        }

        // MARK: - Value capture / restore (code-based, §7.3)

        /// Snapshots the current control values into the code/raw-text model before any teardown.
        private func captureFieldValues() {
            for (type, field) in textFields {
                let value = (field.text ?? "").trimmingCharacters(in: .whitespaces)
                let stored = value.isEmpty ? nil : value
                switch type {
                case .line1: model.line1 = stored
                case .line2: model.line2 = stored
                case .city: model.city = stored
                case .postalCode: model.postalCode = stored
                case .district: model.district = stored
                case .firstName: model.firstName = stored
                case .lastName: model.lastName = stored
                default: break
                }
            }
            if let phoneField {
                let value = (phoneField.text ?? "").trimmingCharacters(in: .whitespaces)
                model.phone = value.isEmpty ? nil : value
            }
            // country / state are captured eagerly in their menu actions.
        }

        /// Re-applies stored model values to the freshly rebuilt controls.
        private func applyStoredValues() {
            textFields[.line1]?.text = model.line1
            textFields[.line2]?.text = model.line2
            textFields[.city]?.text = model.city
            textFields[.postalCode]?.text = model.postalCode
            textFields[.district]?.text = model.district
            textFields[.firstName]?.text = model.firstName
            textFields[.lastName]?.text = model.lastName
            phoneField?.text = model.phone
        }

        // MARK: - Container / skeleton / error

        private func configureContainer() {
            contentStack.axis = .vertical
            contentStack.spacing = 12
            contentStack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(contentStack)

            skeletonView.backgroundColor = appearance.componentBackground
            skeletonView.layer.cornerRadius = appearance.cornerRadius
            skeletonView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(skeletonView)

            configureErrorContainer()
            errorContainer.translatesAutoresizingMaskIntoConstraints = false
            addSubview(errorContainer)

            for view in [contentStack, skeletonView, errorContainer] {
                NSLayoutConstraint.activate([
                    view.topAnchor.constraint(equalTo: topAnchor),
                    view.leadingAnchor.constraint(equalTo: leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: trailingAnchor),
                    view.bottomAnchor.constraint(equalTo: bottomAnchor),
                ])
            }
            skeletonView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        }

        private func configureErrorContainer() {
            errorLabel.text = localize("sunbay.address.loadError")
            errorLabel.font = appearance.cardFieldFont
            errorLabel.textColor = appearance.danger
            errorLabel.numberOfLines = 0
            errorLabel.textAlignment = .center
            errorLabel.translatesAutoresizingMaskIntoConstraints = false

            retryButton.setTitle(localize("sunbay.common.retry"), for: .normal)
            retryButton.titleLabel?.font = appearance.ctaFont
            retryButton.tintColor = appearance.primary
            retryButton.translatesAutoresizingMaskIntoConstraints = false
            retryButton.addTarget(self, action: #selector(handleRetry), for: .touchUpInside)

            let stack = UIStackView(arrangedSubviews: [errorLabel, retryButton])
            stack.axis = .vertical
            stack.spacing = 8
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            errorContainer.addSubview(stack)

            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: errorContainer.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: errorContainer.trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: errorContainer.topAnchor, constant: 16),
                stack.bottomAnchor.constraint(equalTo: errorContainer.bottomAnchor, constant: -16),
            ])
        }

        @objc private func handleRetry() {
            load()
        }

        // MARK: - Test seams

        /// Spins the main run loop until the in-flight load `Task` finishes rendering.
        func waitForLoadForTest(timeout: TimeInterval = 2.0) {
            let deadline = Date().addingTimeInterval(timeout)
            var done = false
            loadFinishedForTest = { done = true }
            while !done, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        }

        /// The text-field types currently rendered (names appear only when the options collect them).
        var renderedFieldTypesForTest: Set<AddressFieldType> { Set(textFields.keys) }

        /// The postal error message currently shown (the localized text), or nil when none is shown.
        var postalErrorMessageForTest: String? {
            guard let label = postalErrorLabel, !label.isHidden else { return nil }
            return label.text
        }

        /// Whether the first / last name row is collected.
        var hasNameFieldsForTest: Bool { options.collectName }

        /// Fills the model directly (bypassing the country menu and keystrokes), then re-applies it to
        /// the controls.
        func fillForTest(
            country: String, line1: String, postalCode: String, firstName: String? = nil, lastName: String? = nil,
            phone: String? = nil
        ) {
            model.country = country
            model.line1 = line1
            model.postalCode = postalCode
            model.firstName = firstName
            model.lastName = lastName
            model.phone = phone
            applyStoredValues()
        }

        /// Whether the phone field is currently rendered.
        var hasPhoneFieldForTest: Bool { phoneField != nil }

        /// Sets the phone field's value directly (bypassing keystrokes) for tests.
        func setPhoneForTest(_ value: String) {
            phoneField?.text = value
        }

        /// Sets a rendered text field's value directly (bypassing keystrokes) for tests.
        func setTextForTest(_ type: AddressFieldType, _ value: String) {
            textFields[type]?.text = value
        }

        /// Sets the postal-code field text directly (bypassing keystrokes) for tests.
        func setPostalCodeForTest(_ value: String) {
            textFields[.postalCode]?.text = value
            model.postalCode = value
        }

        /// Selects a subdivision by code (as the state menu action would) for tests.
        func selectStateForTest(_ code: String) {
            model.state = code
            if let name = config?.subdivisions.first(where: { $0.code == code })?.name {
                stateButton?.setSelected(title: name)
            }
        }

        /// Invokes the real country-selection logic for the given country code (the exact production
        /// code path, including stale-subdivision clearing), then reloads the country config.
        func selectCountryForTest(_ code: String) {
            let title = countries.first(where: { $0.code == code })?.name ?? code
            selectCountry(code, title: title, field: countryButton)
        }
    }
#endif
