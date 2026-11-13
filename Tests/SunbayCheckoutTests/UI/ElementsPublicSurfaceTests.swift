#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Guards the public surface of the Elements: no reachable stored property exposes card input, user
    /// actions or wallet authorizations, and a typed card number never shows up in any public value.
    @MainActor
    final class ElementsPublicSurfaceTests: XCTestCase {
        private let pan = "4242424242424242"
        private let forbiddenTypeNames = ["CardInput", "CheckoutUserAction", "WalletAuthorization"]

        private func makeElements(id: String) async throws -> CheckoutElements {
            let payment = MockPaymentService()
            payment.stubSession(
                CheckoutSession(
                    id: id, amount: Amount(minorUnits: 999, currencyCode: "USD"), merchantName: "Acme",
                    methods: [.card, .savedCard, .applePay], expiresAt: Date().addingTimeInterval(600),
                    rsaPublicKey: nil, cofEnabled: true, collectBillingAddress: false,
                    collectShippingAddress: false))
            let controller = CheckoutController(
                paymentService: payment, cofService: MockCofService(), credentials: CredentialStore(),
                actionHandler: StubActionHandler(result: .pending))
            return try await CheckoutElements.create(
                controller: controller, sessionId: id,
                walletAuthorizer: MockWalletAuthorizer(canMake: true, outcome: .success(Data([1]))),
                walletMerchantId: "merchant.com.acme")
        }

        /// Recursively walks the object graph of `subject` (all stored properties of any visibility, through
        /// optionals, collections, enum payloads, tuples and class references) and returns one violation per
        /// forbidden type name or PAN-bearing string (compared on digits only, so the formatted
        /// "4242 4242 …" form is caught too). UIKit objects (views, layers, responders) are not entered:
        /// the card field legitimately holds the PAN. Closure captures are not reflectable by `Mirror`,
        /// but closure-typed properties' types are checked by name.
        private func violations(in subject: Any, name: String, maxDepth: Int = 12) -> [String] {
            var found: [String] = []
            var visited = Set<ObjectIdentifier>()

            func isUIKitObject(_ value: Any) -> Bool {
                value is UIView || value is UIResponder || value is CALayer || value is UIImage
            }

            func digits(_ text: String) -> String { text.filter(\.isNumber) }

            func walk(_ value: Any, path: String, depth: Int) {
                guard depth <= maxDepth else { return }
                let mirror = Mirror(reflecting: value)
                let typeName = String(reflecting: mirror.subjectType)
                for forbidden in forbiddenTypeNames where typeName.contains(forbidden) {
                    found.append("\(path) has type \(typeName)")
                }
                if let text = value as? String, digits(text).contains(pan) {
                    found.append("\(path) contains the PAN")
                    return
                }
                if let text = value as? Substring, digits(String(text)).contains(pan) {
                    found.append("\(path) contains the PAN")
                    return
                }
                if mirror.displayStyle == .class {
                    if isUIKitObject(value) { return }
                    let object = value as AnyObject
                    guard visited.insert(ObjectIdentifier(object)).inserted else { return }
                }
                for child in mirror.children {
                    walk(child.value, path: "\(path).\(child.label ?? "?")", depth: depth + 1)
                }
                if let parent = mirror.superclassMirror {
                    for child in parent.children {
                        walk(child.value, path: "\(path).\(child.label ?? "?")", depth: depth + 1)
                    }
                }
            }

            walk(subject, path: name, depth: 0)
            return found
        }

        private func assertClean(_ subject: Any, name: String, file: StaticString = #filePath, line: UInt = #line) {
            for violation in violations(in: subject, name: name) {
                XCTFail(violation, file: file, line: line)
            }
            XCTAssertFalse(digitsOnly(String(describing: subject)).contains(pan), "\(name) description", file: file, line: line)
            XCTAssertFalse(digitsOnly(String(reflecting: subject)).contains(pan), "\(name) debug description", file: file, line: line)
        }

        private func digitsOnly(_ text: String) -> String { text.filter(\.isNumber) }

        // MARK: - The walker itself is not vacuous

        private struct LeakyInner { let shown = "Card 4242 4242 4242 4242" }
        private struct CardInput {}
        private final class LeakyMiddle {
            let items: [Int: LeakyInner?] = [1: LeakyInner()]
        }
        private final class LeakyRoot {
            let middle = LeakyMiddle()
        }
        private final class TypeLeakRoot {
            let nested: [CardInput] = [CardInput()]
        }

        func test_walker_catchesAFormattedPANDeepInsideTheGraph() {
            let found = violations(in: LeakyRoot(), name: "Fake")
            XCTAssertEqual(found.count, 1, "\(found)")
            XCTAssertTrue(found.first?.contains("contains the PAN") ?? false)
        }

        func test_walker_catchesAForbiddenTypeNestedInACollection() {
            XCTAssertFalse(violations(in: TypeLeakRoot(), name: "Fake").isEmpty)
        }

        func test_walker_doesNotEnterUIKitObjects() {
            let field = UITextField()
            field.text = pan
            XCTAssertTrue(violations(in: [field], name: "Views").isEmpty)
        }

        func test_publicObjects_exposeNoCardInputActionsAuthorizationsOrTypedPAN() async throws {
            let elements = try await makeElements(id: "s_surface")
            let express = elements.makeExpressCheckoutElement()
            let card = elements.makeCardElement()
            let entry = try XCTUnwrap(card.newCardEntryForTest)
            entry.typePANForTest(pan)
            entry.fillCardForTest()

            // Non-vacuity: the PAN really is held internally (in the field, formatted) before the negative checks.
            XCTAssertEqual(entry.panTextForTest.filter(\.isNumber), pan, "the typing helper must put the PAN in the field")

            let option = try XCTUnwrap(elements.paymentOption)
            XCTAssertFalse(option.label.contains(pan))
            XCTAssertFalse(option.label.contains(where: \.isNumber), "a typed card shows its brand only")

            assertClean(elements, name: "CheckoutElements")
            assertClean(express, name: "ExpressCheckoutElement")
            assertClean(card, name: "CardElement")
            assertClean(option, name: "PaymentOptionDisplayData")
        }
    }
#endif
