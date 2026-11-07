#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// New-card page options: address sections can be turned off, and the "Save this card" opt-in
    /// carries a one-line explanation. iOS-only; vacuous on the macOS host.
    @MainActor
    final class NewCardPageOptionsTests: XCTestCase {
        private struct StubAddressService: AddressMetadataService {
            func countries(locale: String?) async throws -> AddressCountryList {
                AddressCountryList(countries: [], detectedCountry: nil)
            }

            func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
                AddressCountryConfig(code: countryCode, fields: [:], layout: [], subdivisions: [])
            }
        }

        private func makeNewCardVC(
            billing: Appearance.AddressCollectionMode, shipping: Appearance.AddressCollectionMode,
            cofEnabled: Bool = false, localize: @escaping (String) -> String = { $0 }
        ) -> CheckoutContentViewController {
            let session = CheckoutSession(
                id: "s", amount: Amount(minorUnits: 100, currencyCode: "USD"), merchantName: "Demo Merchant",
                methods: [.card], expiresAt: Date().addingTimeInterval(600), rsaPublicKey: nil,
                cofEnabled: cofEnabled)
            let vc = CheckoutContentViewController(
                session: session, savedCards: [], appearance: .resolve(.default), localize: localize,
                localeCode: nil, billingMode: billing, shippingMode: shipping,
                addressService: StubAddressService())
            vc.loadViewIfNeeded()
            vc.openNewCardForTest()
            return vc
        }

        private func visibleTexts(in view: UIView) -> [String] {
            var result: [String] = []
            if !view.isHidden, let label = view as? UILabel, let text = label.text { result.append(text) }
            guard !view.isHidden else { return result }
            for sub in view.subviews { result.append(contentsOf: visibleTexts(in: sub)) }
            return result
        }

        func test_shippingOff_hasNoShippingSection() {
            let vc = makeNewCardVC(billing: .simple, shipping: .off)
            let texts = visibleTexts(in: vc.view)
            XCTAssertFalse(texts.contains("SUNBAY.ADDRESS.SHIPPINGTITLE"), "No shipping title when off.")
            XCTAssertFalse(texts.contains("sunbay.address.sameAsBilling"), "No 'Same as billing' when off.")
            XCTAssertTrue(texts.contains("SUNBAY.ADDRESS.BILLINGTITLE"), "Billing is unaffected.")
        }

        func test_billingOff_hasNoBillingSection() {
            let vc = makeNewCardVC(billing: .off, shipping: .off)
            let texts = visibleTexts(in: vc.view)
            XCTAssertFalse(texts.contains("SUNBAY.ADDRESS.BILLINGTITLE"), "No billing title when off.")
            XCTAssertFalse(texts.contains("sunbay.address.country"), "No address fields when off.")
        }

        func test_saveThisCard_showsNeutralOneLineHint() {
            let vc = makeNewCardVC(billing: .off, shipping: .off, cofEnabled: true)
            let texts = visibleTexts(in: vc.view)
            XCTAssertTrue(texts.contains("sunbay.sheet.saveThisCard"), "The opt-in title stays.")
            XCTAssertTrue(texts.contains("sunbay.sheet.saveThisCardHint"), "A one-line hint sits under it.")
            XCTAssertFalse(texts.contains { $0.contains("Demo Merchant") }, "The hint is merchant-neutral.")
        }
    }
#endif
