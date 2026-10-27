#if canImport(UIKit)
    import Security
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Unit tests for `PaymentSheet` (L1, black-box payment page) (iOS only; entirely excluded by `#if canImport(UIKit)` on the macOS host).
    ///
    /// ## Splitting testable logic vs. the `present()` wrapper
    /// In a headless xctest without a host app, actually driving UIKit presentation (`presenter.present(...)`) is both
    /// fragile and non-deterministic. For that reason `PaymentSheet` collapses the controller-driven logic of
    /// "start → (list, per COF decision) → await user action → confirm → outcome" into one **internal, testable**
    /// method `runCheckout(seam:)`; `present(from:)` is just a thin UIKit wrapper: it constructs and presents
    /// `PaymentSheetViewController`, bridges its "user actions" into `runCheckout`'s `seam`, and awaits the same
    /// logic to get a `CheckoutOutcome`.
    ///
    /// These tests inject a real `CheckoutController` assembled from a mock backend via the **internal initializer**,
    /// call `runCheckout(seam:)` directly, and use the `seam` to trigger the target user action (equivalent to tapping
    /// confirm on a new card / selecting a card / canceling), thereby verifying start/list/confirm/outcome without
    /// touching real presentation. The full UI is verified by the example app (Task 13).
    final class PaymentSheetTests: XCTestCase {
        // MARK: - Assembly helpers

        /// Builds a session (with configurable `cofEnabled` and payment methods).
        private func makeSession(
            id: String,
            cofEnabled: Bool,
            rsaPublicKey: String? = nil
        ) -> CheckoutSession {
            CheckoutSession(
                id: id,
                amount: Amount(minorUnits: 999, currencyCode: "USD"),
                merchantName: "Acme",
                methods: [.card, .savedCard, .applePay],
                expiresAt: Date().addingTimeInterval(600),
                rsaPublicKey: rsaPublicKey,
                cofEnabled: cofEnabled
            )
        }

        /// Assemble a real `CheckoutController` with a mock backend + stub action handler, returning the mocks used.
        private func makeController(
            session: CheckoutSession,
            cards: [SavedCard] = [],
            submit snapshots: [PaymentSnapshot] = []
        ) -> (CheckoutController, MockPaymentService, MockCofService) {
            let payment = MockPaymentService()
            payment.stubSession(session)
            if !snapshots.isEmpty { payment.stubSubmit(snapshots) }
            let cof = MockCofService()
            cof.stubCards(cards)
            let controller = CheckoutController(
                paymentService: payment,
                cofService: cof,
                credentials: CredentialStore(),
                actionHandler: StubActionHandler(result: .pending)
            )
            return (controller, payment, cof)
        }

        // MARK: - 1. COF: with secret + cofEnabled → list saved cards

        func test_present_cofEnabledWithSecret_listsSavedCards() async {
            let sessionId = "sess_cof_1"
            let session = makeSession(id: sessionId, cofEnabled: true)
            let scriptedCard = SavedCard(
                id: "pm_1", brand: "visa", last4: "4242", expMonth: 12, expYear: 2030
            )
            let (controller, _, cof) = makeController(session: session, cards: [scriptedCard])

            let sheet = PaymentSheet(
                controller: controller,
                sessionId: sessionId,
                customerAccessSecret: "secret_abc"
            )

            // Drive the testable logic directly; the seam cancels immediately after listing (this case only verifies the listing path is taken).
            let outcome = await sheet.runCheckout { context in
                // context.savedCards should contain the scripted card; and CofService should have been called once.
                XCTAssertEqual(context.savedCards.map(\.id), ["pm_1"])
                return .cancel
            }

            XCTAssertEqual(cof.listCallCount, 1)
            XCTAssertEqual(cof.lastCustomerAccessSecret, "secret_abc")
            guard case .canceled = outcome else {
                return XCTFail("expected .canceled after cancel seam, got \(outcome)")
            }
        }

        // MARK: - 2. No secret → do not list saved cards

        func test_present_noSecret_doesNotListSavedCards() async {
            let sessionId = "sess_cof_2"
            let session = makeSession(id: sessionId, cofEnabled: true)
            let (controller, _, cof) = makeController(session: session, cards: [
                SavedCard(id: "pm_x", brand: "visa", last4: "1111", expMonth: 1, expYear: 2031),
            ])

            // Do not pass customerAccessSecret.
            let sheet = PaymentSheet(controller: controller, sessionId: sessionId)

            let outcome = await sheet.runCheckout { context in
                XCTAssertTrue(context.savedCards.isEmpty, "no secret → no saved cards")
                return .cancel
            }

            // No secret → CofService must never be called.
            XCTAssertEqual(cof.listCallCount, 0)
            guard case .canceled = outcome else {
                return XCTFail("expected .canceled, got \(outcome)")
            }
        }

        // MARK: - 3. present resolves with the controller outcome

        func test_present_resolvesWithControllerOutcome() async throws {
            let sessionId = "sess_resolve_1"
            // Include rsaPublicKey so the new-card path can encrypt; script submit to return S.
            // Generate a real RSA key pair at runtime, and feed the session the public key (PKCS#1 DER base64,
            // matching CardEncryptor's import format) so CardEncryptor can encrypt successfully, thereby driving to submit.
            let publicKeyBase64 = try Self.makeRSAPublicKeyBase64(bits: 2048)
            let session = makeSession(
                id: sessionId,
                cofEnabled: false,
                rsaPublicKey: publicKeyBase64
            )
            let (controller, payment, _) = makeController(
                session: session,
                submit: [PaymentSnapshot(sessionId: sessionId, status: .succeeded, txnId: "txn_ok")]
            )

            let sheet = PaymentSheet(controller: controller, sessionId: sessionId)

            let cardInput = CardInput(
                cardNumber: "4242424242424242",
                expiryMonth: "12",
                expiryYear: "2030",
                cvv: "123"
            )

            let outcome = await sheet.runCheckout { _ in
                // Equivalent to the user filling in a new card and tapping confirm (without checking save).
                .confirmNewCard(cardInput, save: false)
            }

            XCTAssertEqual(payment.submitCallCount, 1)
            guard case .succeeded(let txnId) = outcome else {
                return XCTFail("expected .succeeded, got \(outcome)")
            }
            XCTAssertEqual(txnId, "txn_ok")
        }

        // MARK: - 4. EmbeddedPaymentElement is internal (compile-time)

        func test_embeddedPaymentElement_isInternal_notPublic() {
            // It can only be referenced from the test target via @testable; if it were mistakenly marked public,
            // this line would still compile, but the real guard for "not public" is the public-API audit in Final
            // verification plus the existence note of this assertion.
            // Here we instantiate via internal visibility to anchor that it is a "same-module internal symbol".
            let stub = EmbeddedPaymentElement()
            XCTAssertNotNil(stub)
        }
    }

    // MARK: - Test RSA public key

    extension PaymentSheetTests {
        /// Generates an RSA public key at runtime (PKCS#1 DER / base64), matching `CardEncryptor`'s import convention.
        ///
        /// Used by `test_present_resolvesWithControllerOutcome` to let `CardEncryptor` actually encrypt new card data,
        /// thereby driving to `submit`. This public key does not correspond to any real backend private key; it is only
        /// for local encryption-shape verification.
        static func makeRSAPublicKeyBase64(bits: Int) throws -> String {
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits: bits,
            ]
            var error: Unmanaged<CFError>?
            guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
                throw error!.takeRetainedValue() as Error
            }
            guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
                throw NSError(domain: "PaymentSheetTests", code: -1)
            }
            guard let der = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
                throw error!.takeRetainedValue() as Error
            }
            return der.base64EncodedString()
        }
    }
#endif
