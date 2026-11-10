import Foundation
import SunbayCheckout
import SunbayCheckoutTestSupport

#if canImport(UIKit) && canImport(SwiftUI)
    import SwiftUI
    import UIKit

    // MARK: - Root view

    /// The demo configuration playground.
    ///
    /// A Stripe-style config screen: a `Form` exposing every `DemoSettings` knob, a "Pay (sheet)"
    /// action that creates a real dev order through the local `Example/DevServer` and presents the SDK
    /// `PaymentSheet` against the Dev backend, a standalone `ApplePayButton` section, and a
    /// last-outcome display. The environment is fixed to `.dev`; there is no mock mode.
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

        /// The Apple Pay merchant id baked into Info.plist (`SunbayDemoMerchantId`) by the Tuist
        /// manifest, so it always matches the entitlement. Falls back to the committed placeholder.
        private static let merchantId: String = {
            let value = Bundle.main.object(forInfoDictionaryKey: "SunbayDemoMerchantId") as? String
            return (value?.isEmpty == false ? value : nil) ?? "merchant.com.example.yourapp"
        }()

        var body: some View {
            NavigationView {
                Form {
                    devServerSection
                    localeSection
                    appearanceSection
                    addressSection
                    amountSection
                    cofSection
                    paymentSheetSection
                    applePaySection
                    outcomeSection
                }
                .navigationTitle("Sunbay Checkout Demo")
                .safeAreaInset(edge: .top, spacing: 0) { devOnlyBanner }
            }
            .navigationViewStyle(.stack)
        }

        // MARK: - Dev server

        /// Persistent warning shown on screen: sessions come from a dev server that holds the API key.
        private var devOnlyBanner: some View {
            Text("DEV ONLY: sessions are created by a local dev server that holds your API key. In production, create the session in your own backend.")
                .font(.footnote.bold())
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red)
        }

        /// Dev server URL. The environment is fixed to Dev.
        private var devServerSection: some View {
            Section {
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
                Text("Backend (Dev)")
            } footer: {
                Text("Pays against the Dev backend (environment is fixed). Start Example/DevServer first; it creates the order session.")
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
                Toggle("Order requires billing address", isOn: $settings.orderRequiresBillingAddress)
                Toggle("Order requires shipping address", isOn: $settings.orderRequiresShippingAddress)
                Toggle("Pass a host billing address", isOn: $settings.passHostBillingAddress)
            } header: {
                Text("Address collection")
            } footer: {
                Text("The \"Order requires\" toggles set the dev-server session flags. Automatic follows the session flag (on: full form, off: hidden); Simple, Full and Off ignore it. \"Pass a host billing address\" supplies a fixed US test address to the sheet, which wins over the form.")
            }
        }

        private var amountSection: some View {
            Section {
                HStack {
                    Text("Currency")
                    Spacer()
                    Text("USD").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Minor units")
                    Spacer()
                    TextField("105", text: amountText)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                }
            } header: {
                Text("Amount")
            } footer: {
                Text("The currency is fixed to USD. The dev server receives the amount in major units (minor units / 100).")
            }
        }

        private var cofSection: some View {
            Section {
                Toggle("Card on file enabled", isOn: $settings.cardOnFileEnabled)
                Toggle("Pre-tick save card", isOn: $settings.preTickSaveCard)
            } footer: {
                Text("The host switch can only disable saved cards; the session must also allow them. \"Pre-tick save card\" only sets the checkbox's initial state.")
            }
        }

        // MARK: - Action sections

        private var paymentSheetSection: some View {
            Section("PaymentSheet (L1 black-box)") {
                Text("Creates a Dev order session, then presents the SDK sheet: new-card form, 'Save this card', saved cards (COF one-tap), and an Apple Pay entry row.")
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
                amountMajorUnits: Double(settings.amountMinorUnits) / 100,
                collectBillingAddress: settings.orderRequiresBillingAddress,
                collectShippingAddress: settings.orderRequiresShippingAddress,
                hostBillingAddress: settings.passHostBillingAddress ? Self.testBillingAddress : nil
            )
        }

        /// Fixed US test address handed to the sheet when "Pass a host billing address" is on.
        private static let testBillingAddress = AddressInput(
            country: "US", line1: "1 Test St", city: "San Jose", state: "CA",
            postalCode: "95112", firstName: "Test", lastName: "User"
        )

        /// Assembles the public SDK entry point against the Dev environment (real backend adapters).
        private func makeCheckout() -> SunbayCheckout {
            let config = CheckoutConfiguration(
                environment: .dev,
                applePayMerchantId: Self.merchantId,
                appearance: makeAppearance(),
                locale: settings.locale.bcp47,
                cardOnFile: CardOnFileOptions(isEnabled: settings.cardOnFileEnabled,
                                              saveByDefault: settings.preTickSaveCard)
            )
            return SunbayCheckout(configuration: config)
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
        let amountMajorUnits: Double
        let collectBillingAddress: Bool
        let collectShippingAddress: Bool
        /// Host-provided billing address for `PaymentSheet(billingAddress:)` (nil: let the form collect it).
        let hostBillingAddress: AddressInput?

        /// Creates the session through the dev server. Throws `DevSessionError` with a readable message.
        func create() async throws -> DevSession {
            guard let serverURL else { throw InvalidServerURL() }
            return try await DevSessionClient(serverURL: serverURL).createSession(
                amountMajorUnits: amountMajorUnits,
                collectBillingAddress: collectBillingAddress,
                collectShippingAddress: collectShippingAddress
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
                            billingAddress: request.hostBillingAddress
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
                    Text("Creates a Dev order session first; the button is then bound to it. Apple Pay needs a real device.")
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
