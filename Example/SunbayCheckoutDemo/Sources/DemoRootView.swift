import Foundation
import SunbayCheckout
import SunbayCheckoutTestSupport

#if canImport(UIKit) && canImport(SwiftUI)
    import SwiftUI
    import UIKit

    // MARK: - Root view

    /// The demo configuration playground.
    ///
    /// A tabbed config screen (Pay / Options / Look) exposing every `DemoSettings` knob, a "Pay (sheet)"
    /// action that creates a real order through the local `Example/DevServer` and presents the SDK
    /// `PaymentSheet` against the selected backend, a standalone `ApplePayButton` section, and a
    /// last-outcome display. The environment is switchable (dev by default); there is no mock mode.
    ///
    /// Consumes only the SDK public API (`SunbayCheckout`, `CheckoutConfiguration`, `PaymentSheet`,
    /// `ApplePayButton`, `CheckoutOutcome`, `CheckoutError`) plus `DevSessionClient` from
    /// `SunbayCheckoutTestSupport`. No internal types, no `@testable`.
    ///
    /// Localization gate: the `Locale` picker writes into `CheckoutConfiguration.locale`, which the
    /// SDK uses to localize the PaymentSheet UI at runtime. Switching to `zh-CN` and presenting the
    /// sheet renders the SDK's Chinese strings (the app itself hand-writes no Chinese literals).
    struct DemoRootView: View {
        /// The live configuration surface driven by the playground controls.
        @State private var settings: DemoSettings = .default
        /// A readable description of the most recent checkout result.
        @State private var lastOutcome: String = "-"
        /// The most recent presentation state observed via `PaymentSheet.onStateChange`.
        @State private var lastState: String = "-"
        /// Diagnostic events received through `SunbayCheckout.onDiagnostic` (code, ignored names, reason only).
        @State private var diagnostics: [String] = []

        /// The Apple Pay merchant id baked into Info.plist (`SunbayDemoMerchantId`) by the Tuist
        /// manifest, so it always matches the entitlement. Falls back to the committed placeholder.
        private static let merchantId: String = {
            let value = Bundle.main.object(forInfoDictionaryKey: "SunbayDemoMerchantId") as? String
            return (value?.isEmpty == false ? value : nil) ?? "merchant.com.example.yourapp"
        }()

        var body: some View {
            TabView {
                tab("Pay", systemImage: "creditcard") {
                    backendSection
                    orderSection
                    paymentSheetSection
                    applePaySection
                    outcomeSection
                }
                tab("Options", systemImage: "slider.horizontal.3") {
                    methodsSection
                    addressSection
                    cofSection
                }
                tab("Look", systemImage: "paintbrush") {
                    localeSection
                    appearanceSection
                }
            }
        }

        /// One tab: its own navigation stack around a form, so each tab keeps its scroll position.
        private func tab<Content: View>(
            _ title: String, systemImage: String, @ViewBuilder content: () -> Content
        ) -> some View {
            NavigationView {
                Form { content() }
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .navigationViewStyle(.stack)
            .tabItem { Label(title, systemImage: systemImage) }
        }

        // MARK: - Backend

        /// Environment and local session-server URL.
        private var backendSection: some View {
            Section {
                Picker("Environment", selection: $settings.environment) {
                    ForEach(DemoSettings.DemoEnvironment.allCases) { env in
                        Text(env.label).tag(env)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Server URL")
                    Spacer()
                    TextField("http://127.0.0.1:8095", text: $settings.devServerURL)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
            } header: {
                Text("Backend")
            } footer: {
                Text("The environment selects the SDK backend and the credentials the local DevServer uses (TEST_ / PROD_ variables in .env.local). Prod creates real orders.")
            }
        }

        // MARK: - Order

        private var orderSection: some View {
            Section {
                HStack {
                    Text("Amount (minor units, USD)")
                    Spacer()
                    TextField("105", text: amountText)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                }
                Toggle("Order requires billing address", isOn: $settings.orderRequiresBillingAddress)
                Toggle("Order requires shipping address", isOn: $settings.orderRequiresShippingAddress)
            } header: {
                Text("Order")
            } footer: {
                Text("The server receives the amount in major units (minor units / 100). The \"requires\" toggles set the session's collect flags; see Options for how the sheet shows the address forms.")
            }
        }

        // MARK: - Config sections

        private var localeSection: some View {
            Section {
                Picker("Locale", selection: $settings.locale) {
                    ForEach(DemoSettings.DemoLocale.allCases) { loc in
                        Text(loc.label).tag(loc)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Locale")
            } footer: {
                Text("Drives CheckoutConfiguration.locale. Switch to zh-CN, then present the sheet to see the SDK render its Chinese UI strings.")
            }
        }

        private var appearanceSection: some View {
            Section {
                Picker("Preset", selection: $settings.appearancePreset) {
                    ForEach(DemoSettings.DemoAppearancePreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                Picker("Color scheme", selection: $settings.colorScheme) {
                    ForEach(DemoSettings.DemoColorScheme.allCases) { scheme in
                        Text(scheme.label).tag(scheme)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Presets mirror the prototype's Customize lab (primary color, corner radius, express position, density). The color-scheme control overrides the preset's scheme when not Automatic.")
            }
        }

        private var addressSection: some View {
            Section {
                Picker("Billing address", selection: $settings.billingAddressMode) {
                    ForEach(DemoSettings.DemoAddressMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                Picker("Shipping address", selection: $settings.shippingAddressMode) {
                    ForEach(DemoSettings.DemoAddressMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Pass a host billing address", isOn: $settings.passHostBillingAddress)
                Toggle("Pass a host shipping address", isOn: $settings.passHostShippingAddress)
            } header: {
                Text("Address collection")
            } footer: {
                Text("Automatic follows the session flag set by the \"Order requires\" toggles on the Pay tab (on: full form, off: hidden); Simple, Full and Off ignore it. The \"Pass a host ...\" toggles supply a fixed, complete US test address. A host address is used only when the session collects that kind and the address is complete; Automatic then hides the form for it. A form that is shown wins over the host address.")
            }
        }

        private var methodsSection: some View {
            Section {
                Toggle("Hide Apple Pay", isOn: $settings.hideApplePay)
                Toggle("Hide Card", isOn: $settings.hideCard)
            } header: {
                Text("Payment methods")
            } footer: {
                Text("Maps to PaymentMethodFilter(hide:). Hiding Card also hides saved cards. Hiding every method makes present() fail with NO_PAYMENT_METHOD_AVAILABLE.")
            }
        }

        private var cofSection: some View {
            Section {
                Toggle("Card on file enabled", isOn: $settings.cardOnFileEnabled)
                Toggle("Pre-tick save card", isOn: $settings.preTickSaveCard)
            } header: {
                Text("Saved cards")
            } footer: {
                Text("The host switch can only disable saved cards; the session must also allow them. \"Pre-tick save card\" only sets the checkbox's initial state.")
            }
        }

        // MARK: - Action sections

        private var paymentSheetSection: some View {
            Section("PaymentSheet (L1 black-box)") {
                Text("Creates an order session, then presents the SDK sheet: new-card form, 'Save this card', saved cards (COF one-tap), and an Apple Pay entry row.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                PaySheetButton(
                    checkout: makeCheckout(),
                    request: sessionRequest,
                    onOutcome: { lastOutcome = describe($0) },
                    onState: { lastState = describeState($0) }
                )
            }
        }

        private var applePaySection: some View {
            Section("Standalone ApplePayButton (L3)") {
                StandaloneApplePaySection(
                    checkout: makeCheckout(),
                    request: sessionRequest,
                    onResult: { lastOutcome = describe($0) }
                )
                // A session belongs to one environment: switching it drops the bound button.
                .id(settings.environment)
            }
        }

        private var outcomeSection: some View {
            Section("Last outcome") {
                Text(lastOutcome).font(.body.monospaced())
                HStack {
                    Text("Last state")
                    Spacer()
                    Text(lastState).font(.body.monospaced()).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Diagnostics")
                    Spacer()
                    Button("Clear") { diagnostics = [] }
                        .disabled(diagnostics.isEmpty)
                }
                if diagnostics.isEmpty {
                    Text("-").font(.footnote.monospaced()).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.footnote.monospaced())
                    }
                }
            }
        }

        // MARK: - Bindings

        /// Binds the amount (Int64) as editable text, ignoring non-numeric input.
        private var amountText: Binding<String> {
            Binding(
                get: { String(settings.amountMinorUnits) },
                set: { settings.amountMinorUnits = Int64($0.filter(\.isNumber)) ?? 0 }
            )
        }

        // MARK: - Settings -> SDK wiring

        /// The dev-server session request derived from the current settings.
        private var sessionRequest: DevSessionRequest {
            DevSessionRequest(
                serverURL: URL(string: settings.devServerURL),
                environment: settings.environment.serverName,
                amountMajorUnits: Double(settings.amountMinorUnits) / 100,
                collectBillingAddress: settings.orderRequiresBillingAddress,
                collectShippingAddress: settings.orderRequiresShippingAddress,
                hostBillingAddress: settings.passHostBillingAddress ? Self.testBillingAddress : nil,
                hostShippingAddress: settings.passHostShippingAddress ? Self.testShippingAddress : nil
            )
        }

        /// Fixed US test address handed to the sheet when "Pass a host billing address" is on.
        private static let testBillingAddress = AddressInput(
            country: "US", line1: "1 Test St", city: "San Jose", state: "CA",
            postalCode: "95112", firstName: "Test", lastName: "User"
        )

        /// Fixed US test address (with names and phone) handed to the sheet when "Pass a host shipping address" is on.
        private static let testShippingAddress = AddressInput(
            country: "US", line1: "2 Test Ave", city: "San Jose", state: "CA",
            postalCode: "95113", firstName: "Test", lastName: "Recipient", phone: "4085550100"
        )

        /// The SDK environment matching the selected demo environment.
        private var sdkEnvironment: CheckoutConfiguration.Environment {
            switch settings.environment {
            case .dev: return .dev
            case .test: return .test
            case .prod: return .production
            }
        }

        /// The payment-method filter derived from the hide toggles.
        private var methodFilter: PaymentMethodFilter {
            var hide: [PaymentMethodID] = []
            if settings.hideApplePay { hide.append(.applePay) }
            if settings.hideCard { hide.append(.card) }
            return PaymentMethodFilter(hide: hide)
        }

        /// One readable line for a diagnostic: code, ignored names and reason only (never values).
        private static func describe(_ event: CheckoutDiagnostic) -> String {
            switch event {
            case let .warning(warning):
                return "\(warning.code.rawValue) [\(warning.ignored.joined(separator: ", "))] \(warning.reason)"
            case let .error(error, _):
                return "ERROR \(error.code) (\(error.category))"
            }
        }

        /// Assembles the public SDK entry point for the selected environment (real backend adapters).
        private func makeCheckout() -> SunbayCheckout {
            let config = CheckoutConfiguration(
                environment: sdkEnvironment,
                applePayMerchantId: Self.merchantId,
                appearance: makeAppearance(),
                locale: settings.locale.bcp47,
                cardOnFile: CardOnFileOptions(isEnabled: settings.cardOnFileEnabled,
                                              saveByDefault: settings.preTickSaveCard),
                paymentMethodFilter: methodFilter
            )
            let checkout = SunbayCheckout(configuration: config)
            let sink = $diagnostics
            checkout.onDiagnostic = { event in
                sink.wrappedValue.append(Self.describe(event))
            }
            return checkout
        }

        /// Builds an `Appearance` from the preset + scheme + address-mode knobs.
        ///
        /// The preset mirrors the prototype's Customize lab (primary color, corner radius, express
        /// position, density, base scheme). The explicit color-scheme control overrides the preset's
        /// scheme only when it is not `.automatic`, so the segmented control stays meaningful on top
        /// of a preset. Preset colors use the SDK's public `UIColor(sunbayHex:)` convenience with
        /// hardcoded valid literals (the `?? .systemOrange` fallback is unreachable for these).
        private func makeAppearance() -> Appearance {
            var appearance = Appearance()

            switch settings.appearancePreset {
            case .brandDefault:
                // Brand orange #ff6000; leave built-in corner radius / express-top / comfortable.
                appearance.colors.primary = UIColor(sunbayHex: "#ff6000") ?? .systemOrange
            case .sharpBlueExpressBottom:
                appearance.colors.primary = UIColor(sunbayHex: "#2563eb") ?? .systemBlue
                appearance.cornerRadius = 3
                appearance.expressPosition = .bottom
                appearance.density = .compact
            case .roundGreenDark:
                appearance.colors.primary = UIColor(sunbayHex: "#16a34a") ?? .systemGreen
                appearance.cornerRadius = 20
                appearance.colorScheme = .dark
            }

            switch settings.colorScheme {
            case .automatic:
                break // keep the preset's scheme
            case .light:
                appearance.colorScheme = .light
            case .dark:
                appearance.colorScheme = .dark
            }

            appearance.billingAddressMode = addressMode(settings.billingAddressMode)
            appearance.shippingAddressMode = addressMode(settings.shippingAddressMode)
            return appearance
        }

        /// Maps a demo address-mode knob to the SDK's `Appearance.AddressCollectionMode`.
        private func addressMode(_ mode: DemoSettings.DemoAddressMode) -> Appearance.AddressCollectionMode {
            switch mode {
            case .automatic: return .automatic
            case .simple: return .simple
            case .full: return .full
            case .off: return .off
            }
        }

        /// Maps a `CheckoutOutcome` to readable copy (contains no sensitive data).
        private func describe(_ outcome: CheckoutOutcome) -> String {
            switch outcome {
            case let .succeeded(txnId):
                return "succeeded(txnId: \(txnId))"
            case let .failed(txnId, error):
                return "failed(txnId: \(txnId ?? "nil"), code: \(error.code), \(error.category))"
            case .canceled:
                return "canceled"
            case let .pending(txnId):
                return "pending(txnId: \(txnId ?? "nil"))"
            case let .unknown(sessionId):
                return "unknown(sessionId: \(sessionId)) -> retrievePayment()"
            }
        }

        /// Maps a `CheckoutPresentationState` to readable copy (for manual observation of onStateChange).
        private func describeState(_ state: CheckoutPresentationState) -> String {
            switch state {
            case .editing: return "editing"
            case .processing: return "processing"
            case .succeeded: return "succeeded"
            case .failed: return "failed"
            }
        }
    }

    // MARK: - Dev session request

    /// The server URL text is not a valid URL.
    struct InvalidServerURL: Error {}

    /// What the dev server needs to create an order session. `serverURL` is nil for a malformed URL.
    struct DevSessionRequest {
        let serverURL: URL?
        /// Server-side environment name (`dev`, `test`, `prod`).
        let environment: String
        let amountMajorUnits: Double
        let collectBillingAddress: Bool
        let collectShippingAddress: Bool
        /// Host-provided billing address for `PaymentSheet(billingAddress:)` (nil: let the form collect it).
        let hostBillingAddress: AddressInput?
        /// Host-provided shipping address for `PaymentSheet(shippingAddress:)` (nil: let the form collect it).
        let hostShippingAddress: AddressInput?

        /// Creates the session through the dev server. Throws `DevSessionError` with a readable message.
        func create() async throws -> DevSession {
            guard let serverURL else { throw InvalidServerURL() }
            return try await DevSessionClient(serverURL: serverURL).createSession(
                amountMajorUnits: amountMajorUnits,
                collectBillingAddress: collectBillingAddress,
                collectShippingAddress: collectShippingAddress,
                environment: environment
            )
        }
    }

    // MARK: - PaymentSheet wrapper (SwiftUI button -> presents the UIKit payment page)

    /// A SwiftUI button that creates a dev session, presents the public `PaymentSheet` on the
    /// frontmost view controller and passes back the returned `CheckoutOutcome`.
    struct PaySheetButton: View {
        let checkout: SunbayCheckout
        let request: DevSessionRequest
        let onOutcome: (CheckoutOutcome) -> Void
        let onState: (CheckoutPresentationState) -> Void
        @State private var errorMessage: String?
        @State private var isBusy = false

        var body: some View {
            VStack(alignment: .leading) {
                Button("Pay (sheet)") {
                    guard !isBusy, let presenter = topViewController() else { return }
                    errorMessage = nil
                    isBusy = true
                    Task { @MainActor in
                        defer { isBusy = false }
                        let session: DevSession
                        do {
                            session = try await request.create()
                        } catch {
                            errorMessage = describeSessionError(error)
                            return
                        }
                        let sheet = PaymentSheet(
                            checkout: checkout,
                            sessionId: session.sessionId,
                            customerAccessSecret: session.customerAccessSecret,
                            checkoutClientSecret: session.checkoutClientSecret,
                            billingAddress: request.hostBillingAddress,
                            shippingAddress: request.hostShippingAddress
                        )
                        sheet.onStateChange = onState
                        let outcome = await sheet.present(from: presenter)
                        onOutcome(outcome)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundColor(.red)
                }
            }
        }
    }

    // MARK: - Standalone ApplePayButton section

    /// "Create session" then show the standalone `ApplePayButton` bound to that session.
    struct StandaloneApplePaySection: View {
        let checkout: SunbayCheckout
        let request: DevSessionRequest
        let onResult: (CheckoutOutcome) -> Void
        @State private var session: DevSession?
        @State private var errorMessage: String?
        @State private var available = false
        @State private var isBusy = false

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Button("Create session") {
                    guard !isBusy else { return }
                    errorMessage = nil
                    session = nil
                    isBusy = true
                    Task { @MainActor in
                        defer { isBusy = false }
                        do {
                            session = try await request.create()
                        } catch {
                            errorMessage = describeSessionError(error)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
                if let session {
                    Text(available
                        ? "Available - tap to drive the wallet authorization end-to-end (confirmWallet)."
                        : "Hidden/unavailable (device cannot make payments or merchant-id not configured).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ApplePayButtonView(
                        checkout: checkout,
                        sessionId: session.sessionId,
                        checkoutClientSecret: session.checkoutClientSecret,
                        onResult: onResult,
                        onAvailabilityChange: { available = $0 }
                    )
                    .id(session.sessionId)
                    .frame(height: 48)
                } else if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundColor(.red)
                } else {
                    Text("Creates an order session first; the button is then bound to it. Apple Pay needs a real device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Readable session-creation failure copy (never includes secrets or response bodies).
    private func describeSessionError(_ error: Error) -> String {
        if error is InvalidServerURL {
            return "Invalid server URL"
        }
        if let error = error as? DevSessionError {
            return error.description
        }
        return "Dev server session failed: \(error.localizedDescription)"
    }

    // MARK: - ApplePayButton wrapper (UIKit control -> SwiftUI)

    /// Bridges the public `ApplePayButton` (UIControl) into SwiftUI, wiring `onResult` and `onAvailabilityChange`.
    struct ApplePayButtonView: UIViewRepresentable {
        let checkout: SunbayCheckout
        let sessionId: String
        let checkoutClientSecret: String
        let onResult: (CheckoutOutcome) -> Void
        let onAvailabilityChange: (Bool) -> Void

        func makeUIView(context: Context) -> ApplePayButton {
            let button = ApplePayButton(
                checkout: checkout,
                sessionId: sessionId,
                style: .automatic,
                checkoutClientSecret: checkoutClientSecret
            )
            button.onResult = onResult
            button.onAvailabilityChange = onAvailabilityChange
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return button
        }

        func updateUIView(_ uiView: ApplePayButton, context: Context) {}
    }

    // MARK: - Get the top VC (for present)

    /// Returns the frontmost view controller of the current key window (for modal presentation).
    @MainActor
    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
            ?? scenes.first as? UIWindowScene
        guard var top = windowScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? windowScene?.windows.first?.rootViewController
        else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

#endif
