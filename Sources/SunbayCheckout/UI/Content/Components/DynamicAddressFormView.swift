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
    /// state field is a subdivisions dropdown; the postal field is validated against the backend
    /// `pattern`. No Google autocomplete, no postal→state lookup.
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    final class DynamicAddressFormView: UIView {
        private let appearance: ResolvedAppearance
        private let localize: (String) -> String
        private let service: any AddressMetadataService

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

        // Field controls keyed by type (rebuilt on each render).
        private var textFields: [AddressFieldType: UITextField] = [:]
        private var countryButton: UIButton?
        private var stateButton: UIButton?

        // Test seam: a continuation completed when the in-flight load finishes (success or failure).
        private var loadFinishedForTest: (() -> Void)?

        /// Creates the dynamic address form and starts the initial fetch.
        ///
        /// - Parameters:
        ///   - appearance: The resolved appearance providing colors, fonts, corner radius, border width.
        ///   - localize: The localization closure (error / retry copy; field labels come from the backend).
        ///   - service: The address-metadata service (host-injected; mock or real adapter).
        ///   - locale: The effective locale for the initial fetch (nil uses the backend default).
        init(
            appearance: ResolvedAppearance,
            localize: @escaping (String) -> String,
            service: any AddressMetadataService,
            locale: String?
        ) {
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
            return model
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
            contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            textFields.removeAll()
            countryButton = nil
            stateButton = nil

            contentStack.addArrangedSubview(makeCountryRow())

            if let config {
                let rows = AddressFormLayoutResolver.renderRows(config: config, collectName: false)
                for row in rows {
                    let fields = row.filter { $0.type != .country }
                    guard !fields.isEmpty else { continue }
                    contentStack.addArrangedSubview(makeRow(fields))
                }
            }

            applyStoredValues()
        }

        private func makeCountryRow() -> UIView {
            let button = UIButton(type: .system)
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.font = appearance.cardFieldFont
            button.setTitleColor(appearance.text, for: .normal)
            button.translatesAutoresizingMaskIntoConstraints = false

            let actions = countries.map { country in
                UIAction(title: country.name) { [weak self] _ in
                    guard let self else { return }
                    self.captureFieldValues()
                    self.model.country = country.code
                    button.setTitle(country.name, for: .normal)
                    self.reloadCountryConfig()
                }
            }
            button.menu = UIMenu(children: actions)
            button.showsMenuAsPrimaryAction = true
            if let code = model.country, let name = countries.first(where: { $0.code == code })?.name {
                button.setTitle(name, for: .normal)
            } else {
                button.setTitle(localize("sunbay.address.country"), for: .normal)
            }
            countryButton = button

            let label = config?.fields[.country]?.label ?? localize("sunbay.address.country")
            return makeFieldContainer(label: label, control: button)
        }

        private func makeRow(_ fields: [AddressFieldConfig]) -> UIView {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 8
            rowStack.distribution = .fillEqually
            for field in fields {
                rowStack.addArrangedSubview(makeField(field))
            }
            return rowStack
        }

        private func makeField(_ field: AddressFieldConfig) -> UIView {
            if field.type == .state, let config, !config.subdivisions.isEmpty {
                return makeStateRow(field, subdivisions: config.subdivisions)
            }
            let textField = UITextField()
            textField.placeholder = field.placeholder
            textField.font = appearance.cardFieldFont
            textField.textColor = appearance.text
            textField.autocorrectionType = .no
            textField.translatesAutoresizingMaskIntoConstraints = false
            if field.type == .postalCode {
                textField.keyboardType = .numbersAndPunctuation
            }
            textFields[field.type] = textField
            return makeFieldContainer(label: field.label, control: textField)
        }

        private func makeStateRow(_ field: AddressFieldConfig, subdivisions: [AddressSubdivision]) -> UIView {
            let button = UIButton(type: .system)
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.font = appearance.cardFieldFont
            button.setTitleColor(appearance.text, for: .normal)
            button.translatesAutoresizingMaskIntoConstraints = false

            let actions = subdivisions.map { subdivision in
                UIAction(title: subdivision.name) { [weak self] _ in
                    self?.model.state = subdivision.code
                    button.setTitle(subdivision.name, for: .normal)
                }
            }
            button.menu = UIMenu(children: actions)
            button.showsMenuAsPrimaryAction = true
            if let code = model.state, let name = subdivisions.first(where: { $0.code == code })?.name {
                button.setTitle(name, for: .normal)
            } else {
                button.setTitle(field.placeholder, for: .normal)
            }
            stateButton = button
            return makeFieldContainer(label: field.label, control: button)
        }

        private func makeFieldContainer(label: String, control: UIView) -> UIView {
            let container = UIView()
            container.backgroundColor = appearance.componentBackground
            container.layer.cornerRadius = appearance.cornerRadius
            container.layer.borderWidth = max(appearance.borderWidth, 1)
            container.layer.borderColor = appearance.border.cgColor

            control.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(control)
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                control.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                control.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
                control.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
                container.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            ])
            return container
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

        /// Sets the postal-code field text directly (bypassing keystrokes) for tests.
        func setPostalCodeForTest(_ value: String) {
            textFields[.postalCode]?.text = value
            model.postalCode = value
        }
    }
#endif
