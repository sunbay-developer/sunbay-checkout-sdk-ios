#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Verifies the payment page renders localized copy from the injected resolver closure (iOS only;
    /// entirely excluded by `#if canImport(UIKit)` on the macOS host).
    ///
    /// Task 9 replaced the flat `PaymentSheetViewController` with the host-agnostic
    /// `CheckoutContentViewController` (Task 8), which owns all in-sheet copy and renders it through
    /// the same `localize` closure `PaymentSheet` injects. This test repoints onto the content VC and
    /// asserts the localized strings surface in its view hierarchy under a `zh-CN` resolver.
    final class PaymentSheetLocalizationTests: XCTestCase {
        /// Given a zh resolver, the content VC's rendered button/label titles come out localized.
        @MainActor
        func test_content_usesLocalizedTitles_zh() {
            let vc = CheckoutContentViewController(
                session: .demo,
                savedCards: [],
                appearance: .resolve(.default),
                localize: LocalizationResolver(explicitLocale: "zh-CN", systemLanguages: []).localizedNoComment,
                billingMode: .simple,
                shippingMode: .simple,
                addressService: EmptyAddressMetadataService()
            )
            vc.loadViewIfNeeded()
            vc.view.layoutIfNeeded()

            let titles = Self.collectText(in: vc.view)
            // The confirm CTA renders "支付 <amount>" (sunbay.sheet.payAmount) → contains "支付".
            XCTAssertTrue(
                titles.contains { $0.contains("支付") },
                "Expected a localized Pay title; got \(titles)")
        }

        /// Depth-first collects visible `UILabel` / `UIButton` text from a view subtree.
        @MainActor
        private static func collectText(in view: UIView) -> [String] {
            var out: [String] = []
            if let label = view as? UILabel, let text = label.text { out.append(text) }
            if let button = view as? UIButton, let text = button.title(for: .normal) { out.append(text) }
            for sub in view.subviews { out.append(contentsOf: collectText(in: sub)) }
            return out
        }
    }

    // MARK: - Test session factory

    extension CheckoutSession {
        /// A minimal demo session for localization rendering tests. Includes `.applePay`
        /// so the Apple Pay row renders; non-secret values only.
        static var demo: CheckoutSession {
            CheckoutSession(
                id: "sess_demo",
                amount: Amount(minorUnits: 999, currencyCode: "USD"),
                merchantName: "Acme",
                methods: [.card, .applePay],
                expiresAt: Date().addingTimeInterval(600),
                rsaPublicKey: nil,
                cofEnabled: false
            )
        }
    }
#endif
