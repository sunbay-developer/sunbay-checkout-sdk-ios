#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Reproduces the host that pins the element's height from `cardElementDidUpdateHeight` only (as the
    /// SwiftUI demo does): after the async address form loads, the pinned height must follow the content.
    @MainActor
    final class CardElementLayoutTests: XCTestCase {
        private struct SlowAddressService: AddressMetadataService {
            func countries(locale: String?) async throws -> AddressCountryList {
                try await Task.sleep(nanoseconds: 150_000_000)
                return AddressCountryList(
                    countries: [AddressCountry(code: "US", name: "United States")], detectedCountry: "US")
            }

            func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
                func field(_ type: AddressFieldType, _ label: String) -> AddressFieldConfig {
                    AddressFieldConfig(type: type, required: true, pattern: nil, label: label, placeholder: label)
                }
                return AddressCountryConfig(
                    code: countryCode,
                    fields: [
                        .country: field(.country, "Country"), .line1: field(.line1, "Address"),
                        .postalCode: field(.postalCode, "ZIP code"),
                    ],
                    layout: [[.country], [.line1], [.postalCode]], subdivisions: [])
            }
        }

        /// Pins the card view's height like a SwiftUI `.frame(height:)`; updates ONLY from the delegate.
        private final class PinningHost: CardElementDelegate {
            let pin: NSLayoutConstraint
            var updates = 0
            init(pin: NSLayoutConstraint) { self.pin = pin }
            func cardElementDidUpdateHeight(_ element: CardElement) {
                updates += 1
                pin.constant = element.view.intrinsicContentSize.height
            }
        }

            private func fieldContainers(in root: UIView) -> [FieldContainerView] {
            var found: [FieldContainerView] = []
            func walk(_ view: UIView) {
                if let box = view as? FieldContainerView { found.append(box) }
                view.subviews.forEach(walk)
            }
            walk(root)
            return found
        }

        func test_addressLoadAfterLayout_pinnedHostHeightFollowsContent_andNoFieldIsCompressed() async throws {
            let id = "s_layout_async"
            let payment = MockPaymentService()
            payment.stubSession(
                CheckoutSession(
                    id: id, amount: Amount(minorUnits: 999, currencyCode: "USD"), merchantName: "Acme",
                    methods: [.card], expiresAt: Date().addingTimeInterval(600), rsaPublicKey: nil,
                    cofEnabled: false, collectBillingAddress: true, collectShippingAddress: false))
            let controller = CheckoutController(
                paymentService: payment, cofService: MockCofService(), credentials: CredentialStore(),
                actionHandler: StubActionHandler(result: .pending))
            var configuration = CheckoutElements.Configuration()
            configuration.customerAccessSecret = "secret_abc"
            let elements = try await CheckoutElements.create(
                controller: controller, sessionId: id, configuration: configuration, appearance: .default,
                walletAuthorizer: MockWalletAuthorizer(canMake: false, outcome: .success(Data([1]))),
                walletMerchantId: nil, paymentMethodFilter: PaymentMethodFilter(),
                addressService: SlowAddressService())
            let card = elements.makeCardElement()

            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 1600))
            let controllerVC = UIViewController()
            window.rootViewController = controllerVC
            window.makeKeyAndVisible()
            let view = card.view
            view.translatesAutoresizingMaskIntoConstraints = false
            controllerVC.view.addSubview(view)
            let pin = view.heightAnchor.constraint(equalToConstant: view.intrinsicContentSize.height)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: controllerVC.view.topAnchor),
                view.leadingAnchor.constraint(equalTo: controllerVC.view.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: controllerVC.view.trailingAnchor),
                pin,
            ])
            let host = PinningHost(pin: pin)
            card.delegate = host
            window.layoutIfNeeded()

            try await Task.sleep(nanoseconds: 600_000_000)  // the address metadata answers after ~150 ms
            window.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            window.layoutIfNeeded()

            let fitting = view.subviews[0].systemLayoutSizeFitting(
                CGSize(width: 375, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
            ).height
            let boxes = fieldContainers(in: view)
            XCTAssertEqual(pin.constant, fitting, accuracy: 1, "host height must follow the loaded content")
            XCTAssertGreaterThan(host.updates, 0, "the delegate must hear about the growth")
            let heights = Set(boxes.map { Int($0.frame.height.rounded()) })
            XCTAssertGreaterThan(boxes.count, 2)
            XCTAssertEqual(heights.count, 1, "every field box has the same height, got \(heights)")
        }
    }
#endif
