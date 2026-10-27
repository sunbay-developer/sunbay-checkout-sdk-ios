#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Verifies `PaymentSheetViewController` renders localized titles from the injected
    /// resolver closure (iOS only; entirely excluded by `#if canImport(UIKit)` on the macOS host).
    final class PaymentSheetLocalizationTests: XCTestCase {
        /// Given a zh resolver, the VC's rendered button/label titles come out localized.
        func test_viewController_usesLocalizedTitles_zh() {
            let vc = PaymentSheetViewController(
                session: .demo,
                savedCards: [],
                localize: LocalizationResolver(explicitLocale: "zh-CN", systemLanguages: []).localizedNoComment
            )
            vc.loadViewIfNeeded()
            XCTAssertTrue(vc.renderedTitles().contains("支付"))
            XCTAssertTrue(vc.renderedTitles().contains("取消"))
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
