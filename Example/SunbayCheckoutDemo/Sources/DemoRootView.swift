import Foundation
import SunbayCheckout
import SunbayCheckoutTestSupport

#if canImport(UIKit) && canImport(SwiftUI)
    import SwiftUI
    import UIKit

    // MARK: - Log

    /// The live log behind the Logs tab. Lines are also printed to the console.
    ///
    /// Callers must only pass text that is safe to show: ids, codes and counts, never secrets, tokens,
    /// card data or addresses.
    @MainActor
    final class DemoLog: ObservableObject {
        enum Level {
            case info, success, warning, error

            var color: Color {
                switch self {
                case .info: return .primary
                case .success: return .green
                case .warning: return .orange
                case .error: return .red
                }
            }
        }

        struct Entry: Identifiable {
            let id: Int
            let time: String
            let level: Level
            let message: String
        }

        @Published private(set) var entries: [Entry] = []
        private var nextId = 0
        private let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()

        /// Plain-text copy of all lines, oldest first.
        var text: String { entries.map { "\($0.time) \($0.message)" }.joined(separator: "\n") }

        func add(_ message: String, level: Level = .info) {
            let entry = Entry(id: nextId, time: formatter.string(from: Date()), level: level, message: message)
            nextId += 1
            entries.append(entry)
            if entries.count > 500 { entries.removeFirst(entries.count - 500) }
            print("[SunbayDemo] \(entry.time) \(message)")
        }

        func clear() { entries = [] }
    }

    // MARK: - Root view

    /// The demo configuration playground.
    ///
    /// A tabbed config screen (Pay / Options / Look) exposing every `DemoSettings` knob, a "Pay (sheet)"
    /// action that creates a real order through the local `Example/DevServer` and presents the SDK
    /// `PaymentSheet` against the selected backend, a standalone `ApplePayButton` section, and a
    /// live Logs tab. The environment is switchable (dev by default); there is no mock mode.
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
        /// The live log shown on the Logs tab.
        @StateObject private var log = DemoLog()
        /// The current order session; every payment action needs one.
        @State private var session: DevSession?
        /// True while a session is being created.
        @State private var isCreatingSession = false
        /// The last session-creation failure, if any.
        @State private var sessionError: String?

        /// The Apple Pay merchant id baked into Info.plist (`SunbayDemoMerchantId`) by the Tuist
        /// manifest, so it always matches the entitlement. Falls back to the committed placeholder.
        private static let merchantId: String = {
            let value = Bundle.main.object(forInfoDictionaryKey: "SunbayDemoMerchantId") as? String
            return (value?.isEmpty == false ? value : nil) ?? "merchant.com.example.yourapp"
        }()

        var body: some View {
            TabView {
                tab("Pay", systemImage: "creditcard") {
                    sessionSection
                    orderSection
                    paymentSheetSection
                    applePaySection
                }
                tab("Look", systemImage: "paintbrush") {
                    appearanceSection
                    effectsSection
                    localeSection
                }
                tab("Options", systemImage: "slider.horizontal.3") {
                    methodsSection
                    addressSection
                    cofSection
                    backendSection
                }
                tab("Logs", systemImage: "list.bullet.rectangle") {
                    logsSection
                }
            }
            .onChange(of: sessionInputs) { _ in
                // A session belongs to the inputs it was created with.
                if session != nil {
                    session = nil
                    log.add("Session discarded: order or backend settings changed")
                }
            }
        }

        /// Everything a created session depends on; changing any of it invalidates the session.
        private var sessionInputs: [String] {
            [settings.environment.rawValue, settings.devServerURL, String(settings.amountMinorUnits),
             String(settings.orderRequiresBillingAddress), String(settings.orderRequiresShippingAddress)]
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

        /// SDK environment and the URL of the session server (which holds the credentials for that environment).
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
                Text("The environment is the SDK's CheckoutConfiguration.environment. Orders are created through the session server at the URL above, which must hold credentials for the same environment.")
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
                ForEach(DemoSettings.DemoAppearancePreset.allCases) { preset in
                    Button {
                        settings.appearancePreset = preset
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color(UIColor(sunbayHex: preset.swatchHex) ?? .systemOrange))
                                .frame(width: 22, height: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.label).foregroundColor(.primary)
                                Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if settings.appearancePreset == preset {
                                Image(systemName: "checkmark").foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("Each theme sets colors, corner radius, shadow, density and express position on Appearance.")
            }
        }

        private var effectsSection: some View {
            Section {
                Picker("Color scheme", selection: $settings.colorScheme) {
                    ForEach(DemoSettings.DemoColorScheme.allCases) { scheme in
                        Text(scheme.label).tag(scheme)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Shadow", selection: $settings.shadow) {
                    ForEach(DemoSettings.DemoShadow.allCases) { shadow in
                        Text(shadow.label).tag(shadow)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Sheet size", selection: $settings.sheetSize) {
                    ForEach(DemoSettings.DemoSheetSize.allCases) { size in
                        Text(size.label).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Page transitions", isOn: $settings.pageTransitions)
            } header: {
                Text("Effects")
            } footer: {
                Text("Overrides applied on top of the theme. Color scheme and shadow stay at the theme's own value when set to Automatic / Theme.")
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

        // MARK: - Session

        /// Creating the session comes first: the payment actions below stay disabled until one exists.
        private var sessionSection: some View {
            Section {
                Button {
                    createSession()
                } label: {
                    HStack {
                        Text(session == nil ? "Create session" : "Create a new session")
                        if isCreatingSession { Spacer(); ProgressView() }
                    }
                }
                .disabled(isCreatingSession)
                if let session {
                    HStack {
                        Text("Session")
                        Spacer()
                        Text(session.sessionId).font(.footnote.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                } else if let sessionError {
                    Text(sessionError).font(.footnote).foregroundColor(.red)
                } else {
                    Text("No session yet. Create one to enable the payment actions.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Session")
            } footer: {
                Text("Creates an order through the session server using the order settings below. Changing them discards the session.")
            }
        }

        private func createSession() {
            guard !isCreatingSession else { return }
            isCreatingSession = true
            sessionError = nil
            session = nil
            let request = sessionRequest
            log.add("Create session: env=\(settings.environment.label) amount=\(settings.amountMinorUnits) billing=\(request.collectBillingAddress) shipping=\(request.collectShippingAddress)")
            Task { @MainActor in
                defer { isCreatingSession = false }
                do {
                    let created = try await request.create()
                    session = created
                    log.add("Session created: \(created.sessionId)")
                } catch {
                    let message = describeSessionError(error)
                    sessionError = message
                    log.add("Create session failed: \(message)", level: .error)
                }
            }
        }

        // MARK: - Action sections

        private var paymentSheetSection: some View {
            Section("PaymentSheet (L1 black-box)") {
                Text("Presents the SDK sheet for the session: new-card form, 'Save this card', saved cards (COF one-tap), and an Apple Pay entry row.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                PaySheetButton(
                    checkout: makeCheckout(),
                    session: session,
                    request: sessionRequest,
                    onOutcome: { handle($0, source: "Sheet") },
                    onState: { log.add("Sheet state: \(describeState($0))") }
                )
            }
        }

        private var applePaySection: some View {
            Section("Standalone ApplePayButton (L3)") {
                StandaloneApplePaySection(
                    checkout: makeCheckout(),
                    session: session,
                    onResult: { handle($0, source: "Apple Pay") },
                    onAvailability: { log.add("Apple Pay button available: \($0)") }
                )
            }
        }

        /// Logs an outcome; a session that reached a final state is spent, so the next payment needs a new one.
        private func handle(_ outcome: CheckoutOutcome, source: String) {
            let level: DemoLog.Level
            switch outcome {
            case .succeeded: level = .success
            case .failed: level = .error
            default: level = .info
            }
            log.add("\(source) outcome: \(describe(outcome))", level: level)
            switch outcome {
            case .succeeded, .pending, .unknown:
                session = nil
                log.add("Session finished; create a new one to pay again")
            case .failed, .canceled:
                break
            }
        }

        // MARK: - Logs

        private var logsSection: some View {
            Section {
                HStack {
                    Button("Copy") { UIPasteboard.general.string = log.text }
                        .disabled(log.entries.isEmpty)
                    Spacer()
                    Button("Clear", role: .destructive) { log.clear() }
                        .disabled(log.entries.isEmpty)
                }
                if log.entries.isEmpty {
                    Text("No logs yet.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(log.entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.time).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            Text(entry.message).font(.footnote.monospaced()).foregroundColor(entry.level.color)
                        }
                    }
                }
            } footer: {
                Text("Newest first. Shows session creation, outcomes, sheet states and SDK diagnostics. Secrets and card data are never logged.")
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
            let sink = log
            checkout.onDiagnostic = { event in
                sink.add("Diagnostic: \(Self.describe(event))", level: .warning)
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
                appearance.colors.primary = hex("#ff6000")
            case .sharpBlueExpressBottom:
                appearance.colors.primary = hex("#2563eb")
                appearance.cornerRadius = 3
                appearance.expressPosition = .bottom
                appearance.density = .compact
            case .roundGreenDark:
                appearance.colors.primary = hex("#16a34a")
                appearance.cornerRadius = 20
                appearance.colorScheme = .dark
            case .midnight:
                appearance.colorScheme = .dark
                appearance.colors.primary = hex("#8b5cf6")
                appearance.colors.background = hex("#0b1020")
                appearance.colors.componentBackground = hex("#151b30")
                appearance.colors.text = hex("#e6e9f5")
                appearance.colors.textSecondary = hex("#8d96b8")
                appearance.colors.border = hex("#2a3354")
                appearance.cornerRadius = 14
                appearance.shadow = .medium
            case .ocean:
                appearance.colorScheme = .light
                appearance.colors.primary = hex("#0ea5e9")
                appearance.colors.background = hex("#f0f9ff")
                appearance.colors.componentBackground = hex("#ffffff")
                appearance.colors.border = hex("#bae6fd")
                appearance.cornerRadius = 12
                appearance.shadow = .soft
            case .sunset:
                appearance.colorScheme = .light
                appearance.colors.primary = hex("#f43f5e")
                appearance.colors.background = hex("#fff1f2")
                appearance.colors.componentBackground = hex("#ffffff")
                appearance.colors.border = hex("#fecdd3")
                appearance.cornerRadius = 24
                appearance.primaryButton.cornerRadius = 24
                appearance.shadow = .medium
            case .mono:
                appearance.colorScheme = .light
                appearance.colors.primary = hex("#111827")
                appearance.colors.background = hex("#ffffff")
                appearance.colors.border = hex("#111827")
                appearance.cornerRadius = 0
                appearance.borderWidth = 1.5
                appearance.density = .compact
            case .editorial:
                appearance.colorScheme = .light
                appearance.colors.primary = hex("#92400e")
                appearance.colors.background = hex("#fffbeb")
                appearance.colors.componentBackground = hex("#fffdf5")
                appearance.colors.text = hex("#3b2a14")
                appearance.colors.border = hex("#e7d3a8")
                appearance.cornerRadius = 4
                appearance.font.base = UIFont(name: "Georgia", size: 16)
            }

            switch settings.colorScheme {
            case .automatic:
                break // keep the theme's scheme
            case .light:
                appearance.colorScheme = .light
            case .dark:
                appearance.colorScheme = .dark
            }

            switch settings.shadow {
            case .theme: break
            case .none: appearance.shadow = .none
            case .soft: appearance.shadow = .soft
            case .medium: appearance.shadow = .medium
            }

            switch settings.sheetSize {
            case .adaptive: break
            case .half: appearance.sheetSizing = .init(mode: .fixedFraction(0.5))
            case .large: appearance.sheetSizing = .init(mode: .large)
            }
            appearance.pageTransitionsEnabled = settings.pageTransitions

            appearance.billingAddressMode = addressMode(settings.billingAddressMode)
            appearance.shippingAddressMode = addressMode(settings.shippingAddressMode)
            return appearance
        }

        /// A color from a hardcoded valid hex literal (the fallback is unreachable).
        private func hex(_ value: String) -> UIColor {
            UIColor(sunbayHex: value) ?? .systemOrange
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
        /// Host-provided shipping address for `PaymentSheet(shippingAddress:)` (nil: let the form collect it).
        let hostShippingAddress: AddressInput?

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

    /// A SwiftUI button that presents the public `PaymentSheet` for an existing session on the
    /// frontmost view controller and passes back the returned `CheckoutOutcome`.
    struct PaySheetButton: View {
        let checkout: SunbayCheckout
        let session: DevSession?
        let request: DevSessionRequest
        let onOutcome: (CheckoutOutcome) -> Void
        let onState: (CheckoutPresentationState) -> Void
        @State private var isBusy = false

        var body: some View {
            Button("Pay (sheet)") {
                guard !isBusy, let session, let presenter = topViewController() else { return }
                isBusy = true
                Task { @MainActor in
                    defer { isBusy = false }
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
            .disabled(isBusy || session == nil)
        }
    }

    // MARK: - Standalone ApplePayButton section

    /// The standalone `ApplePayButton` bound to the current session.
    struct StandaloneApplePaySection: View {
        let checkout: SunbayCheckout
        let session: DevSession?
        let onResult: (CheckoutOutcome) -> Void
        let onAvailability: (Bool) -> Void
        @State private var available = false

        var body: some View {
            if let session {
                VStack(alignment: .leading, spacing: 8) {
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
                        onAvailabilityChange: {
                            available = $0
                            onAvailability($0)
                        }
                    )
                    .id(session.sessionId)
                    .frame(height: 48)
                }
            } else {
                Text("Create a session first. Apple Pay needs a real device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
