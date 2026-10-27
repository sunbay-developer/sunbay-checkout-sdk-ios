import Foundation
import SunbayCheckout

#if canImport(UIKit) && canImport(SwiftUI)
    import SwiftUI
    import UIKit

    // MARK: - App entry

    /// SunbayCheckout mock example App (SwiftUI, iOS Simulator).
    ///
    /// Consumes only the SDK's **public** API: `SunbayCheckout(configuration:paymentService:cofService:)`
    /// injects an in-memory mock backend, then uses `PaymentSheet` / `ApplePayButton` to run end-to-end.
    /// Imports no internal types and does not use @testable.
    @main
    struct SunbayCheckoutDemoApp: App {
        var body: some Scene {
            WindowGroup {
                DemoRootView()
            }
        }
    }

    // MARK: - Root view

    /// Demo main screen: scenario selection + "Pay (sheet)" + standalone ApplePayButton + result display.
    struct DemoRootView: View {
        /// The switchable submit scenario (drives the four outcomes + requiresAction).
        @State private var script: DemoScript = .succeeded
        /// A readable description of the most recent checkout result.
        @State private var lastOutcome: String = "—"
        /// Availability of the standalone ApplePayButton (onAvailabilityChange drives show/hide).
        @State private var applePayAvailable = false

        // Fixed demo session identifier and COF credential (mock, not confidential).
        private let sessionId = "demo_session_001"
        private let customerAccessSecret = "demo_secret"

        /// The mock payment service (holds the current scenario); synced to it whenever the scenario changes.
        @State private var paymentService = MockDemoPaymentService(script: .succeeded)
        private let cofService = MockDemoCofService()

        var body: some View {
            NavigationView {
                Form {
                    Section("Scenario (mock submit result)") {
                        Picker("Script", selection: $script) {
                            Text("Succeeded").tag(DemoScript.succeeded)
                            Text("Failed").tag(DemoScript.failed)
                            Text("Pending").tag(DemoScript.pending)
                            Text("Requires action").tag(DemoScript.requiresAction)
                            Text("Network timeout → unknown").tag(DemoScript.networkTimeout)
                        }
                        .pickerStyle(.menu)
                        .onChange(of: script) { newValue in
                            paymentService.script = newValue
                        }
                    }

                    Section("PaymentSheet (L1 black-box)") {
                        Text("Presents the SDK sheet: new-card form, 'Save this card', the two mock saved cards (COF one-tap), and an Apple Pay entry row.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        PaySheetButton(
                            checkout: makeCheckout(),
                            sessionId: sessionId,
                            customerAccessSecret: customerAccessSecret,
                            onOutcome: { lastOutcome = describe($0) }
                        )
                    }

                    Section("Standalone ApplePayButton (L3)") {
                        Text(applePayAvailable
                            ? "Available — tap to drive the wallet authorization end-to-end (confirmWallet)."
                            : "Hidden/unavailable (device cannot make payments, or merchant-id not configured).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ApplePayButtonView(
                            checkout: makeCheckout(),
                            sessionId: sessionId,
                            onResult: { lastOutcome = describe($0) },
                            onAvailabilityChange: { applePayAvailable = $0 }
                        )
                        .frame(height: 48)
                        // Still rendered when unavailable (internally isEnabled=false); availability is hinted via copy.
                    }

                    Section("Last outcome") {
                        Text(lastOutcome).font(.body.monospaced())
                    }
                }
                .navigationTitle("Sunbay Checkout Demo")
            }
            .navigationViewStyle(.stack)
        }

        /// Assemble a public entry point with the current mock services.
        ///
        /// Injects the mock via `SunbayCheckout(configuration:paymentService:cofService:)`, i.e. the public
        /// injection seam from Task 11.5. The configuration uses the `.test` environment and gives a placeholder
        /// merchant id so the ApplePayButton's merchant-id factor is satisfied (the device factor may still be false).
        private func makeCheckout() -> SunbayCheckout {
            let config = CheckoutConfiguration(
                environment: .test,
                applePayMerchantId: "merchant.com.sunbay.demo",
                locale: "en-US"
            )
            return SunbayCheckout(
                configuration: config,
                paymentService: paymentService,
                cofService: cofService
            )
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
                return "unknown(sessionId: \(sessionId)) → retrievePayment()"
            }
        }
    }

    // MARK: - PaymentSheet wrapper (SwiftUI button → presents the UIKit payment page)

    /// A SwiftUI button: on tap, `present` the public `PaymentSheet` on the frontmost UIViewController,
    /// and pass back the returned `CheckoutOutcome`. The presentation itself uses the SDK public API, no internal types.
    struct PaySheetButton: View {
        let checkout: SunbayCheckout
        let sessionId: String
        let customerAccessSecret: String
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

    // MARK: - ApplePayButton wrapper (UIKit control → SwiftUI)

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
            // Minimal visible appearance (the SDK control only tints itself, no text).
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return button
        }

        func updateUIView(_ uiView: ApplePayButton, context: Context) {}
    }

    // MARK: - Get the top VC (for present)

    /// Returns the frontmost UIViewController of the current key window (for modally presenting the payment page).
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

#else

    // MARK: - Non-GUI host fallback (e.g. macOS host)

    /// A SwiftPM executable product needs a `main`. On a host without UIKit/SwiftUI (macOS host),
    /// the GUI demo is unavailable; print an explanation and exit, so the executable target compiles and
    /// links on any host (the real run target is the iOS Simulator, see Example/README.md).
    @main
    struct SunbayCheckoutDemoApp {
        static func main() {
            FileHandle.standardError.write(Data(
                "SunbayCheckoutDemo is a UIKit/SwiftUI app; build & run it on the iOS simulator. See Example/README.md.\n".utf8
            ))
        }
    }

#endif
