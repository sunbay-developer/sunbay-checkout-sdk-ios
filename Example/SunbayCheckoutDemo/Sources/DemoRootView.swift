import Foundation
import SunbayCheckout
import SunbayCheckoutMocks

#if canImport(UIKit) && canImport(SwiftUI)
    import SwiftUI
    import UIKit

    // MARK: - Root view

    /// The demo configuration playground.
    ///
    /// A Stripe-style config screen: a `Form` exposing every `DemoSettings` knob, a "Pay (sheet)"
    /// action that maps the settings into a `CheckoutConfiguration` + scripted `SunbayCheckoutMocks`
    /// services and presents the SDK `PaymentSheet`, a standalone `ApplePayButton` section, and a
    /// last-outcome display.
    ///
    /// Consumes only the SDK public API (`SunbayCheckout`, `CheckoutConfiguration`, `PaymentSheet`,
    /// `ApplePayButton`, `CheckoutOutcome`, `CheckoutError`) plus the public `SunbayCheckoutMocks`
    /// doubles (`ScriptablePaymentService`, `ScriptableCofService`, `DemoSessionFactory`,
    /// `DemoRSAKey`). No internal types, no `@testable`.
    ///
    /// Localization gate: the `Locale` picker writes into `CheckoutConfiguration.locale`, which the
    /// SDK uses to localize the PaymentSheet UI at runtime. Switching to `zh-CN` and presenting the
    /// sheet renders the SDK's Chinese strings (the app itself hand-writes no Chinese literals).
    struct DemoRootView: View {
        /// The live configuration surface driven by the playground controls.
        @State private var settings: DemoSettings = .default
        /// A readable description of the most recent checkout result.
        @State private var lastOutcome: String = "-"
        /// Availability of the standalone ApplePayButton (onAvailabilityChange drives the hint copy).
        @State private var applePayAvailable = false

        // Fixed demo session identifier and COF credential (mock, not confidential).
        private let sessionId = "demo_session_001"
        private let customerAccessSecret = "demo_secret"

        var body: some View {
            NavigationView {
                Form {
                    environmentSection
                    localeSection
                    amountSection
                    methodsSection
                    cofSection
                    scenarioSection
                    paymentSheetSection
                    applePaySection
                    outcomeSection
                }
                .navigationTitle("Sunbay Checkout Demo")
            }
            .navigationViewStyle(.stack)
        }

        // MARK: - Config sections

        private var environmentSection: some View {
            Section("Environment") {
                Picker("Environment", selection: $settings.environment) {
                    ForEach(DemoSettings.DemoEnvironment.allCases) { env in
                        Text(env.label).tag(env)
                    }
                }
                .pickerStyle(.segmented)
            }
        }

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

        private var amountSection: some View {
            Section("Amount") {
                HStack {
                    Text("Currency")
                    Spacer()
                    TextField("USD", text: $settings.currencyCode)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                }
                HStack {
                    Text("Minor units")
                    Spacer()
                    TextField("4299", text: amountText)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                }
            }
        }

        private var methodsSection: some View {
            Section("Payment methods") {
                ForEach(DemoSettings.DemoMethod.allCases) { method in
                    Toggle(method.label, isOn: methodBinding(method))
                }
            }
        }

        private var cofSection: some View {
            Section {
                Toggle("COF enabled (saved cards)", isOn: $settings.cofEnabled)
            } footer: {
                Text("When on and a customerAccessSecret is passed, the sheet lists the mock saved cards for one-tap pay.")
            }
        }

        private var scenarioSection: some View {
            Section("Scenario (mock submit result)") {
                Picker("Scenario", selection: $settings.scenario) {
                    ForEach(DemoSettings.DemoScenario.allCases) { scenario in
                        Text(scenario.label).tag(scenario)
                    }
                }
                .pickerStyle(.menu)
            }
        }

        // MARK: - Action sections

        private var paymentSheetSection: some View {
            Section("PaymentSheet (L1 black-box)") {
                Text("Presents the SDK sheet: new-card form, 'Save this card', the mock saved cards (COF one-tap), and an Apple Pay entry row.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                PaySheetButton(
                    checkout: makeCheckout(),
                    sessionId: sessionId,
                    customerAccessSecret: settings.cofEnabled ? customerAccessSecret : nil,
                    onOutcome: { lastOutcome = describe($0) }
                )
            }
        }

        private var applePaySection: some View {
            Section("Standalone ApplePayButton (L3)") {
                Text(applePayAvailable
                    ? "Available - tap to drive the wallet authorization end-to-end (confirmWallet)."
                    : "Hidden/unavailable (device cannot make payments, merchant-id not configured, or Apple Pay method off).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ApplePayButtonView(
                    checkout: makeCheckout(),
                    sessionId: sessionId,
                    onResult: { lastOutcome = describe($0) },
                    onAvailabilityChange: { applePayAvailable = $0 }
                )
                .frame(height: 48)
            }
        }

        private var outcomeSection: some View {
            Section("Last outcome") {
                Text(lastOutcome).font(.body.monospaced())
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

        /// Binds one payment-method toggle into the `methods` set.
        private func methodBinding(_ method: DemoSettings.DemoMethod) -> Binding<Bool> {
            Binding(
                get: { settings.methods.contains(method) },
                set: { isOn in
                    if isOn {
                        settings.methods.insert(method)
                    } else {
                        settings.methods.remove(method)
                    }
                }
            )
        }

        // MARK: - Settings -> SDK wiring

        /// Assembles a public SDK entry point from the current settings and the scripted mock services.
        ///
        /// Maps `DemoSettings` into a `CheckoutConfiguration` (environment + locale + placeholder
        /// merchant id) and injects `ScriptablePaymentService` / `ScriptableCofService` from
        /// `SunbayCheckoutMocks` via the public `SunbayCheckout(configuration:paymentService:cofService:)`
        /// seam. The scripted session and submit snapshots reflect the amount/methods/COF/scenario knobs.
        private func makeCheckout() -> SunbayCheckout {
            let config = CheckoutConfiguration(
                environment: settings.environment.configurationValue,
                applePayMerchantId: "merchant.com.sunbay.demo",
                locale: settings.locale.bcp47
            )
            return SunbayCheckout(
                configuration: config,
                paymentService: makePaymentService(),
                cofService: makeCofService()
            )
        }

        /// Builds a scripted `PaymentService` reflecting the amount/methods/COF/scenario knobs.
        private func makePaymentService() -> ScriptablePaymentService {
            let service = ScriptablePaymentService()
            let methodKinds = Set(settings.methods.map(\.kind))
            service.stubSession(
                DemoSessionFactory.make(
                    id: sessionId,
                    amount: Amount(
                        minorUnits: settings.amountMinorUnits,
                        currencyCode: settings.currencyCode
                    ),
                    methods: methodKinds,
                    cofEnabled: settings.cofEnabled
                )
            )

            let txnId = "demo_txn_001"
            switch settings.scenario {
            case .succeeded:
                service.stubSubmit([PaymentSnapshot(sessionId: sessionId, status: .succeeded, txnId: txnId)])
            case .failed:
                service.stubSubmit([PaymentSnapshot(sessionId: sessionId, status: .failed, txnId: txnId)])
            case .pending:
                service.stubSubmit([PaymentSnapshot(sessionId: sessionId, status: .initial, txnId: txnId)])
            case .requiresAction:
                service.stubSubmit([PaymentSnapshot(sessionId: sessionId, status: .requiresAction, txnId: txnId)])
            case .networkTimeout:
                // Submit throws -> Core enters unknown (no blind retry). getResult recovers to succeeded.
                service.stubSubmitError(DemoNetworkUnavailable())
            }
            // Recovery query for the unknown branch always resolves to a confirmed terminal success.
            service.stubGetResult([PaymentSnapshot(sessionId: sessionId, status: .succeeded, txnId: "demo_txn_recovered")])
            return service
        }

        /// Builds a scripted `CofService` with two mock saved cards.
        private func makeCofService() -> ScriptableCofService {
            let service = ScriptableCofService()
            service.stubCards([
                SavedCard(id: "pm_demo_visa", brand: "visa", last4: "4242", expMonth: 12, expYear: 2029),
                SavedCard(id: "pm_demo_mc", brand: "mastercard", last4: "4444", expMonth: 8, expYear: 2028),
            ])
            return service
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
    }

    /// The "network unavailable" error used by the `networkTimeout` scenario.
    ///
    /// A minimal `Error` simulating a submit timeout, letting `CheckoutController` take the unknown
    /// branch (query getResult first instead of blindly resubmitting).
    private struct DemoNetworkUnavailable: Error {}

    // MARK: - PaymentSheet wrapper (SwiftUI button -> presents the UIKit payment page)

    /// A SwiftUI button that presents the public `PaymentSheet` on the frontmost view controller and
    /// passes back the returned `CheckoutOutcome`. Uses SDK public API only, no internal types.
    struct PaySheetButton: View {
        let checkout: SunbayCheckout
        let sessionId: String
        let customerAccessSecret: String?
        let onOutcome: (CheckoutOutcome) -> Void

        var body: some View {
            Button("Pay (sheet)") {
                guard let presenter = topViewController() else { return }
                let sheet = PaymentSheet(
                    checkout: checkout,
                    sessionId: sessionId,
                    customerAccessSecret: customerAccessSecret
                )
                Task { @MainActor in
                    let outcome = await sheet.present(from: presenter)
                    onOutcome(outcome)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - ApplePayButton wrapper (UIKit control -> SwiftUI)

    /// Bridges the public `ApplePayButton` (UIControl) into SwiftUI, wiring `onResult` and `onAvailabilityChange`.
    struct ApplePayButtonView: UIViewRepresentable {
        let checkout: SunbayCheckout
        let sessionId: String
        let onResult: (CheckoutOutcome) -> Void
        let onAvailabilityChange: (Bool) -> Void

        func makeUIView(context: Context) -> ApplePayButton {
            let button = ApplePayButton(checkout: checkout, sessionId: sessionId, style: .automatic)
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
