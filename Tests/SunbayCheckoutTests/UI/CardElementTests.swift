#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Tests for `CardElement` and the `CheckoutElements.confirm()` / `paymentOption` wiring (iOS only).
    ///
    /// A real `CheckoutController` is assembled from the mock backend; nothing needs the network. Card
    /// values used here are the public test PAN 4242… and a fixed far-future expiry.
    @MainActor
    final class CardElementTests: XCTestCase {
        private final class DelegateSpy: CardElementDelegate {
            var heightUpdates = 0
            var selectionChanges = 0
            var completenessChanges = 0
            func cardElementDidUpdateHeight(_ element: CardElement) { heightUpdates += 1 }
            func cardElementDidChangeSelection(_ element: CardElement) { selectionChanges += 1 }
            func cardElementDidChangeCompleteness(_ element: CardElement) { completenessChanges += 1 }
        }

        private struct PostalAddressService: AddressMetadataService {
            func countries(locale: String?) async throws -> AddressCountryList {
                AddressCountryList(countries: [AddressCountry(code: "US", name: "United States")], detectedCountry: "US")
            }

            func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
                func field(_ type: AddressFieldType, _ label: String) -> AddressFieldConfig {
                    AddressFieldConfig(type: type, required: true, pattern: nil, label: label, placeholder: label)
                }
                return AddressCountryConfig(
                    code: countryCode,
                    fields: [
                        .country: field(.country, "Country"), .line1: field(.line1, "Address"),
                        .postalCode: field(.postalCode, "ZIP"),
                    ],
                    layout: [[.country], [.line1], [.postalCode]], subdivisions: [])
            }
        }

        private let usable = SavedCard(id: "pm_ok", brand: "visa", last4: "4242", expMonth: 12, expYear: 2099)
        private let usable2 = SavedCard(id: "pm_ok2", brand: "mastercard", last4: "5454", expMonth: 11, expYear: 2099)
        private let expired = SavedCard(id: "pm_old", brand: "visa", last4: "0001", expMonth: 1, expYear: 2020)

        // MARK: - Assembly helpers

        private func makeElements(
            id: String, cards: [SavedCard] = [], billing: Bool = false, shipping: Bool = false,
            submit: [PaymentSnapshot] = [], submitDelay: Duration? = nil, withKey: Bool = false,
            filter: PaymentMethodFilter = PaymentMethodFilter(), appearance: Appearance = .default
        ) async throws -> (CheckoutElements, MockPaymentService) {
            let payment = MockPaymentService()
            payment.stubSession(
                CheckoutSession(
                    id: id, amount: Amount(minorUnits: 999, currencyCode: "USD"), merchantName: "Acme",
                    methods: [.card, .savedCard], expiresAt: Date().addingTimeInterval(600),
                    rsaPublicKey: withKey ? try PaymentSheetTests.makeRSAPublicKeyBase64(bits: 2048) : nil,
                    cofEnabled: true, collectBillingAddress: billing, collectShippingAddress: shipping))
            if !submit.isEmpty { payment.stubSubmit(submit) }
            if let submitDelay { payment.stubSubmitDelay(submitDelay) }
            let cof = MockCofService()
            cof.stubCards(cards)
            let controller = CheckoutController(
                paymentService: payment, cofService: cof, credentials: CredentialStore(),
                actionHandler: StubActionHandler(result: .pending))
            var configuration = CheckoutElements.Configuration()
            configuration.customerAccessSecret = "secret_abc"
            let elements = try await CheckoutElements.create(
                controller: controller, sessionId: id, configuration: configuration, appearance: appearance,
                walletAuthorizer: MockWalletAuthorizer(canMake: false, outcome: .success(Data([1]))),
                walletMerchantId: nil, paymentMethodFilter: filter, addressService: PostalAddressService())
            return (elements, payment)
        }

        private func snapshot(_ id: String, _ status: TxnStatus, txn: String = "txn_1") -> PaymentSnapshot {
            PaymentSnapshot(sessionId: id, status: status, txnId: txn)
        }

        // MARK: - Saved cards

        func test_savedCards_defaultSelectsFirstUsable_andPaymentOptionIsServerLabel() async throws {
            let (elements, _) = try await makeElements(id: "s_saved", cards: [expired, usable, usable2])
            let card = elements.makeCardElement()
            XCTAssertTrue(card.isAvailable)
            XCTAssertTrue(card.isComplete)
            XCTAssertEqual(card.selectedSavedCardIdForTest, "pm_ok")
            XCTAssertFalse(card.isNewCardFormVisibleForTest, "the form stays collapsed behind the New card row")
            let option = try XCTUnwrap(elements.paymentOption)
            XCTAssertEqual(option.label, "Visa ····4242")
            XCTAssertEqual(option.paymentMethodType, "CARD")
        }

        func test_expiredSavedCard_notSelectable() async throws {
            let (elements, _) = try await makeElements(id: "s_expired", cards: [usable, expired])
            let card = elements.makeCardElement()
            card.tapSavedCardForTest("pm_old")
            XCTAssertEqual(card.selectedSavedCardIdForTest, "pm_ok", "an expired card never takes the selection")
            XCTAssertEqual(elements.paymentOption?.label, "Visa ····4242")
        }

        func test_selectingAnotherSavedCard_updatesOptionAndNotifiesDelegate() async throws {
            let (elements, _) = try await makeElements(id: "s_switch", cards: [usable, usable2])
            let card = elements.makeCardElement()
            let spy = DelegateSpy()
            card.delegate = spy
            card.tapSavedCardForTest("pm_ok2")
            XCTAssertEqual(elements.paymentOption?.label, "Mastercard ····5454")
            XCTAssertEqual(spy.selectionChanges, 1)
        }

        func test_noSavedCards_showsFormDirectly() async throws {
            let (elements, _) = try await makeElements(id: "s_none")
            let card = elements.makeCardElement()
            XCTAssertEqual(card.savedRowCountForTest, 0)
            XCTAssertTrue(card.isNewCardFormVisibleForTest)
            XCTAssertNotNil(card.newCardEntryForTest)
            XCTAssertFalse(card.isComplete)
            XCTAssertNil(elements.paymentOption)
        }

        func test_groupCarriesTheInjectedRulesService() async throws {
            struct Marker: CardRulesService {
                func fetchRules(ifNoneMatch etag: String?) async throws -> CardRulesFetchResult { .notModified }
            }
            let payment = MockPaymentService()
            payment.stubSession(
                CheckoutSession(
                    id: "s_rules", amount: Amount(minorUnits: 999, currencyCode: "USD"), merchantName: "Acme",
                    methods: [.card], expiresAt: Date().addingTimeInterval(600), rsaPublicKey: nil,
                    cofEnabled: false, collectBillingAddress: false, collectShippingAddress: false))
            let controller = CheckoutController(
                paymentService: payment, cofService: MockCofService(), credentials: CredentialStore(),
                actionHandler: StubActionHandler(result: .pending))
            let elements = try await CheckoutElements.create(
                controller: controller, sessionId: "s_rules",
                walletAuthorizer: MockWalletAuthorizer(canMake: false, outcome: .success(Data([1]))),
                walletMerchantId: nil, cardRulesService: Marker())
            XCTAssertTrue(elements.cardRulesService is Marker)
        }

        func test_secondMakeCardElement_returnsTheSameInstance() async throws {
            let (elements, _) = try await makeElements(id: "s_same")
            XCTAssertTrue(elements.makeCardElement() === elements.makeCardElement())
        }

        // MARK: - paymentOption (new card)

        func test_typedCard_paymentOptionIsBrandOnly_noDigits() async throws {
            let (elements, _) = try await makeElements(id: "s_typed")
            let card = elements.makeCardElement()
            let entry = try XCTUnwrap(card.newCardEntryForTest)
            entry.typePANForTest("4242424242424242")
            XCTAssertNil(elements.paymentOption, "nil while the form is incomplete")
            entry.fillCardForTest()
            let option = try XCTUnwrap(elements.paymentOption)
            XCTAssertEqual(option.label, "Visa")
            XCTAssertFalse(option.label.contains(where: \.isNumber))
            XCTAssertEqual(option.paymentMethodType, "CARD")
        }

        // MARK: - confirm

        func test_confirm_savedCard_submitsConfirmSavedCard() async throws {
            let id = "s_confirm_saved"
            let (elements, payment) = try await makeElements(
                id: id, cards: [usable], submit: [snapshot(id, .succeeded)])
            _ = elements.makeCardElement()
            let outcome = await elements.confirm()
            XCTAssertEqual(outcome, .succeeded(txnId: "txn_1"))
            XCTAssertEqual(payment.submitCallCount, 1)
        }

        func test_confirm_newCardValid_submitsEncryptedCard_once() async throws {
            let id = "s_confirm_new"
            let (elements, payment) = try await makeElements(
                id: id, submit: [snapshot(id, .succeeded)], withKey: true)
            let card = elements.makeCardElement()
            card.newCardEntryForTest?.fillCardForTest()
            XCTAssertTrue(card.isComplete)
            let outcome = await elements.confirm()
            XCTAssertEqual(outcome, .succeeded(txnId: "txn_1"))
            XCTAssertEqual(payment.submitCallCount, 1)
        }

        func test_confirm_invalidCard_returnsCardInputInvalid_andDoesNotSubmit() async throws {
            let id = "s_invalid"
            let (elements, payment) = try await makeElements(id: id, submit: [snapshot(id, .succeeded)])
            let card = elements.makeCardElement()
            let outcome = await elements.confirm()
            guard case let .failed(_, error) = outcome else { return XCTFail("expected .failed, got \(outcome)") }
            XCTAssertEqual(error.code, "CARD_INPUT_INVALID")
            XCTAssertEqual(error.category, .validation)
            XCTAssertEqual(payment.submitCallCount, 0)
            XCTAssertTrue(card.newCardEntryForTest?.hasCardFieldError ?? false, "inline errors are shown")
        }

        func test_confirm_noSelection_returnsNoPaymentOptionSelected() async throws {
            let id = "s_nosel"
            let (elements, payment) = try await makeElements(id: id, cards: [expired])
            // No card component at all.
            var outcome = await elements.confirm()
            guard case let .failed(_, error) = outcome else { return XCTFail("expected .failed, got \(outcome)") }
            XCTAssertEqual(error.code, "NO_PAYMENT_OPTION_SELECTED")
            XCTAssertEqual(error.category, .validation)
            // A card component whose only saved card is expired: nothing is selected.
            let card = elements.makeCardElement()
            XCTAssertNil(card.selectedSavedCardIdForTest)
            XCTAssertNil(elements.paymentOption)
            outcome = await elements.confirm()
            guard case let .failed(_, again) = outcome else { return XCTFail("expected .failed, got \(outcome)") }
            XCTAssertEqual(again.code, "NO_PAYMENT_OPTION_SELECTED")
            XCTAssertEqual(payment.submitCallCount, 0)
        }

        func test_confirm_failed_keepsFormForRetry_secondConfirmSubmitsAgain() async throws {
            let id = "s_retry"
            let (elements, payment) = try await makeElements(
                id: id, submit: [snapshot(id, .failed), snapshot(id, .succeeded)], withKey: true)
            let card = elements.makeCardElement()
            card.newCardEntryForTest?.fillCardForTest()
            let first = await elements.confirm()
            guard case .failed = first else { return XCTFail("expected .failed, got \(first)") }
            XCTAssertTrue(card.isComplete, "the typed card survives a failure")
            XCTAssertTrue(card.newCardEntryForTest?.isCardFormInteractive ?? false)
            let second = await elements.confirm()
            XCTAssertEqual(second, .succeeded(txnId: "txn_1"))
            XCTAssertEqual(payment.submitCallCount, 2)
        }

        func test_confirm_succeeded_clearsFormAndDisables() async throws {
            let id = "s_done"
            let (elements, payment) = try await makeElements(
                id: id, billing: true, submit: [snapshot(id, .succeeded)], withKey: true)
            let card = elements.makeCardElement()
            let entry = try XCTUnwrap(card.newCardEntryForTest)
            try await Task.sleep(nanoseconds: 200_000_000)  // let the async address metadata load finish
            entry.fillCardForTest(awaitingAddressLoad: false)
            (entry.billingAddressView as? DynamicAddressFormView)?.fillForTest(
                country: "US", line1: "1 Main", postalCode: "94107")
            XCTAssertTrue(card.isComplete)
            XCTAssertNotNil(entry.makeConfirmAction(), "the card and the address form are valid")
            let outcome = await elements.confirm()
            XCTAssertEqual(outcome, .succeeded(txnId: "txn_1"))
            XCTAssertFalse(card.isComplete, "the form was cleared")
            XCTAssertFalse(entry.isCardFormInteractive, "and disabled")
            XCTAssertNil((entry.billingAddressView as? DynamicAddressFormView)?.addressInput.line1)
            XCTAssertFalse(card.isInteractiveForTest)
            // A later confirm returns the stored outcome and never submits again.
            let again = await elements.confirm()
            XCTAssertEqual(again, .succeeded(txnId: "txn_1"))
            XCTAssertEqual(payment.submitCallCount, 1)
        }

        func test_confirm_pending_staysLocked_returnsStoredOutcome() async throws {
            let id = "s_pending"
            let (elements, payment) = try await makeElements(
                id: id, submit: [snapshot(id, .initial)], withKey: true)
            let card = elements.makeCardElement()
            card.newCardEntryForTest?.fillCardForTest()
            let first = await elements.confirm()
            guard case .pending = first else { return XCTFail("expected .pending, got \(first)") }
            XCTAssertFalse(card.isInteractiveForTest)
            let second = await elements.confirm()
            XCTAssertEqual(second, first)
            XCTAssertEqual(payment.submitCallCount, 1)
        }

        // MARK: - Address precedence

        func test_addressMode_off_hidesForm_butCannotForceOnWhenGlobalOff() async throws {
            // Session collects billing, global on, component automatic: shown.
            let (shown, _) = try await makeElements(id: "s_addr_a", billing: true)
            XCTAssertTrue(shown.makeCardElement().newCardEntryForTest?.billingFormShown ?? false)

            // Component .off hides it.
            let (off, _) = try await makeElements(id: "s_addr_b", billing: true)
            var configuration = CardElement.Configuration()
            configuration.billingAddress = .off
            XCTAssertFalse(off.makeCardElement(configuration).newCardEntryForTest?.billingFormShown ?? true)

            // Global switch off: `.automatic` stays off (the component can never force a form on).
            var appearance = Appearance()
            appearance.billingAddressEnabled = false
            let (global, _) = try await makeElements(id: "s_addr_c", billing: true, appearance: appearance)
            XCTAssertFalse(global.makeCardElement().newCardEntryForTest?.billingFormShown ?? true)

            // The backend decides: a session that does not collect shipping shows none.
            let (backend, _) = try await makeElements(id: "s_addr_d", billing: true, shipping: false)
            let entry = backend.makeCardElement().newCardEntryForTest
            XCTAssertTrue(entry?.billingFormShown ?? false)
            XCTAssertFalse(entry?.shippingFormShown ?? true)
        }

        func test_clear_resetsTypedCardAndAddress() async throws {
            let (elements, _) = try await makeElements(id: "s_clear", billing: true)
            let card = elements.makeCardElement()
            let entry = try XCTUnwrap(card.newCardEntryForTest)
            try await Task.sleep(nanoseconds: 200_000_000)  // let the async address metadata load finish
            entry.fillCardForTest(awaitingAddressLoad: false)
            let form = entry.billingAddressView as? DynamicAddressFormView
            form?.fillForTest(country: "US", line1: "1 Main", postalCode: "94107")
            XCTAssertTrue(card.isComplete)
            card.clear()
            XCTAssertFalse(card.isComplete)
            XCTAssertNil(form?.addressInput.line1)
            XCTAssertNil(form?.addressInput.postalCode)
        }

        // MARK: - Availability

        func test_cardHiddenByFilter_isUnavailable_zeroHeight() async throws {
            let (elements, _) = try await makeElements(
                id: "s_hidden", cards: [usable], filter: PaymentMethodFilter(hide: ["CARD"]))
            let card = elements.makeCardElement()
            XCTAssertFalse(card.isAvailable)
            XCTAssertNil(card.newCardEntryForTest, "no form is built")
            XCTAssertEqual(card.view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height, 0)
            XCTAssertEqual(card.view.intrinsicContentSize.height, 0)
            XCTAssertNil(elements.paymentOption)
            let outcome = await elements.confirm()
            guard case let .failed(_, error) = outcome else { return XCTFail("expected .failed, got \(outcome)") }
            XCTAssertEqual(error.code, "NO_PAYMENT_OPTION_SELECTED")
        }

        // MARK: - Lock

        func test_inputsDisabledWhileConfirming() async throws {
            let id = "s_locked"
            let (elements, _) = try await makeElements(
                id: id, cards: [usable], submit: [snapshot(id, .succeeded)], submitDelay: .milliseconds(400))
            let card = elements.makeCardElement()
            XCTAssertTrue(card.isInteractiveForTest)
            let task = Task { await elements.confirm() }
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertFalse(card.isInteractiveForTest, "saved rows are disabled while confirming")
            card.tapNewCardRowForTest()
            XCTAssertEqual(card.selectedSavedCardIdForTest, "pm_ok", "taps are ignored while confirming")
            _ = await task.value
        }

        func test_newCardFormDisabledWhileConfirming() async throws {
            let id = "s_locked_form"
            let (elements, _) = try await makeElements(
                id: id, submit: [snapshot(id, .failed)], submitDelay: .milliseconds(400), withKey: true)
            let card = elements.makeCardElement()
            let entry = try XCTUnwrap(card.newCardEntryForTest)
            entry.fillCardForTest()
            let task = Task { await elements.confirm() }
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertFalse(entry.isCardFormInteractive)
            _ = await task.value
            XCTAssertTrue(entry.isCardFormInteractive, "re-enabled after a failure")
        }

        // MARK: - Self-sizing

        func test_heightCallback_firesWhenSelectionExpandsForm() async throws {
            let (elements, _) = try await makeElements(id: "s_height", cards: [usable])
            let card = elements.makeCardElement()
            let spy = DelegateSpy()
            card.delegate = spy
            let collapsed = card.view.intrinsicContentSize.height
            card.tapNewCardRowForTest()
            XCTAssertTrue(card.isNewCardFormVisibleForTest)
            XCTAssertGreaterThan(spy.heightUpdates, 0)
            XCTAssertGreaterThan(card.view.intrinsicContentSize.height, collapsed)
            XCTAssertNil(elements.paymentOption, "the empty new-card form is not payable")
            XCTAssertFalse(card.isComplete)
            XCTAssertEqual(spy.selectionChanges, 1)
        }

        func test_layoutPass_withUnchangedHeight_neitherInvalidatesNorNotifies() async throws {
            let (elements, _) = try await makeElements(id: "s_layout_stable", cards: [usable])
            let card = elements.makeCardElement()
            let spy = DelegateSpy()
            card.delegate = spy
            let container = try XCTUnwrap(card.view as? CardElementContainerView)
            container.frame = CGRect(x: 0, y: 0, width: 320, height: container.intrinsicContentSize.height)
            for _ in 0..<2 {  // settle the first measurements
                container.setNeedsLayout()
                container.layoutIfNeeded()
            }
            let invalidations = container.invalidationCountForTest
            let updates = spy.heightUpdates
            for _ in 0..<3 {
                container.setNeedsLayout()
                container.layoutIfNeeded()
            }
            XCTAssertEqual(container.invalidationCountForTest, invalidations, "no re-invalidation without a change")
            XCTAssertEqual(spy.heightUpdates, updates)
        }

        // MARK: - Ended element

        func test_paymentOption_isNilOnceTheElementEnded() async throws {
            let id = "s_ended_option"
            let (elements, _) = try await makeElements(id: id, cards: [usable], submit: [snapshot(id, .initial)])
            let card = elements.makeCardElement()
            XCTAssertNotNil(elements.paymentOption)
            let first = await elements.confirm()
            guard case .pending = first else { return XCTFail("expected .pending, got \(first)") }
            XCTAssertFalse(card.isComplete)
            XCTAssertNil(elements.paymentOption, "consistent with isComplete: an ended element offers nothing")
        }

        // MARK: - Invalid input does not touch the lock

        func test_confirm_invalidCard_emitsNoStateChange_andStaysReady() async throws {
            let id = "s_invalid_nostate"
            let (elements, _) = try await makeElements(id: id, submit: [snapshot(id, .succeeded)])
            _ = elements.makeCardElement()
            var states: [ElementsCoordinator.State] = []
            let forward = elements.coordinator.onStateChange
            elements.coordinator.onStateChange = { state in
                states.append(state)
                forward?(state)
            }
            let outcome = await elements.confirm()
            guard case let .failed(_, error) = outcome else { return XCTFail("expected .failed, got \(outcome)") }
            XCTAssertEqual(error.code, "CARD_INPUT_INVALID")
            XCTAssertTrue(states.isEmpty, "got \(states)")
            XCTAssertEqual(elements.coordinator.state, .ready)
        }

        // MARK: - Final review fixes

        /// Hosts the element in a window so first-responder behavior is real.
        private func host(_ card: CardElement) -> UIWindow {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 800))
            let controller = UIViewController()
            window.rootViewController = controller
            window.makeKeyAndVisible()
            card.view.frame = CGRect(x: 0, y: 0, width: 375, height: 600)
            controller.view.addSubview(card.view)
            window.layoutIfNeeded()
            return window
        }

        func test_close_clearsTypedCard() async throws {
            let (elements, _) = try await makeElements(id: "s_close_clear", withKey: true)
            let card = elements.makeCardElement()
            let entry = try XCTUnwrap(card.newCardEntryForTest)
            entry.fillCardForTest()
            XCTAssertFalse(entry.panTextForTest.isEmpty)
            await elements.closeAndWait()
            XCTAssertEqual(entry.panTextForTest, "", "close() wipes the typed values")
            XCTAssertFalse(card.isComplete)
        }

        func test_sessionExpiry_clearsTypedCard() async throws {
            let (elements, _) = try await makeElements(id: "s_expiry_clear", withKey: true)
            let card = elements.makeCardElement()
            let entry = try XCTUnwrap(card.newCardEntryForTest)
            entry.fillCardForTest()
            XCTAssertFalse(entry.panTextForTest.isEmpty)
            card.applyLock(.expired)
            XCTAssertEqual(entry.panTextForTest, "", "an ended session wipes the typed values")
        }

        func test_pending_clearsTypedCard() async throws {
            let id = "s_pending_clear"
            let (elements, _) = try await makeElements(id: id, submit: [snapshot(id, .initial)], withKey: true)
            let card = elements.makeCardElement()
            let entry = try XCTUnwrap(card.newCardEntryForTest)
            entry.fillCardForTest()
            let outcome = await elements.confirm()
            guard case .pending = outcome else { return XCTFail("expected .pending, got \(outcome)") }
            XCTAssertEqual(entry.panTextForTest, "", "a settled-pending element no longer holds card values")
        }

        func test_pendingThenDeferredClose_clearsTypedCard() async throws {
            let id = "s_pending_close_clear"
            let (elements, _) = try await makeElements(
                id: id, submit: [snapshot(id, .initial)], submitDelay: .milliseconds(300), withKey: true)
            let card = elements.makeCardElement()
            let entry = try XCTUnwrap(card.newCardEntryForTest)
            entry.fillCardForTest()
            let task = Task { await elements.confirm() }
            try await Task.sleep(nanoseconds: 100_000_000)
            elements.close()
            _ = await task.value
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(entry.panTextForTest, "")
        }

        func test_locking_resignsFirstResponder() async throws {
            let (elements, _) = try await makeElements(id: "s_resign", withKey: true)
            let card = elements.makeCardElement()
            let window = host(card)
            _ = window
            let entry = try XCTUnwrap(card.newCardEntryForTest)
            entry.focusPANForTest()
            XCTAssertTrue(entry.isPANFirstResponderForTest, "precondition: the field is focused")
            card.applyLock(.confirming)
            XCTAssertFalse(entry.isPANFirstResponderForTest, "a locked form must not keep the keyboard")
        }

        func test_delegate_completenessChanges_whenCardBecomesValid_andOnSelection() async throws {
            let (elements, _) = try await makeElements(id: "s_complete", cards: [usable], withKey: true)
            let card = elements.makeCardElement()
            let spy = DelegateSpy()
            card.delegate = spy
            XCTAssertTrue(card.isComplete)
            card.tapNewCardRowForTest()  // saved card -> empty form: complete flips true -> false
            XCTAssertEqual(spy.completenessChanges, 1)
            card.newCardEntryForTest?.fillCardForTest()  // false -> true
            XCTAssertEqual(spy.completenessChanges, 2)
            card.newCardEntryForTest?.fillCardForTest()  // still complete: no new callback
            XCTAssertEqual(spy.completenessChanges, 2)
            card.clear()  // true -> false
            XCTAssertEqual(spy.completenessChanges, 3)
        }

        func test_updateAddresses_thenConfirm_inOneTurn_usesNewAddress() async throws {
            let id = "s_addr_order"
            let (elements, payment) = try await makeElements(
                id: id, cards: [usable], billing: true, submit: [snapshot(id, .succeeded)])
            _ = elements.makeCardElement()
            let host = AddressInput(country: "US", line1: "9 New St", city: "SF", postalCode: "94103")
            elements.updateAddresses(billing: host, shipping: nil)
            _ = await elements.confirm()
            XCTAssertEqual(payment.lastSubmitRequest?.billingAddress, host)
        }

        func test_closeThenConfirm_inOneTurn_doesNotStartPayment() async throws {
            let id = "s_close_confirm"
            let (elements, payment) = try await makeElements(
                id: id, cards: [usable], submit: [snapshot(id, .succeeded)])
            _ = elements.makeCardElement()
            elements.close()
            let outcome = await elements.confirm()
            XCTAssertEqual(outcome, .canceled)
            XCTAssertEqual(payment.submitCallCount, 0)
        }
    }
#endif
