import Contacts
import PassKit
import XCTest

@testable import SunbayCheckout

final class WalletAuthorizerTests: XCTestCase {
    // MARK: - merchant-id resolution priority (config over session, §7 / §2.1)

    func test_resolveMerchantId_configuredWinsOverSession() {
        XCTAssertEqual(
            resolveMerchantId(configured: "merchant.host", sessionProvided: "merchant.session"),
            "merchant.host"
        )
    }

    func test_resolveMerchantId_fallsBackToSessionWhenNoConfig() {
        XCTAssertEqual(
            resolveMerchantId(configured: nil, sessionProvided: "merchant.session"),
            "merchant.session"
        )
    }

    func test_resolveMerchantId_nilWhenNeitherProvided() {
        XCTAssertNil(resolveMerchantId(configured: nil, sessionProvided: nil))
    }

    // MARK: - CheckoutConfiguration field storage (round-trip)

    func test_checkoutConfiguration_storesValues() {
        #if canImport(UIKit)
            var appearance = Appearance()
            appearance.colors.primary = UIColor(sunbayHex: "#112233")
            let config = CheckoutConfiguration(
                environment: .dev,
                applePayMerchantId: "merchant.host",
                appearance: appearance,
                locale: "zh-CN"
            )
        #else
            let config = CheckoutConfiguration(
                environment: .dev,
                applePayMerchantId: "merchant.host",
                locale: "zh-CN"
            )
        #endif

        XCTAssertEqual(config.environment, .dev)
        XCTAssertEqual(config.applePayMerchantId, "merchant.host")
        #if canImport(UIKit)
            XCTAssertEqual(config.appearance, appearance)
        #endif
        XCTAssertEqual(config.locale, "zh-CN")
    }

    func test_checkoutConfiguration_environmentDefaultsToProduction() {
        // environment defaults to production; developers only pass .dev / .test explicitly.
        let config = CheckoutConfiguration()

        XCTAssertEqual(config.environment, .production)
        XCTAssertNil(config.applePayMerchantId)
        #if canImport(UIKit)
            XCTAssertNil(config.appearance)
        #endif
        XCTAssertNil(config.locale)
    }

    func test_checkoutConfiguration_environmentIsThreeValued() {
        XCTAssertEqual(CheckoutConfiguration(environment: .dev).environment, .dev)
        XCTAssertEqual(CheckoutConfiguration(environment: .test).environment, .test)
        XCTAssertEqual(CheckoutConfiguration(environment: .production).environment, .production)
    }

    // MARK: - canMakePayments is callable (device-dependent value; only assert it does not throw and returns a Bool)

    func test_walletAuthorizer_canMakePayments_isCallable() {
        let result: Bool = WalletAuthorizer().canMakePayments()
        // Do not assert the specific device-dependent true/false; only verify it is callable and returns a Bool.
        _ = result
    }

    // MARK: - Request construction (pure)

    func test_networks_mapsCaseInsensitivelyDropsUnknownAndDuplicates() {
        XCTAssertEqual(
            WalletAuthorizer.networks(from: ["chinaUnionPay", "amex", "discover", "masterCard", "jcb", "visa", "bogus", "visa"]),
            [.chinaUnionPay, .amex, .discover, .masterCard, .JCB, .visa])
        XCTAssertEqual(WalletAuthorizer.networks(from: ["VISA", "MasterCard"]), [.visa, .masterCard])
    }

    func test_capabilities_mapsKnownDropsUnknown() {
        XCTAssertEqual(
            WalletAuthorizer.capabilities(from: ["supports3DS", "supportsCredit", "supportsDebit", "x"]),
            [.threeDSecure, .credit, .debit])
    }

    func test_missingParameters() {
        let authorizer = WalletAuthorizer()
        XCTAssertEqual(authorizer.missingParameters(for: nil), ["supportedNetworks", "merchantCapabilities"])
        XCTAssertEqual(
            authorizer.missingParameters(
                for: ApplePayParams(countryCode: nil, supportedNetworks: ["nope"], merchantCapabilities: ["supports3DS"])),
            ["supportedNetworks"])
        XCTAssertEqual(
            authorizer.missingParameters(
                for: ApplePayParams(countryCode: nil, supportedNetworks: ["visa"], merchantCapabilities: [])),
            ["merchantCapabilities"])
        XCTAssertEqual(
            authorizer.missingParameters(
                for: ApplePayParams(countryCode: nil, supportedNetworks: ["visa"], merchantCapabilities: ["supports3DS"])),
            [])
    }

    private let fullParams = ApplePayParams(
        countryCode: nil, supportedNetworks: ["visa", "amex"], merchantCapabilities: ["supports3DS", "supportsDebit"])

    private func request(
        params: ApplePayParams? = nil, merchantName: String = "Acme",
        contacts: WalletContactRequest = WalletContactRequest(billing: false, shipping: false)
    ) -> PKPaymentRequest {
        WalletAuthorizer.makeRequest(
            amount: Amount(minorUnits: 1299, currencyCode: "USD"), merchantId: "merchant.x",
            merchantName: merchantName, params: params ?? fullParams, contacts: contacts)
    }

    func test_makeRequest_basics() {
        let r = request()
        XCTAssertEqual(r.merchantIdentifier, "merchant.x")
        XCTAssertEqual(r.currencyCode, "USD")
        XCTAssertEqual(r.countryCode, "US")
        XCTAssertEqual(r.supportedNetworks, [.visa, .amex])
        XCTAssertEqual(r.merchantCapabilities, [.threeDSecure, .debit])
        XCTAssertEqual(r.paymentSummaryItems.first?.label, "Acme")
        XCTAssertEqual(r.paymentSummaryItems.first?.amount, NSDecimalNumber(string: "12.99"))
    }

    func test_makeRequest_countryAndLabelFallbacks() {
        let gb = ApplePayParams(
            countryCode: " gb ", supportedNetworks: ["visa"], merchantCapabilities: ["supports3DS"])
        XCTAssertEqual(request(params: gb).countryCode, "GB")
        let blank = ApplePayParams(
            countryCode: "  ", supportedNetworks: ["visa"], merchantCapabilities: ["supports3DS"])
        XCTAssertEqual(request(params: blank).countryCode, "US")
        XCTAssertEqual(request(merchantName: "  ").paymentSummaryItems.first?.label, "Total")
    }

    func test_makeRequest_contactFieldSets() {
        var r = request(contacts: WalletContactRequest(billing: true, shipping: false))
        XCTAssertEqual(r.requiredBillingContactFields, [.postalAddress, .name])
        XCTAssertEqual(r.requiredShippingContactFields, [])
        r = request(contacts: WalletContactRequest(billing: false, shipping: true))
        XCTAssertEqual(r.requiredBillingContactFields, [])
        XCTAssertEqual(r.requiredShippingContactFields, [.postalAddress, .name, .phoneNumber])
        r = request()
        XCTAssertEqual(r.requiredBillingContactFields, [])
        XCTAssertEqual(r.requiredShippingContactFields, [])
    }

    // MARK: - Contact mapping (pure)

    func test_address_fromContact() {
        let contact = PKContact()
        var name = PersonNameComponents()
        name.givenName = "Ada"
        name.familyName = "Lovelace"
        contact.name = name
        let postal = CNMutablePostalAddress()
        postal.street = "1 Main St\nApt 2"
        postal.city = "SF"
        postal.state = "CA"
        postal.postalCode = "94103"
        postal.isoCountryCode = "us"
        contact.postalAddress = postal
        contact.phoneNumber = CNPhoneNumber(stringValue: "+14155550100")

        let address = WalletAuthorizer.address(from: contact)

        XCTAssertEqual(address?.line1, "1 Main St")
        XCTAssertEqual(address?.line2, "Apt 2")
        XCTAssertEqual(address?.country, "US")
        XCTAssertEqual(address?.city, "SF")
        XCTAssertEqual(address?.state, "CA")
        XCTAssertEqual(address?.postalCode, "94103")
        XCTAssertEqual(address?.firstName, "Ada")
        XCTAssertEqual(address?.lastName, "Lovelace")
        XCTAssertEqual(address?.phone, "+14155550100")
    }

    func test_address_emptyOrNilContact_isNil() {
        XCTAssertNil(WalletAuthorizer.address(from: PKContact()))
        XCTAssertNil(WalletAuthorizer.address(from: nil))
    }

    func test_email_fromContact() {
        let contact = PKContact()
        XCTAssertNil(WalletAuthorizer.email(from: contact))
        XCTAssertNil(WalletAuthorizer.email(from: nil))
        contact.emailAddress = " a@b.co "
        XCTAssertEqual(WalletAuthorizer.email(from: contact), "a@b.co")
    }
}
