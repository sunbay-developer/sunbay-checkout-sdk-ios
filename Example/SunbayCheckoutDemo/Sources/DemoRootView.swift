import Foundation
import SunbayCheckout
import SunbayCheckoutTestSupport

#if canImport(UIKit) && canImport(SwiftUI)
    import SwiftUI
    import UIKit

    // MARK: - Toast

    /// A short message shown over the tabs.
    struct DemoToast: Equatable {
        enum Kind: Equatable { case success, error, info }
        let id = UUID()
        let message: String
        let kind: Kind
    }

    struct ToastView: View {
        let toast: DemoToast

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(toast.message).font(.subheadline.bold())
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(color))
            .shadow(radius: 6)
        }

        private var icon: String {
            switch toast.kind {
            case .success: return "checkmark.circle.fill"
            case .error: return "xmark.octagon.fill"
            case .info: return "info.circle.fill"
            }
        }

        private var color: Color {
            switch toast.kind {
            case .success: return .green
            case .error: return .red
            case .info: return .gray
            }
        }
    }

    // MARK: - Section help

    /// A section title with a "?" button that explains the section in an alert (keeps the form compact).
    struct SectionHelp: View {
        let title: String
        let message: String
        @State private var isShown = false

        init(_ title: String, _ message: String) {
            self.title = title
            self.message = message
        }

        var body: some View {
            HStack(spacing: 6) {
                Text(title)
                Button {
                    isShown = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Help: \(title)")
            }
            .alert(title, isPresented: $isShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message)
            }
        }
    }

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
        /// The toast currently shown over the tabs (payment results).
        @State private var toast: DemoToast?
        /// Whether the embedded ApplePayButton has been loaded (it is not rendered until asked for).
        @State private var embeddedLoaded = false
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
                    orderSection
                    sessionSection
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
                }
                tab("Logs", systemImage: "list.bullet.rectangle") {
                    logsSection
                }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    ToastView(toast: toast)
                        .padding(.bottom, 70)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: toast)
            .onChange(of: session?.sessionId) { id in
                if id == nil { embeddedLoaded = false }
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
             String(settings.orderRequiresBillingAddress), String(settings.orderRequiresShippingAddress),
             String(settings.orderSupportsSavedCards)]
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
                Toggle("Requires billing address", isOn: $settings.orderRequiresBillingAddress)
                Toggle("Requires shipping address", isOn: $settings.orderRequiresShippingAddress)
                Toggle("Supports saved cards", isOn: $settings.orderSupportsSavedCards)
                DisclosureGroup("More") {
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
                }
            } header: {
                SectionHelp("Order", "These values are sent to the session server when the session is created; changing any of them discards the current session. The server receives the amount in major units (minor units / 100). The \"Requires\" toggles set the session's collect flags and \"Supports saved cards\" sets the session's card-on-file flag (the host switch on the Options tab can only disable saved cards on top of it). More: Environment is the SDK's CheckoutConfiguration.environment (Dev by default); Server URL is the session server, which must hold credentials for the same environment.")
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
                SectionHelp("Locale", "Drives CheckoutConfiguration.locale. Switch to zh-CN, then present the sheet to see the SDK render its Chinese UI strings.")
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
                SectionHelp("Theme", "Each theme sets colors, corner radius, shadow, density and express position on Appearance.")
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
                SectionHelp("Effects", "Overrides applied on top of the theme. Color scheme and shadow stay at the theme's own value when set to Automatic / Theme.")
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
                SectionHelp("Address collection", "Automatic follows the session flag set by the \"Order requires\" toggles on the Pay tab (on: full form, off: hidden); Simple, Full and Off ignore it. The \"Pass a host ...\" toggles supply a fixed, complete US test address. A host address is used only when the session collects that kind and the address is complete; Automatic then hides the form for it. A form that is shown wins over the host address.")
            }
        }

        private var methodsSection: some View {
            Section {
                Toggle("Hide Apple Pay", isOn: $settings.hideApplePay)
                Toggle("Hide Card", isOn: $settings.hideCard)
                Picker("Apple Pay button text", selection: $settings.applePayText) {
                    ForEach(DemoSettings.DemoApplePayText.allCases) { text in
                        Text(text.label).tag(text)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                SectionHelp("Payment methods", "Hide maps to PaymentMethodFilter(hide:). Hiding Card also hides saved cards; hiding every method makes present() fail with NO_PAYMENT_METHOD_AVAILABLE. Apple Pay button text maps to Appearance.applePayButtonType (the sheet's express row) and ApplePayButton(type:) (the embedded button).")
            }
        }

        private var cofSection: some View {
            Section {
                Toggle("Card on file enabled", isOn: $settings.cardOnFileEnabled)
                Toggle("Pre-tick save card", isOn: $settings.preTickSaveCard)
            } header: {
                SectionHelp("Saved cards", "The host switch can only disable saved cards; the session must also allow them. \"Pre-tick save card\" only sets the checkbox's initial state.")
            }
        }

        // MARK: - Session

        /// The payment actions below stay disabled until a session exists. The session is created from the Backend
        /// and Order settings above.
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
                }
            } header: {
                SectionHelp("Session", "Creates an order through the session server using the Backend and Order settings above. Changing any of them discards the session.")
            }
        }

        private func createSession() {
            guard !isCreatingSession else { return }
            isCreatingSession = true
            sessionError = nil
            session = nil
            let request = sessionRequest
            log.add("Create session: env=\(settings.environment.label) amount=\(settings.amountMinorUnits) billing=\(request.collectBillingAddress) shipping=\(request.collectShippingAddress) savedCards=\(request.supportStoreCard)")
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
            Section {
                PaySheetButton(
                    checkout: makeCheckout(),
                    session: session,
                    request: sessionRequest,
                    onOutcome: { handle($0, source: "Sheet") },
                    onState: { log.add("Sheet state: \(describeState($0))") }
                )
            } header: {
                SectionHelp("PaymentSheet", "L1 black-box page for the current session: new-card form, 'Save this card', saved cards (one-tap) and an Apple Pay entry row.")
            }
        }

        private var applePaySection: some View {
            Section {
                if embeddedLoaded, session != nil {
                    StandaloneApplePaySection(
                        checkout: makeCheckout(),
                        session: session,
                        type: settings.applePayText.sdk,
                        onResult: { handle($0, source: "Apple Pay") },
                        onAvailability: { log.add("Apple Pay button available: \($0)") }
                    )
                    Button("Remove") {
                        embeddedLoaded = false
                        log.add("Embedded ApplePayButton removed")
                    }
                } else {
                    Button("Load ApplePayButton") {
                        embeddedLoaded = true
                        log.add("Embedded ApplePayButton loaded")
                    }
                    .disabled(session == nil)
                }
            } header: {
                SectionHelp("Embedded components", "Components you embed in your own screen. Nothing is rendered until you load it. Currently: the L3 ApplePayButton bound to the current session (needs a real device). Card and billing-address components will be added here once they are embeddable.")
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
            showToast(for: outcome)
            switch outcome {
            case .succeeded, .pending, .unknown:
                session = nil
                log.add("Session finished; create a new one to pay again")
            case .failed, .canceled:
                break
            }
        }

        /// Shows the result of a payment attempt as a short toast (codes only, never sensitive data).
        private func showToast(for outcome: CheckoutOutcome) {
            let next: DemoToast
            switch outcome {
            case .succeeded: next = DemoToast(message: "Payment succeeded", kind: .success)
            case .canceled: next = DemoToast(message: "Payment canceled", kind: .info)
            case let .failed(_, error): next = DemoToast(message: "Payment failed: \(error.code)", kind: .error)
            case .pending: next = DemoToast(message: "Payment pending", kind: .info)
            case .unknown: next = DemoToast(message: "Payment result unknown", kind: .info)
            }
            toast = next
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if toast == next { toast = nil }
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
            } header: {
                SectionHelp("Logs", "Newest first. Shows session creation, outcomes, sheet states and SDK diagnostics. Secrets and card data are never logged.")
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
                supportStoreCard: settings.orderSupportsSavedCards,
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

            appearance.applePayButtonType = settings.applePayText.sdk
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
        /// Whether the session allows saved cards (the session's card-on-file flag).
        let supportStoreCard: Bool
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
                supportStoreCard: supportStoreCard
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
            Button {
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
            } label: {
                Text("Pay (sheet)").frame(maxWidth: .infinity)
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
        let type: ApplePayButtonType
        let onResult: (CheckoutOutcome) -> Void
        let onAvailability: (Bool) -> Void
        @State private var available = false

        var body: some View {
            if let session {
                VStack(alignment: .leading, spacing: 8) {
                    Text(available ? "Available" : "Unavailable (device cannot pay or merchant id not configured)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ApplePayButtonView(
                        checkout: checkout,
                        sessionId: session.sessionId,
                        checkoutClientSecret: session.checkoutClientSecret,
                        type: type,
                        onResult: onResult,
                        onAvailabilityChange: {
                            available = $0
                            onAvailability($0)
                        }
                    )
                    .id("\(session.sessionId)-\(type)")
                    .frame(height: 48)
                }
            } else {
                Text("Create a session first.")
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
        let type: ApplePayButtonType
        let onResult: (CheckoutOutcome) -> Void
        let onAvailabilityChange: (Bool) -> Void

        func makeUIView(context: Context) -> ApplePayButton {
            let button = ApplePayButton(
                checkout: checkout,
                sessionId: sessionId,
                style: .automatic,
                type: type,
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

    extension DemoSettings.DemoApplePayText {
        /// The SDK button wording for this demo choice.
        var sdk: ApplePayButtonType {
            switch self {
            case .plain: return .plain
            case .buy: return .buy
            case .setUp: return .setUp
            case .inStore: return .inStore
            case .donate: return .donate
            case .checkout: return .checkout
            case .book: return .book
            case .subscribe: return .subscribe
            case .reload: return .reload
            case .addMoney: return .addMoney
            case .topUp: return .topUp
            case .order: return .order
            case .rent: return .rent
            case .support: return .support
            case .contribute: return .contribute
            case .tip: return .tip
            }
        }
    }

#endif
