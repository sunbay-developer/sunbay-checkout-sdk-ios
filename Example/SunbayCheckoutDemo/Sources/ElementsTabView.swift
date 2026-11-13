import Foundation
import SunbayCheckout
import SunbayCheckoutTestSupport

#if canImport(UIKit) && canImport(SwiftUI)
    import Combine
    import SwiftUI
    import UIKit

    // MARK: - Page configuration

    /// The component selection on the Configuration group.
    enum ElementsMode: String, CaseIterable, Identifiable {
        case both, expressOnly, cardOnly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .both: return "Both"
            case .expressOnly: return "Express only"
            case .cardOnly: return "Card only"
            }
        }

        var hasExpress: Bool { self != .cardOnly }
        var hasCard: Bool { self != .expressOnly }

        /// Default mode; a DEBUG build also accepts `-ElementsMode both|express|card` as a launch argument.
        static var launchDefault: ElementsMode {
            #if DEBUG
                switch UserDefaults.standard.string(forKey: "ElementsMode") {
                case "express": return .expressOnly
                case "card": return .cardOnly
                default: return .both
                }
            #else
                return .both
            #endif
        }
    }

    /// The per-element switches on the Configuration disclosure group. Each one maps to a field of
    /// `ExpressCheckoutElement.Configuration` or `CardElement.Configuration`; changing any of them rebuilds the elements.
    struct ElementsPageOptions: Equatable {
        /// Which components the merchant page embeds.
        var mode: ElementsMode = ElementsMode.launchDefault
        /// `ExpressCheckoutElement.Configuration.methods = [.applePay]`.
        var applePayOnly = false
        /// `CardElement.Configuration.showsSavedCards`.
        var showsSavedCards = true
        /// `CardElement.Configuration.billingAddress` (`.automatic` when on, `.off` when off).
        var billingAddress = true
        /// `CardElement.Configuration.shippingAddress` (`.automatic` when on, `.off` when off).
        var shippingAddress = true
        /// `CardElement.Configuration.showsSaveCardOption`.
        var showsSaveCardOption = true
    }

    // MARK: - Model

    /// The state behind the Elements tab: one `CheckoutElements` group plus its express and card components,
    /// and the merchant-owned Pay button state. Uses only the SDK's public API.
    @MainActor
    final class ElementsPageModel: ObservableObject, CardElementDelegate {
        @Published private(set) var express: ExpressCheckoutElement?
        @Published private(set) var card: CardElement?
        @Published private(set) var expressAvailable = false
        @Published private(set) var cardHeight: CGFloat = 0
        @Published private(set) var isCardComplete = false
        @Published private(set) var selectedLabel = "-"
        @Published private(set) var isLoading = false
        @Published private(set) var errorText: String?
        @Published private(set) var isPaying = false
        @Published private(set) var isClosed = false
        @Published private(set) var lastOutcome: CheckoutOutcome?

        private var elements: CheckoutElements?
        /// Reports every outcome to the host screen (log and toast).
        var onOutcome: ((CheckoutOutcome) -> Void)?
        var onLog: ((String, DemoLog.Level) -> Void)?
        /// Bumped by every load so a slow, superseded load cannot overwrite a newer one.
        private var generation = 0

        /// True when there is a group that can still take a payment.
        var isActive: Bool { elements != nil && !isClosed }

        /// Drops the current group (closing it) and creates a fresh one for the session.
        func load(
            checkout: SunbayCheckout, session: DevSession, type: ApplePayButtonType,
            style: Appearance.ApplePayButtonStyle, options: ElementsPageOptions
        ) async {
            generation += 1
            let mine = generation
            elements?.close()
            elements = nil
            express = nil
            card = nil
            expressAvailable = false
            cardHeight = 0
            isCardComplete = false
            selectedLabel = "-"
            errorText = nil
            lastOutcome = nil
            isClosed = false
            isPaying = false
            isLoading = true

            var configuration = CheckoutElements.Configuration()
            configuration.customerAccessSecret = session.customerAccessSecret
            configuration.checkoutClientSecret = session.checkoutClientSecret
            do {
                let group = try await CheckoutElements.create(
                    checkout: checkout, sessionId: session.sessionId, configuration: configuration)
                guard mine == generation else {
                    group.close()
                    return
                }
                isLoading = false
                elements = group

                var cardCreated: CardElement?
                if options.mode.hasCard {
                    var cardConfiguration = CardElement.Configuration()
                    cardConfiguration.showsSavedCards = options.showsSavedCards
                    cardConfiguration.billingAddress = options.billingAddress ? .automatic : .off
                    cardConfiguration.shippingAddress = options.shippingAddress ? .automatic : .off
                    cardConfiguration.showsSaveCardOption = options.showsSaveCardOption
                    let cardElement = group.makeCardElement(cardConfiguration)
                    cardElement.delegate = self
                    card = cardElement
                    // There is no initial height callback: read the intrinsic height once after creation.
                    cardHeight = cardElement.view.intrinsicContentSize.height
                    isCardComplete = cardElement.isComplete
                    cardCreated = cardElement
                }

                var expressCreated: ExpressCheckoutElement?
                if options.mode.hasExpress {
                    var expressConfiguration = ExpressCheckoutElement.Configuration()
                    expressConfiguration.buttonType = type
                    expressConfiguration.buttonStyle = style
                    expressConfiguration.methods = options.applePayOnly ? [.applePay] : nil
                    let expressElement = group.makeExpressCheckoutElement(expressConfiguration)
                    expressElement.onResult = { [weak self] in self?.record($0, source: "Express") }
                    expressElement.onAvailabilityChange = { [weak self] available in
                        self?.expressAvailable = available
                        self?.onLog?("Express element available: \(available)", .info)
                    }
                    // `isAvailable` is authoritative; the callback above only repeats it.
                    expressAvailable = expressElement.isAvailable
                    express = expressElement
                    expressCreated = expressElement
                }
                onLog?(
                    "Elements created (mode: \(options.mode.label), card: \(cardCreated.map { String($0.isAvailable) } ?? "not created"), express: \(expressCreated.map { String($0.isAvailable) } ?? "not created"))",
                    .info)
            } catch {
                guard mine == generation else { return }
                isLoading = false
                errorText = (error as? CheckoutError)?.message ?? "Elements could not be created."
                onLog?("Elements creation failed: \(errorText ?? "-")", .error)
            }
        }

        /// The merchant-owned Pay button: pays whatever the card element has selected.
        func pay() async {
            guard let elements, !isPaying, !isClosed else { return }
            isPaying = true
            let outcome = await elements.confirm()
            isPaying = false
            record(outcome, source: "Elements")
        }

        /// Clears the typed card values (`CardElement.clear()`).
        func clearCard() {
            card?.clear()
            refreshCardState()
        }

        /// Ends the session (`CheckoutElements.close()`); the elements stay on screen, disabled.
        func close() {
            guard !isClosed else { return }
            elements?.close()
            isClosed = true
            onLog?("Elements closed", .info)
        }

        private func record(_ outcome: CheckoutOutcome, source: String) {
            lastOutcome = outcome
            refreshCardState()
            onOutcome?(outcome)
        }

        private func refreshCardState() {
            isCardComplete = card?.isComplete ?? false
            selectedLabel = elements?.paymentOption?.label ?? "-"
        }

        // MARK: CardElementDelegate

        func cardElementDidUpdateHeight(_ element: CardElement) {
            cardHeight = element.view.intrinsicContentSize.height
        }

        func cardElementDidChangeSelection(_ element: CardElement) {
            refreshCardState()
        }

        func cardElementDidChangeCompleteness(_ element: CardElement) {
            refreshCardState()
        }
    }

    // MARK: - Keyboard

    /// Publishes the on-screen keyboard height so the page can pad its bottom (the host owns keyboard insets).
    @MainActor
    final class KeyboardObserver: ObservableObject {
        @Published private(set) var height: CGFloat = 0
        private var token: AnyCancellable?

        init() {
            token = NotificationCenter.default
                .publisher(for: UIResponder.keyboardWillChangeFrameNotification)
                .sink { [weak self] note in
                    guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                    let screenHeight = UIScreen.main.bounds.height
                    let overlap = max(0, screenHeight - frame.minY)
                    self?.height = overlap
                }
        }
    }

    // MARK: - Tab view

    /// A typical merchant checkout page built from the Elements components: order summary, Express
    /// Checkout, the Card element, and a merchant-owned Pay button. Card entry stays inside the SDK.
    ///
    /// The shared settings (server URL, environment, order amount, theme, locale, Apple Pay button wording and
    /// color, method-hide switches, saved-cards switch) come from `DemoSettings` via the closures; only the
    /// element-level switches live here.
    struct ElementsTabView: View {
        let settings: DemoSettings
        let session: DevSession?
        let isCreatingSession: Bool
        let sessionError: String?
        let makeCheckout: () -> SunbayCheckout
        let createSession: () -> Void
        let onOutcome: (CheckoutOutcome) -> Void
        let onLog: (String, DemoLog.Level) -> Void

        @StateObject private var model = ElementsPageModel()
        @StateObject private var keyboard = KeyboardObserver()
        @State private var options = ElementsPageOptions()
        /// Bumped by "Recreate" to force a rebuild with the same session.
        @State private var recreateToken = 0
        @State private var showsConfiguration = false

        /// The merchant's own brand color and typography: deliberately not the SDK theme.
        private static let brand = Color(red: 0.17, green: 0.16, blue: 0.42)
        private static let pageRadius: CGFloat = 6

        /// Everything that forces the elements to be rebuilt.
        private var rebuildKey: String {
            "\(session?.sessionId ?? "-")|\(recreateToken)|\(String(describing: settings))|\(String(describing: options))"
        }

        private var hasElements: Bool { model.card != nil || model.express != nil }

        var body: some View {
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        demoControls
                        Text("Checkout")
                            .font(.system(size: 34, weight: .heavy, design: .serif))
                            .foregroundColor(Self.brand)
                        cartSection
                        if session != nil || hasElements {
                            checkoutArea
                        } else {
                            placeholder
                        }
                        resultArea
                        configurationArea
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .padding(.bottom, keyboard.height)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { payBar }
                .navigationBarHidden(true)
            }
            .navigationViewStyle(.stack)
            .task(id: rebuildKey) {
                model.onOutcome = onOutcome
                model.onLog = onLog
                guard let session else { return }
                await model.load(
                    checkout: makeCheckout(), session: session, type: settings.applePayText.sdk,
                    style: settings.applePayStyle.sdkSheet, options: options)
            }
            .tabItem { Label("Elements", systemImage: "rectangle.stack") }
        }

        // MARK: Demo harness (not part of the merchant page)

        /// Session creation belongs to the demo harness, so it is drawn apart from the merchant page.
        private var demoControls: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("DEMO CONTROLS (not part of the merchant page)")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                HStack {
                    Button {
                        createSession()
                    } label: {
                        HStack(spacing: 6) {
                            Text(session == nil ? "Create order" : "Reload")
                            if isCreatingSession { ProgressView() }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isCreatingSession)
                    if let session {
                        Text(session.sessionId).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                if let sessionError {
                    Text(sessionError).font(.footnote).foregroundColor(.red)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundColor(.secondary.opacity(0.6)))
        }

        // MARK: Cart

        /// Sample cart lines. The two items split the real amount so the lines always add up to the total.
        private var cartLines: [(name: String, cents: Int)] {
            let amountCents = Int((DemoSettings.majorUnits(settings.amount) * 100).rounded())
            let taxCents = Int((DemoSettings.majorUnits(settings.tax) * 100).rounded())
            let first = amountCents * 6 / 10
            var lines = [("Demo T-Shirt  x1", first), ("Canvas Tote  x1", amountCents - first)]
            if taxCents > 0 { lines.append(("Tax", taxCents)) }
            return lines
        }

        private var totalCents: Int { cartLines.reduce(0) { $0 + $1.cents } }

        private static func money(_ cents: Int) -> String {
            String(format: "$%d.%02d", cents / 100, cents % 100)
        }

        private var cartSection: some View {
            VStack(spacing: 10) {
                ForEach(Array(cartLines.enumerated()), id: \.offset) { _, line in
                    HStack {
                        Text(line.name).font(.system(size: 16, design: .serif))
                        Spacer()
                        Text(Self.money(line.cents)).font(.system(size: 16, design: .serif))
                    }
                }
                Divider()
                HStack {
                    Text("Total").font(.system(size: 18, weight: .bold, design: .serif))
                    Spacer()
                    Text(Self.money(totalCents)).font(.system(size: 18, weight: .bold, design: .serif))
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: Self.pageRadius).fill(Color(UIColor.secondarySystemBackground)))
        }

        private var placeholder: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("Payment options will appear here").font(.system(size: 15, weight: .semibold, design: .serif))
                Text("Use \"Create order\" above to start a checkout session.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Self.pageRadius).fill(Color(UIColor.secondarySystemBackground)))
        }

        // MARK: Checkout area

        /// A merchant-styled section: its own heading in a neutral rounded container.
        private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.system(size: 18, weight: .bold, design: .serif)).foregroundColor(Self.brand)
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Self.pageRadius).fill(Color(UIColor.secondarySystemBackground)))
        }

        /// The elements stay visible after the session is spent (so the result and the disabled state show).
        private var checkoutArea: some View {
            VStack(alignment: .leading, spacing: 20) {
                if model.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading session...").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let errorText = model.errorText {
                    Text(errorText).font(.footnote).foregroundColor(.red)
                }
                if let express = model.express {
                    section("Express checkout") { expressArea(express) }
                }
                if let card = model.card {
                    section("Pay by card") { cardArea(card) }
                }
            }
        }

        private func expressArea(_ express: ExpressCheckoutElement) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                ElementView(view: express.view)
                    .frame(height: model.expressAvailable ? 48 : 0)
                if !model.expressAvailable {
                    Text("Apple Pay unavailable (device cannot pay, merchant id not configured, or hidden by settings)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }

        private func cardArea(_ card: CardElement) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                ElementView(view: card.view)
                    .frame(height: model.cardHeight)
                if !card.isAvailable {
                    Text("Card is unavailable for this session (not offered or hidden by settings)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("Selected: \(model.selectedLabel)").font(.footnote).foregroundStyle(.secondary)
            }
        }

        // MARK: Pay bar

        /// The merchant-owned bar pinned to the bottom. While the keyboard is up it collapses to a "Done" strip,
        /// so it never covers the card fields.
        @ViewBuilder
        private var payBar: some View {
            if keyboard.height > 0 {
                HStack {
                    Spacer()
                    Button("Done") { Self.dismissKeyboard() }
                        .font(.system(size: 15, weight: .bold)).foregroundColor(Self.brand)
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                .background(Color(UIColor.systemBackground))
            } else {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Total").font(.system(size: 12, design: .serif)).foregroundStyle(.secondary)
                        Text(Self.money(totalCents)).font(.system(size: 20, weight: .bold, design: .serif))
                    }
                    Spacer()
                    if options.mode == .expressOnly {
                        Text("Tap Apple Pay above to pay")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    } else {
                        placeOrderButton
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(Color(UIColor.systemBackground).shadow(color: .black.opacity(0.12), radius: 4, y: -1))
            }
        }

        private static func dismissKeyboard() {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        private var payEnabled: Bool { model.card != nil && model.isCardComplete && !model.isPaying && !model.isClosed }

        /// The merchant's own Pay button; the SDK renders no button and no spinner.
        private var placeOrderButton: some View {
            Button {
                Self.dismissKeyboard()
                Task { await model.pay() }
            } label: {
                HStack(spacing: 8) {
                    if model.isPaying { ProgressView().tint(.white) }
                    Text(model.isPaying ? "Processing..." : "Place order")
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 28).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Self.brand.opacity(payEnabled || model.isPaying ? 1 : 0.35)))
            }
            .buttonStyle(.plain)
            .disabled(!payEnabled)
        }

        // MARK: Result

        @ViewBuilder
        private var resultArea: some View {
            if let outcome = model.lastOutcome {
                let copy = Self.resultCopy(outcome)
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy.title).font(.system(size: 16, weight: .bold, design: .serif)).foregroundColor(copy.color)
                    Text(copy.detail).font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: Self.pageRadius).fill(copy.color.opacity(0.12)))
            }
        }

        /// Merchant-side copy for each outcome (contains no sensitive data).
        static func resultCopy(_ outcome: CheckoutOutcome) -> (title: String, detail: String, color: Color) {
            switch outcome {
            case let .succeeded(txnId):
                return ("Payment succeeded", "Thank you for your order. Transaction \(txnId).", .green)
            case let .failed(_, error):
                return ("Payment failed", "\(error.message) (\(error.code)). You can try again.", .red)
            case .canceled:
                return ("Payment canceled", "No charge was made.", .secondary)
            case .pending:
                return ("Payment is being confirmed", "We are confirming your payment. Do not pay again.", .orange)
            case let .unknown(sessionId):
                return (
                    "Payment result unknown",
                    "We could not confirm the result yet. Do not pay again; check the order status later (session \(sessionId)).",
                    .orange)
            }
        }

        // MARK: Configuration

        private var configurationArea: some View {
            DisclosureGroup("Configuration", isExpanded: $showsConfiguration) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Components", selection: $options.mode) {
                        ForEach(ElementsMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Apple Pay only", isOn: $options.applePayOnly)
                        .disabled(!options.mode.hasExpress)
                    Text("No visible effect while Apple Pay is the only express method.")
                        .font(.caption).foregroundStyle(.secondary)
                    Group {
                        Toggle("Show saved cards", isOn: $options.showsSavedCards)
                        Toggle("Billing address", isOn: $options.billingAddress)
                        Toggle("Shipping address", isOn: $options.shippingAddress)
                        Toggle("Show \"save this card\" option", isOn: $options.showsSaveCardOption)
                    }
                    .disabled(!options.mode.hasCard)
                    if !options.mode.hasCard {
                        Text("Express only: the card element is not created, so the card options and the selected-option line are off.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Theme, locale, Apple Pay button and method-hide switches come from the other tabs.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Clear card") { model.clearCard() }
                            .disabled(model.card == nil)
                        Spacer()
                        Button("Close", role: .destructive) { model.close() }
                            .disabled(!model.isActive)
                        Spacer()
                        Button("Recreate") { recreateToken += 1 }
                            .disabled(session == nil)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Element wrapper (UIKit view -> SwiftUI)

    /// Hosts an element's self-sizing view inside SwiftUI (the caller fixes the height).
    struct ElementView: UIViewRepresentable {
        let view: UIView

        func makeUIView(context: Context) -> UIView { view }

        func updateUIView(_ uiView: UIView, context: Context) {}
    }
#endif
