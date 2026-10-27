import Foundation

// MARK: - Apple Pay on-device probe (Task 14)
//
// Standalone probe: **talks directly to PassKit**, does not depend on the SunbayCheckout SDK target,
// and is not an SDK consumer (does not import SunbayCheckout).
//
// Purpose: validate the Apple Pay **client wallet call chain** — capability detection → system sheet → read
// the encrypted token, producing only redacted diagnostics (token byte length, presence). It **never** prints/logs
// raw token bytes, never sends them to any backend, and never initiates a real transaction (see AGENTS.md §2.3,
// product-spec §3.2 / §6.2).
//
// All merchant/gateway parameters are **placeholder** values, a TEST/placeholder environment. The real
// merchantIdentifier, Apple Pay entitlement, sandbox test account + Wallet test card are configured by the
// developer on a real device (see README.md).

#if canImport(UIKit)

    import PassKit
    import SwiftUI
    import UIKit

    // MARK: - Placeholder configuration (not confidential, committable)

    /// Placeholder merchant/gateway parameters used by the probe. **Not** real credentials — running on a real
    /// device requires the developer to replace merchantIdentifier and enable the Apple Pay capability on the app
    /// target (see README.md).
    enum ProbeConfig {
        /// Placeholder merchant id (on a real device, replace with a real id registered in Apple Developer).
        static let merchantIdentifier = "merchant.com.sunbay.probe"
        /// Placeholder country/region (TEST).
        static let countryCode = "US"
        /// Placeholder currency (TEST).
        static let currencyCode = "USD"
        /// Placeholder summary line: 1.00 (an intuitive value in the smallest currency unit, only to drive the sheet, no real charge).
        static let summaryLabel = "Sunbay Apple Pay Probe"
        static let summaryAmount = NSDecimalNumber(string: "1.00")
        /// Supported card networks (placeholder).
        static let supportedNetworks: [PKPaymentNetwork] = [.visa, .masterCard, .amex]
        /// Merchant capability: 3DS (the minimal PassKit standard set).
        static let merchantCapabilities: PKMerchantCapability = .threeDSecure
    }

    // MARK: - Probe result model (redacted diagnostics only)

    /// A readable result of a single probe run. Contains **no** raw token bytes or sensitive data.
    struct ProbeResult: Equatable {
        /// The result of `PKPaymentAuthorizationController.canMakePayments()`.
        var canMakePayments: Bool
        /// The result of `canMakePayments(usingNetworks:)` (with supported networks).
        var canMakePaymentsUsingNetworks: Bool
        /// Whether the system authorization sheet was successfully presented.
        var sheetPresented: Bool
        /// A readable description of the terminal branch (redacted token diagnostics on authorization success / user cancel / error).
        var branch: String

        static let initial = ProbeResult(
            canMakePayments: false,
            canMakePaymentsUsingNetworks: false,
            sheetPresented: false,
            branch: "—"
        )
    }

    // MARK: - Probe core (PassKit call chain)

    /// An Apple Pay probe talking directly to PassKit.
    ///
    /// Call chain: capability detection → build `PKPaymentRequest` (placeholder parameters) → present
    /// `PKPaymentAuthorizationController` → in the delegate read `payment.token.paymentData`
    /// → produce only redacted diagnostics (length / presence).
    @MainActor
    final class ApplePayProbe: NSObject, PKPaymentAuthorizationControllerDelegate {
        private var controller: PKPaymentAuthorizationController?
        private var completion: ((ProbeResult) -> Void)?
        private var result = ProbeResult.initial
        /// Marks whether the delegate has received the authorization callback (used to distinguish "user cancel" from "authorization success").
        private var didAuthorize = false

        /// Run a single probe. The callback is on the main thread.
        ///
        /// - Parameter completion: a `ProbeResult` with redacted diagnostics.
        func run(completion: @escaping (ProbeResult) -> Void) {
            self.completion = completion
            self.didAuthorize = false
            var r = ProbeResult.initial

            // 1) Capability detection (two APIs).
            r.canMakePayments = PKPaymentAuthorizationController.canMakePayments()
            r.canMakePaymentsUsingNetworks = PKPaymentAuthorizationController
                .canMakePayments(usingNetworks: ProbeConfig.supportedNetworks)
            self.result = r

            // 2) Build the placeholder PKPaymentRequest.
            let request = Self.makeRequest()

            // 3) Present the system authorization sheet.
            let controller = PKPaymentAuthorizationController(paymentRequest: request)
            controller.delegate = self
            self.controller = controller
            controller.present { [weak self] presented in
                Task { @MainActor in
                    guard let self else { return }
                    self.result.sheetPresented = presented
                    if !presented {
                        // The sheet cannot present (device has no capability / no card, etc.) → take the no-card/cancel branch.
                        self.result.branch =
                            "sheet did not present (no Apple Pay capability / no card in Wallet)"
                        self.finish()
                    }
                }
            }
        }

        /// Build a placeholder `PKPaymentRequest` (1.00 summary line, placeholder merchant/gateway parameters).
        private static func makeRequest() -> PKPaymentRequest {
            let request = PKPaymentRequest()
            request.merchantIdentifier = ProbeConfig.merchantIdentifier
            request.countryCode = ProbeConfig.countryCode
            request.currencyCode = ProbeConfig.currencyCode
            request.supportedNetworks = ProbeConfig.supportedNetworks
            request.merchantCapabilities = ProbeConfig.merchantCapabilities
            request.paymentSummaryItems = [
                PKPaymentSummaryItem(
                    label: ProbeConfig.summaryLabel,
                    amount: ProbeConfig.summaryAmount
                ),
            ]
            return request
        }

        /// Pass back the one-off result and clean up.
        private func finish() {
            let out = result
            let cb = completion
            completion = nil
            controller = nil
            cb?(out)
        }

        // MARK: PKPaymentAuthorizationControllerDelegate

        /// User authorization success callback. Reads `payment.token.paymentData` → **only** redacted diagnostics.
        ///
        /// Security constraints (AGENTS.md §2.3, product-spec §3.2 / §5):
        /// never print/log raw token bytes, never send them to any backend, never initiate a real transaction.
        func paymentAuthorizationController(
            _ controller: PKPaymentAuthorizationController,
            didAuthorizePayment payment: PKPayment,
            handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
        ) {
            didAuthorize = true
            let tokenData = payment.token.paymentData
            // Redacted diagnostics only: byte length + presence. Never read out/print raw bytes.
            let present = !tokenData.isEmpty
            result.branch =
                "authorized — token present: \(present ? "yes" : "no"), token byte length: \(tokenData.count) (redacted; raw bytes never logged/sent)"
            // The probe does not run a real transaction: close the sheet directly with success (without sending the token anywhere).
            completion(PKPaymentAuthorizationResult(status: .success, errors: nil))
        }

        /// Sheet-finished callback (user cancel, or system dismiss after the authorization flow completes).
        func paymentAuthorizationControllerDidFinish(
            _ controller: PKPaymentAuthorizationController
        ) {
            controller.dismiss {
                Task { @MainActor in
                    if !self.didAuthorize {
                        // Finished without authorization → user cancel / no-card branch (the expected outcome on the simulator).
                        self.result.branch =
                            "canceled / no-card branch (user dismissed or Wallet has no usable card)"
                    }
                    self.finish()
                }
            }
        }
    }

    // MARK: - Minimal SwiftUI UI

    /// Probe main screen: a button runs the probe, showing canMakePayments, whether presented, redacted token diagnostics / cancel / error branch.
    struct ProbeRootView: View {
        @State private var result = ProbeResult.initial
        @State private var running = false
        private let probe = ApplePayProbe()

        var body: some View {
            NavigationView {
                Form {
                    Section("Capability detection") {
                        row("canMakePayments()", result.canMakePayments ? "true" : "false")
                        row(
                            "canMakePayments(usingNetworks:)",
                            result.canMakePaymentsUsingNetworks ? "true" : "false"
                        )
                    }
                    Section("Sheet") {
                        row("sheet presented", result.sheetPresented ? "yes" : "no")
                    }
                    Section("Result branch (redacted)") {
                        Text(result.branch)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        Button(running ? "Running…" : "Run Apple Pay probe") {
                            running = true
                            probe.run { out in
                                result = out
                                running = false
                            }
                        }
                        .disabled(running)
                        .buttonStyle(.borderedProminent)
                    }
                    Section {
                        Text("This probe validates the CLIENT wallet call chain only (capability → sheet → token). No backend, no real charge, redacted diagnostics only. On the iOS Simulator the token path is limited (no real Wallet card), so the expected result is the cancel/no-card branch; real-device token acquisition must be verified by the developer (see README.md).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Apple Pay Probe")
            }
            .navigationViewStyle(.stack)
        }

        private func row(_ label: String, _ value: String) -> some View {
            HStack {
                Text(label)
                Spacer()
                Text(value).font(.body.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - App entry (iOS)

    /// Standalone probe App entry (SwiftUI, iOS Simulator / real device). Does not depend on SunbayCheckout.
    @main
    struct ApplePayProbeApp: App {
        var body: some Scene {
            WindowGroup {
                ProbeRootView()
            }
        }
    }

#else

    // MARK: - Non-iOS host fallback (macOS host)

    /// A SwiftPM executable product needs a `main`. On a host without UIKit (macOS host),
    /// PassKit's `PKPaymentAuthorizationController` UI path is unavailable; print an explanation and exit,
    /// so the executable target compiles and links on the host too (`swift build` / `swift test` green).
    /// The real run target is the iOS Simulator / real device (see Example/ApplePayProbe/README.md).
    @main
    enum ApplePayProbeApp {
        static func main() {
            FileHandle.standardError.write(Data(
                "ApplePayProbe is an iOS PassKit probe; build & run it on the iOS simulator (expected: cancel/no-card branch) or a real device (full token). See Example/ApplePayProbe/README.md.\n".utf8
            ))
        }
    }

#endif
