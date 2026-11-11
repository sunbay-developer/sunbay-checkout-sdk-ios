#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Behavior tests for `CheckoutContentViewController` (spec §3.1–§3.3, Task 8).
    ///
    /// UIKit is iOS-only; on the macOS host (`swift test`) this whole file is excluded by
    /// `#if canImport(UIKit)` and is vacuous. The real RED/GREEN requires building against the iOS
    /// Simulator SDK. The suite drives the content VC through a `MockContentDelegate` and asserts the
    /// delegate contract: a confirm tap emits `.confirmNewCard` + `didChangeProcessing(true)`; applying
    /// a `.succeeded` outcome finishes with that outcome after the success animation; applying a
    /// `.failed` outcome keeps the sheet editable and reports `.failed`.
    @MainActor
    final class CheckoutContentViewControllerTests: XCTestCase {
        // MARK: - Helpers

        /// A trivial in-memory address-metadata service (simple mode never consults it, but the init
        /// requires one and full mode would).
        private struct MockAddressService: AddressMetadataService {
            func countries(locale: String?) async throws -> AddressCountryList {
                AddressCountryList(countries: [AddressCountry(code: "US", name: "United States")], detectedCountry: "US")
            }

            func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
                AddressCountryConfig(
                    code: countryCode,
                    fields: [.country: AddressFieldConfig(
                        type: .country, required: true, pattern: nil, label: "Country", placeholder: "Country")],
                    layout: [[.country]],
                    subdivisions: []
                )
            }
        }

        /// Records the delegate callbacks so tests can assert the emitted actions / states.
        private final class MockContentDelegate: CheckoutContentDelegate {
            var lastRequestedAction: PaymentSheet.UserAction?
            var didChangeProcessingTrue = false
            var finishedOutcome: CheckoutOutcome?
            var lastState: CheckoutPresentationState?
            var canceled = false
            var cancelCount = 0
            var heights: [CGFloat] = []

            func content(_ content: CheckoutContentViewController, didRequest action: PaymentSheet.UserAction) {
                lastRequestedAction = action
            }

            func contentDidRequestCancel(_ content: CheckoutContentViewController) {
                canceled = true
                cancelCount += 1
            }

            func content(_ content: CheckoutContentViewController, didFinishWith outcome: CheckoutOutcome) {
                finishedOutcome = outcome
            }

            func content(_ content: CheckoutContentViewController, didChangeProcessing isProcessing: Bool) {
                if isProcessing { didChangeProcessingTrue = true }
            }

            func content(_ content: CheckoutContentViewController, didUpdateContentHeight height: CGFloat) {
                heights.append(height)
            }

            func content(_ content: CheckoutContentViewController, didChangeState state: CheckoutPresentationState) {
                lastState = state
            }
        }

        private func makeSession(methods: Set<PaymentMethodKind> = [.card], cofEnabled: Bool = false) -> CheckoutSession {
            CheckoutSession(
                id: "sess_1",
                amount: Amount(minorUnits: 1999, currencyCode: "USD"),
                merchantName: "Demo Merchant",
                methods: methods,
                expiresAt: Date().addingTimeInterval(600),
                rsaPublicKey: nil,
                cofEnabled: cofEnabled
            )
        }

        private func makeVC(
            savedCards: [SavedCard], methods: Set<PaymentMethodKind> = [.card],
            appearance: Appearance = .default, cofEnabled: Bool = false,
            cardOnFileEnabled: Bool = false, saveCardByDefault: Bool = false,
            localeCode: String? = nil,
            visibleEntries: [MethodEntry]? = nil,
            localize: @escaping (String) -> String = { $0 }
        ) -> CheckoutContentViewController {
            CheckoutContentViewController(
                session: makeSession(methods: methods, cofEnabled: cofEnabled),
                savedCards: savedCards,
                appearance: .resolve(appearance),
                localize: localize,
                localeCode: localeCode,
                billingMode: .simple,
                shippingMode: .simple,
                addressService: MockAddressService(),
                cardOnFileEnabled: cardOnFileEnabled,
                saveCardByDefault: saveCardByDefault,
                visibleEntries: visibleEntries
            )
        }

        // MARK: - Tests

        // MARK: - Save-card row (effective COF decision)

        func test_saveRowHidden_whenCardOnFileDisabled_evenIfSessionAllowsCof() {
            let vc = makeVC(savedCards: [], cofEnabled: true, cardOnFileEnabled: false, saveCardByDefault: true)
            vc.loadViewIfNeeded()
            vc.openNewCardForTest()
            XCTAssertFalse(vc.isSaveCardRowVisibleForTest)
            XCTAssertFalse(vc.isSaveCardOnForTest)
        }

        func test_saveRowVisibleAndOn_whenSaveByDefault_andUserCanOptOut() {
            let vc = makeVC(savedCards: [], cofEnabled: true, cardOnFileEnabled: true, saveCardByDefault: true)
            vc.loadViewIfNeeded()
            vc.openNewCardForTest()
            XCTAssertTrue(vc.isSaveCardRowVisibleForTest)
            XCTAssertTrue(vc.isSaveCardOnForTest)

            vc.setSaveCardForTest(false)
            vc.fillCardForTest()
            let delegate = MockContentDelegate()
            vc.delegate = delegate
            vc.simulateTapPay()

            guard case let .confirmNewCard(_, save, _, _, _, _)? = delegate.lastRequestedAction else {
                return XCTFail("Expected .confirmNewCard, got \(String(describing: delegate.lastRequestedAction))")
            }
            XCTAssertFalse(save)
        }

        func test_saveRowVisibleAndOff_whenNotSaveByDefault() {
            let vc = makeVC(savedCards: [], cofEnabled: true, cardOnFileEnabled: true, saveCardByDefault: false)
            vc.loadViewIfNeeded()
            vc.openNewCardForTest()
            XCTAssertTrue(vc.isSaveCardRowVisibleForTest)
            XCTAssertFalse(vc.isSaveCardOnForTest)
        }

        func test_tapPayWithCompleteCardRequestsConfirmNewCard() {
            let vc = makeVC(savedCards: [])
            vc.loadViewIfNeeded()
            vc.openNewCardForTest()
            vc.fillCardForTest()
            let delegate = MockContentDelegate()
            vc.delegate = delegate

            vc.simulateTapPay()

            guard case .confirmNewCard = delegate.lastRequestedAction else {
                return XCTFail("Expected .confirmNewCard, got \(String(describing: delegate.lastRequestedAction))")
            }
            XCTAssertTrue(delegate.didChangeProcessingTrue)
            XCTAssertEqual(delegate.lastState, .processing)
        }

        func test_applySuccessFinishesWithOutcome() {
            let vc = makeVC(savedCards: [])
            vc.loadViewIfNeeded()
            vc.openNewCardForTest()
            vc.fillCardForTest()
            let delegate = MockContentDelegate()
            vc.delegate = delegate

            vc.simulateTapPay()
            vc.applyOutcome(.succeeded(txnId: "t"))

            // The success path waits out minimumFlightTime + successDisplayDuration before finishing.
            // Spin the main run loop (staying on the main actor) until the delegate finishes.
            let deadline = Date().addingTimeInterval(5.0)
            while delegate.finishedOutcome == nil, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }

            XCTAssertEqual(delegate.finishedOutcome, .succeeded(txnId: "t"))
            XCTAssertEqual(delegate.lastState, .succeeded)
        }

        func test_applyFailedStaysEditableAndReportsFailedState() {
            let vc = makeVC(savedCards: [])
            vc.loadViewIfNeeded()
            vc.openNewCardForTest()
            vc.fillCardForTest()
            let delegate = MockContentDelegate()
            vc.delegate = delegate

            vc.simulateTapPay()
            vc.applyOutcome(.failed(txnId: nil, error: CheckoutErrors.paymentFailed()))

            // The failed path waits out minimumFlightTime before applying the terminal UI.
            let deadline = Date().addingTimeInterval(3.0)
            while delegate.lastState != .failed, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }

            XCTAssertEqual(delegate.lastState, .failed)
            // The sheet stays open and re-editable: the card form is interactive again. (The machine's
            // own `state` stays `.failed(reason:)` until the next edit/retry; re-editability is that the
            // inputs are re-enabled, per spec §3.2.)
            XCTAssertTrue(vc.isCardFormInteractiveForTest, "Inputs should be re-enabled after a failure.")
            // The CTA must also be moved off `.processing` and back to interactive so the user can
            // resubmit (spec §3.1 "failed … can return to editing for retry"). The form is still
            // complete from `fillCardForTest()`, so the Pay button should be enabled again — not stuck
            // spinning. This is the assertion that fails before the re-enable fix.
            XCTAssertTrue(
                vc.isConfirmButtonEnabledForTest,
                "Pay button must be interactive again after a failure so the user can retry.")
        }

        // MARK: - Saved-card selection (no auto-submit) + Pay visibility

        private func sampleSavedCards() -> [SavedCard] {
            [
                SavedCard(id: "pm_1", brand: "visa", last4: "4242", expMonth: 8, expYear: 2028),
                SavedCard(id: "pm_2", brand: "mastercard", last4: "5454", expMonth: 1, expYear: 2027),
            ]
        }

        /// Selecting a saved card must NOT submit; it only enables the Pay button. Tapping Pay then
        /// submits `.confirmSavedCard` for the selected card.
        func test_selectingSavedCardDoesNotSubmit_payTapSubmits() {
            let vc = makeVC(savedCards: sampleSavedCards())
            vc.loadViewIfNeeded()
            let delegate = MockContentDelegate()
            vc.delegate = delegate

            vc.selectSavedCardForTest("pm_2")
            // No submit yet from selection alone.
            XCTAssertNil(delegate.lastRequestedAction, "Selecting a saved card must not submit.")
            XCTAssertTrue(vc.isConfirmButtonVisibleForTest, "Pay button shows once a card is selected.")
            XCTAssertTrue(vc.isConfirmButtonEnabledForTest)

            vc.simulateTapPay()
            guard case let .confirmSavedCard(paymentMethodId) = delegate.lastRequestedAction else {
                return XCTFail("Expected .confirmSavedCard, got \(String(describing: delegate.lastRequestedAction))")
            }
            XCTAssertEqual(paymentMethodId, "pm_2")
        }

        /// On the saved-card home page, the first card is pre-selected: the Pay button is visible and
        /// enabled immediately, and nothing is submitted by the pre-selection alone.
        func test_home_preSelectsFirstSavedCard_payEnabled_noSubmit() {
            let vc = makeVC(savedCards: sampleSavedCards())
            vc.loadViewIfNeeded()
            let delegate = MockContentDelegate()
            vc.delegate = delegate
            XCTAssertEqual(vc.highlightedSavedCardIdForTest, "pm_1")
            XCTAssertTrue(vc.isConfirmButtonVisibleForTest)
            XCTAssertTrue(vc.isConfirmButtonEnabledForTest)
            XCTAssertNil(delegate.lastRequestedAction)
        }

        /// "View more" is shown only when there are 2+ saved cards; a single saved card is shown
        /// (pre-selected) with no "View more".
        func test_viewMore_visibleOnlyForMultipleCards() {
            let one = makeVC(savedCards: [sampleSavedCards()[0]])
            one.loadViewIfNeeded()
            XCTAssertFalse(one.isViewMoreVisibleForTest)
            XCTAssertEqual(one.highlightedSavedCardIdForTest, "pm_1")

            let many = makeVC(savedCards: sampleSavedCards())
            many.loadViewIfNeeded()
            XCTAssertTrue(many.isViewMoreVisibleForTest)
        }

        /// home → New card → back re-selects the first saved card (Pay stays valid), not blank.
        func test_homeToNewCardAndBack_reselectsFirstCard() {
            let vc = makeVC(savedCards: sampleSavedCards())
            vc.loadViewIfNeeded()
            vc.tapNewCardEntryForTest()
            vc.tapBackForTest()
            XCTAssertTrue(vc.isHomeVisibleForTest)
            XCTAssertEqual(vc.highlightedSavedCardIdForTest, "pm_1")
            XCTAssertTrue(vc.isConfirmButtonVisibleForTest)
        }

        /// The home summary card is a static, non-interactive element: it must not be announced to
        /// VoiceOver as a tappable button (only the separate "View more" control navigates).
        func test_homeSummaryRow_isNotAnnouncedAsButton() {
            let vc = makeVC(savedCards: sampleSavedCards())
            vc.loadViewIfNeeded()
            XCTAssertFalse(vc.isSummaryRowButtonForTest, "Summary card must not advertise a .button trait.")
        }

        /// "View more" opens the full saved-card list page; the back button returns home with the
        /// selection intact.
        func test_viewMore_opensFullList_backReturnsHome() {
            let vc = makeVC(savedCards: sampleSavedCards())
            vc.loadViewIfNeeded()
            vc.tapViewMoreForTest()
            XCTAssertTrue(vc.isAllSavedCardsVisibleForTest)
            XCTAssertFalse(vc.isHomeVisibleForTest)
            vc.tapBackForTest()
            XCTAssertTrue(vc.isHomeVisibleForTest)
            XCTAssertEqual(vc.highlightedSavedCardIdForTest, "pm_1")
        }

        /// The full saved-card list page ("View more") is a pure picker: the bottom Pay button is
        /// hidden while it is visible, and reappears once the user returns home (via back or by
        /// picking a card).
        func test_viewMore_hidesPay_restoredOnReturnHome() {
            let vc = makeVC(savedCards: sampleSavedCards())
            vc.loadViewIfNeeded()
            XCTAssertTrue(vc.isConfirmButtonVisibleForTest, "Precondition: Pay is visible on home.")

            vc.tapViewMoreForTest()
            XCTAssertTrue(vc.isAllSavedCardsVisibleForTest)
            XCTAssertFalse(vc.isConfirmButtonVisibleForTest, "Pay is hidden on the full list page.")

            vc.tapBackForTest()
            XCTAssertTrue(vc.isHomeVisibleForTest)
            XCTAssertTrue(vc.isConfirmButtonVisibleForTest, "Pay returns home via back.")

            vc.tapViewMoreForTest()
            XCTAssertFalse(vc.isConfirmButtonVisibleForTest)
            vc.tapFullListRowForTest("pm_2")
            XCTAssertTrue(vc.isHomeVisibleForTest)
            XCTAssertTrue(vc.isConfirmButtonVisibleForTest, "Pay returns home when a card is picked.")
        }

        /// Picking a non-first card on the full list selects it and auto-returns home showing that
        /// card; tapping Pay then submits `.confirmSavedCard` for the picked card.
        func test_fullList_pickSelectsAndReturnsHome() {
            let vc = makeVC(savedCards: sampleSavedCards())
            vc.loadViewIfNeeded()
            let delegate = MockContentDelegate()
            vc.delegate = delegate
            vc.tapViewMoreForTest()
            vc.tapFullListRowForTest("pm_2")
            XCTAssertTrue(vc.isHomeVisibleForTest, "Picking a card returns to home.")
            XCTAssertEqual(vc.highlightedSavedCardIdForTest, "pm_2")
            XCTAssertTrue(vc.isConfirmButtonVisibleForTest)
            XCTAssertNil(delegate.lastRequestedAction, "Picking must not submit.")

            vc.simulateTapPay()
            guard case let .confirmSavedCard(id) = delegate.lastRequestedAction else {
                return XCTFail("Expected .confirmSavedCard, got \(String(describing: delegate.lastRequestedAction))")
            }
            XCTAssertEqual(id, "pm_2")
        }

        /// On the new-card subpage the Pay button is ALWAYS visible. With an incomplete form it looks
        /// disabled (dimmed, `.notEnabled` trait) but stays tappable; a complete form is normal.
        func test_newCardSubpagePayAlwaysVisible_dimmedUntilComplete() {
            let vc = makeVC(savedCards: [])
            vc.loadViewIfNeeded()
            vc.openNewCardForTest()
            XCTAssertTrue(vc.isConfirmButtonVisibleForTest, "Pay is always visible on the subpage.")
            XCTAssertTrue(vc.isConfirmButtonAppearsDisabledForTest)
            XCTAssertTrue(vc.confirmButtonTraitsForTest.contains(.notEnabled))
            XCTAssertTrue(vc.isConfirmButtonEnabledForTest, "Must not be isEnabled=false (no taps).")

            vc.fillCardForTest()
            XCTAssertTrue(vc.isConfirmButtonVisibleForTest)
            XCTAssertFalse(vc.isConfirmButtonAppearsDisabledForTest)
            XCTAssertFalse(vc.confirmButtonTraitsForTest.contains(.notEnabled))
            XCTAssertTrue(vc.isConfirmButtonEnabledForTest)
        }

        /// Tapping the dimmed Pay button on an incomplete form must not submit, and a REAL touch
        /// delivery (the first and only action here) must reach the handler that surfaces the field error.
        func test_incompleteForm_payTapDoesNotSubmit_butIsDelivered() {
            let vc = makeVC(savedCards: [])
            vc.loadViewIfNeeded()
            vc.openNewCardForTest()
            let delegate = MockContentDelegate()
            vc.delegate = delegate
            XCTAssertFalse(vc.isCardFieldErrorShownForTest, "Precondition: no error before the tap.")

            vc.sendTouchOnPayButtonForTest()

            XCTAssertNil(delegate.lastRequestedAction, "An incomplete form must not submit.")
            XCTAssertFalse(delegate.didChangeProcessingTrue)
            XCTAssertTrue(vc.isCardFieldErrorShownForTest, "The touch must be delivered and surface the field error.")
            XCTAssertEqual(vc.currentViewState, .editing, "Still editing after an incomplete-form tap.")
        }

        func test_completeForm_payTapSubmitsConfirmNewCard() {
            let vc = makeVC(savedCards: [])
            vc.loadViewIfNeeded()
            vc.openNewCardForTest()
            vc.fillCardForTest()
            let delegate = MockContentDelegate()
            vc.delegate = delegate

            vc.sendTouchOnPayButtonForTest()

            guard case .confirmNewCard = delegate.lastRequestedAction else {
                return XCTFail("Expected .confirmNewCard, got \(String(describing: delegate.lastRequestedAction))")
            }
        }

        // MARK: - Selection wiring / stale highlight

        /// A real row tap (through `SavedCardListView`) highlights the row and enables Pay, without
        /// submitting.
        func test_realRowTap_highlightsAndEnablesPay_withoutSubmitting() {
            let vc = makeVC(savedCards: sampleSavedCards())
            vc.loadViewIfNeeded()
            let delegate = MockContentDelegate()
            vc.delegate = delegate

            vc.tapSavedCardRowForTest("pm_1")

            XCTAssertEqual(vc.highlightedSavedCardIdForTest, "pm_1")
            XCTAssertTrue(vc.isConfirmButtonVisibleForTest)
            XCTAssertTrue(vc.isConfirmButtonEnabledForTest)
            XCTAssertFalse(vc.isConfirmButtonAppearsDisabledForTest)
            XCTAssertNil(delegate.lastRequestedAction)
        }

        /// home → select pm_2 → New card → back: the first card (pm_1) is re-selected as the default
        /// (no stale pm_2 highlight), and Pay stays visible because a valid default is selected.
        func test_homeToNewCardAndBack_resetsToFirstCardDefault() {
            let vc = makeVC(savedCards: sampleSavedCards())
            vc.loadViewIfNeeded()
            vc.tapSavedCardRowForTest("pm_2")
            XCTAssertEqual(vc.highlightedSavedCardIdForTest, "pm_2")

            vc.tapNewCardEntryForTest()
            vc.tapBackForTest()

            XCTAssertTrue(vc.isHomeVisibleForTest)
            XCTAssertEqual(vc.highlightedSavedCardIdForTest, "pm_1", "Back resets to the first-card default.")
            XCTAssertTrue(vc.isConfirmButtonVisibleForTest, "Pay stays visible with the default selected.")
        }

        // MARK: - Navigation lock while processing

        func test_processing_locksNewCardEntryOnHome_andFailureUnlocks() {
            let vc = makeVC(savedCards: sampleSavedCards())
            vc.loadViewIfNeeded()
            let delegate = MockContentDelegate()
            vc.delegate = delegate
            vc.tapSavedCardRowForTest("pm_1")
            XCTAssertTrue(vc.isHomeInteractiveForTest)

            vc.simulateTapPay()
            XCTAssertEqual(vc.currentViewState, .processing)
            XCTAssertFalse(vc.isHomeInteractiveForTest, "New card entry must be locked while processing.")
            vc.tapNewCardEntryForTest()
            XCTAssertTrue(vc.isHomeVisibleForTest, "Navigation must be ignored while processing.")

            vc.applyOutcome(.failed(txnId: nil, error: CheckoutErrors.paymentFailed()))
            let deadline = Date().addingTimeInterval(3.0)
            while delegate.lastState != .failed, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            XCTAssertTrue(vc.isHomeInteractiveForTest, "Unlocked after a failure.")
        }

        func test_processing_locksBackButton_andFailureUnlocks() {
            let vc = makeVC(savedCards: [])
            vc.loadViewIfNeeded()
            vc.openNewCardForTest()
            vc.fillCardForTest()
            let delegate = MockContentDelegate()
            vc.delegate = delegate
            XCTAssertTrue(vc.isBackInteractiveForTest)

            vc.simulateTapPay()
            XCTAssertFalse(vc.isBackInteractiveForTest, "Back must be locked while processing.")
            vc.tapBackForTest()
            XCTAssertTrue(vc.isNewCardSubpageVisibleForTest, "Back must be ignored while processing.")

            vc.applyOutcome(.failed(txnId: nil, error: CheckoutErrors.paymentFailed()))
            let deadline = Date().addingTimeInterval(3.0)
            while delegate.lastState != .failed, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            XCTAssertTrue(vc.isBackInteractiveForTest)
        }

        // MARK: - Wallet contacts and ewalletParam

        func test_appleTap_requestsContactsWithFormFlags_andConfirmCarriesAuthorizationAndFlags() async throws {
            let billing = AddressInput(country: "US", line1: "1 Main", city: "SF", postalCode: "94103")
            let wallet = MockWalletAuthorizer(
                canMake: true,
                outcome: .authorization(
                    WalletAuthorization(token: Data([7]), billing: billing, shipping: nil, email: "a@b.co")))
            let flags = FlagRecorder()
            let session = CheckoutSession(
                id: "sess_w", amount: Amount(minorUnits: 100, currencyCode: "USD"), merchantName: "Acme",
                methods: [.card, .applePay], expiresAt: Date().addingTimeInterval(600), collectBillingAddress: true)
            let vc = CheckoutContentViewController(
                session: session, savedCards: [], appearance: .resolve(.default), localize: { $0 },
                billingMode: .simple, shippingMode: .off, addressService: MockAddressService(),
                walletAuthorizer: wallet, walletMerchantId: "merchant.x",
                walletContacts: { b, s in
                    flags.record(b, s)
                    return WalletContactRequest(billing: true, shipping: false)
                })
            let delegate = MockContentDelegate()
            vc.delegate = delegate
            vc.loadViewIfNeeded()

            vc.tapExpressForTest()
            let deadline = Date().addingTimeInterval(3)
            while delegate.lastRequestedAction == nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }

            XCTAssertEqual(wallet.lastContacts, WalletContactRequest(billing: true, shipping: false))
            XCTAssertEqual(wallet.lastMerchantName, "Acme")
            XCTAssertEqual(flags.last?.0, true)
            XCTAssertEqual(flags.last?.1, false)
            guard case let .confirmWallet(authorization, billingShown, shippingShown)? = delegate.lastRequestedAction
            else { return XCTFail("Expected .confirmWallet") }
            XCTAssertEqual(authorization.billing, billing)
            XCTAssertEqual(authorization.email, "a@b.co")
            XCTAssertTrue(billingShown)
            XCTAssertFalse(shippingShown)
            vc.applyOutcome(.failed(txnId: nil, error: CheckoutErrors.paymentFailed()))
        }

        func test_missingWalletParameters_hidesExpressRow_andReportsNamesOnce() {
            let wallet = MockWalletAuthorizer(
                canMake: true, outcome: .success(Data([1])), missing: ["merchantCapabilities"])
            let reported = ReportRecorder()
            let vc = CheckoutContentViewController(
                session: makeSession(methods: [.card, .applePay]), savedCards: [],
                appearance: .resolve(.default), localize: { $0 }, billingMode: .simple, shippingMode: .simple,
                addressService: MockAddressService(), walletAuthorizer: wallet, walletMerchantId: "merchant.x",
                onWalletParamsInvalid: { reported.add($0) })
            vc.loadViewIfNeeded()

            XCTAssertNil(vc.expressViewForTest)
            XCTAssertEqual(reported.all, [["merchantCapabilities"]])
        }

        private final class FlagRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [(Bool, Bool)] = []
            func record(_ b: Bool, _ s: Bool) { lock.lock(); items.append((b, s)); lock.unlock() }
            var last: (Bool, Bool)? { lock.lock(); defer { lock.unlock() }; return items.last }
        }

        private final class ReportRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [[String]] = []
            func add(_ names: [String]) { lock.lock(); items.append(names); lock.unlock() }
            var all: [[String]] { lock.lock(); defer { lock.unlock() }; return items }
        }

        // MARK: - Wallet feedback on a Pay-less home page

        func test_walletOnlyHome_payHiddenAtRest_visibleWhileProcessing_hiddenAfterFailure() {
            let vc = makeVC(savedCards: [], methods: [.card, .applePay])
            vc.loadViewIfNeeded()
            let delegate = MockContentDelegate()
            vc.delegate = delegate
            XCTAssertFalse(vc.isConfirmButtonVisibleForTest)

            vc.stageWalletToken(Data([1, 2, 3]))
            vc.tapExpressForTest()

            guard case .confirmWallet = delegate.lastRequestedAction else {
                return XCTFail("Expected .confirmWallet, got \(String(describing: delegate.lastRequestedAction))")
            }
            XCTAssertTrue(vc.isConfirmButtonVisibleForTest, "Spinner must be visible during a wallet confirm.")

            vc.applyOutcome(.failed(txnId: nil, error: CheckoutErrors.paymentFailed()))
            let deadline = Date().addingTimeInterval(3.0)
            while delegate.lastState != .failed, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            XCTAssertFalse(vc.isConfirmButtonVisibleForTest, "Hidden again on the home page.")
        }

        // MARK: - Express position (D1)

        private func appearance(_ position: Appearance.ExpressPosition) -> Appearance {
            var appearance = Appearance.default
            appearance.expressPosition = position
            return appearance
        }

        // MARK: - Method filter (visible entries)

        private let cardEntry = MethodEntry(method: "VISA", type: "CARD", name: "Visa", logoURL: nil)
        private let appleEntry = MethodEntry(method: "APPLE_PAY", type: "E_WALLET", name: "Apple Pay", logoURL: nil)

        func test_filter_hideApplePay_removesExpressRow() {
            let vc = makeVC(
                savedCards: [], methods: [.card, .applePay], visibleEntries: [cardEntry])
            vc.loadViewIfNeeded()
            XCTAssertEqual(vc.homeOrderForTest, ["newCardEntry"])
        }

        func test_filter_hideCard_removesNewCardRowAndSavedCards() {
            let vc = makeVC(
                savedCards: sampleSavedCards(), methods: [.card, .applePay], visibleEntries: [appleEntry])
            vc.loadViewIfNeeded()
            XCTAssertEqual(vc.homeOrderForTest, ["express"])
        }

        func test_noCardEntry_showsNoNewCardRow() {
            let vc = makeVC(savedCards: [], methods: [.applePay])
            vc.loadViewIfNeeded()
            XCTAssertEqual(vc.homeOrderForTest, ["express"])
        }

        func test_filter_expressBottom_stillPlacesExpressBelow() {
            let vc = makeVC(
                savedCards: [], methods: [.card, .applePay], appearance: appearance(.bottom),
                visibleEntries: [appleEntry, cardEntry])
            vc.loadViewIfNeeded()
            XCTAssertEqual(vc.homeOrderForTest, ["newCardEntry", "express"])
        }

        func test_expressPosition_orderOnHome() {
            let top = makeVC(savedCards: sampleSavedCards(), methods: [.card, .applePay], appearance: appearance(.top))
            top.loadViewIfNeeded()
            XCTAssertEqual(top.homeOrderForTest, ["express", "savedCards", "newCardEntry"])

            let bottom = makeVC(
                savedCards: sampleSavedCards(), methods: [.card, .applePay], appearance: appearance(.bottom))
            bottom.loadViewIfNeeded()
            XCTAssertEqual(bottom.homeOrderForTest, ["savedCards", "newCardEntry", "express"])

            let bottomNoCards = makeVC(savedCards: [], methods: [.card, .applePay], appearance: appearance(.bottom))
            bottomNoCards.loadViewIfNeeded()
            XCTAssertEqual(bottomNoCards.homeOrderForTest, ["newCardEntry", "express"])

            let off = makeVC(savedCards: sampleSavedCards(), methods: [.card, .applePay], appearance: appearance(.off))
            off.loadViewIfNeeded()
            XCTAssertEqual(off.homeOrderForTest, ["savedCards", "newCardEntry"])
        }

        func test_express_neverVisibleOnNewCardSubpage_inAnyMode() {
            for position in [Appearance.ExpressPosition.top, .bottom, .off] {
                let vc = makeVC(savedCards: [], methods: [.card, .applePay], appearance: appearance(position))
                vc.loadViewIfNeeded()
                vc.openNewCardForTest()
                XCTAssertFalse(vc.isExpressVisibleForTest, "Express must not show on the subpage (\(position)).")
            }
        }

        // MARK: - Vertical layout allocation (header / scroll / bottom bar)

        /// Installs the content VC in a real window of a sheet-like size and asserts the vertical chain
        /// header → scroll → bottom bar is deterministic: the header stays at its natural height, the
        /// scroll view gets the remaining space (and lays the home content out inside it), and no
        /// container reports an ambiguous layout.
        private func assertSheetLayout(
            savedCards: [SavedCard], size: CGSize, file: StaticString = #filePath, line: UInt = #line
        ) {
            let vc = makeVC(savedCards: savedCards, methods: [.card, .applePay], cofEnabled: true, cardOnFileEnabled: true)
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = vc
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            vc.view.layoutIfNeeded()

            let headerHeight = vc.headerContainerForTest.frame.height
            XCTAssertGreaterThanOrEqual(headerHeight, 36, "Header row too small: \(headerHeight)", file: file, line: line)
            XCTAssertLessThanOrEqual(headerHeight, 72, "Header must stay near natural height: \(headerHeight)", file: file, line: line)

            let scroll = vc.scrollViewForTest
            XCTAssertGreaterThan(scroll.frame.height, 100, "Scroll view starved: \(scroll.frame.height)", file: file, line: line)

            guard let entry = vc.newCardEntryRowForTest else { return XCTFail("No New card row.", file: file, line: line) }
            XCTAssertGreaterThan(entry.frame.height, 0, file: file, line: line)
            let entryFrame = entry.convert(entry.bounds, to: scroll)
            XCTAssertGreaterThan(entryFrame.height, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(
                entryFrame.maxY, max(scroll.contentSize.height, scroll.bounds.height), file: file, line: line)
            XCTAssertGreaterThan(scroll.contentSize.height, 0, file: file, line: line)
            if let express = vc.expressViewForTest {
                XCTAssertGreaterThan(express.frame.height, 0, "Express view collapsed.", file: file, line: line)
            }
            if !savedCards.isEmpty {
                XCTAssertGreaterThan(vc.savedCardListViewForTest?.frame.height ?? 0, 0, "Saved list collapsed.", file: file, line: line)
            }

            XCTAssertFalse(vc.headerContainerForTest.hasAmbiguousLayout, "headerContainer ambiguous", file: file, line: line)
            XCTAssertFalse(scroll.hasAmbiguousLayout, "scrollView ambiguous", file: file, line: line)
            XCTAssertFalse(vc.bottomBarForTest.hasAmbiguousLayout, "bottomBar ambiguous", file: file, line: line)
        }

        func test_sheetLayout_withSavedCards_sheetSize() {
            assertSheetLayout(savedCards: sampleSavedCards(), size: CGSize(width: 386, height: 447))
        }

        func test_sheetLayout_withSavedCards_tallSize() {
            assertSheetLayout(savedCards: sampleSavedCards(), size: CGSize(width: 386, height: 700))
        }

        func test_sheetLayout_noSavedCards_sheetSize() {
            assertSheetLayout(savedCards: [], size: CGSize(width: 386, height: 447))
        }

        func test_sheetLayout_noSavedCards_tallSize() {
            assertSheetLayout(savedCards: [], size: CGSize(width: 386, height: 700))
        }

        // MARK: - Reported height

        /// The reported height is re-evaluated on navigation, includes the chrome, and differs between
        /// the (short) home page and the (taller) new-card subpage.
        func test_reportedHeight_updatesOnNavigation() {
            let vc = makeVC(savedCards: [])
            let delegate = MockContentDelegate()
            vc.delegate = delegate
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = vc
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            vc.view.layoutIfNeeded()
            let homeHeight = delegate.heights.last
            XCTAssertNotNil(homeHeight)

            vc.openNewCardForTest()
            let formHeight = delegate.heights.last
            XCTAssertNotNil(formHeight)
            XCTAssertGreaterThan(formHeight ?? 0, homeHeight ?? 0, "Form page is taller than empty home.")
            // 16+16 scroll insets + 4 bar margin are included on top of the measured stacks.
            XCTAssertGreaterThan(homeHeight ?? 0, 36 + 52, "Chrome must be counted.")
        }

        /// With a pre-selected saved card the Pay button is visible on home from the start; navigating
        /// to the taller new-card subpage grows the reported height, and returning home restores it.
        func test_reportedHeight_homeShowsPay_growsOnNewCard_restoresOnBack() {
            let vc = makeVC(savedCards: sampleSavedCards())
            let delegate = MockContentDelegate()
            vc.delegate = delegate
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = vc
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            vc.view.layoutIfNeeded()
            // Home pre-selects the first card, so Pay is already visible.
            XCTAssertTrue(vc.isConfirmButtonVisibleForTest)
            guard let home = delegate.heights.last else { return XCTFail("No initial height reported.") }

            vc.tapNewCardEntryForTest()
            guard let form = delegate.heights.last else { return XCTFail("No height after New card.") }
            XCTAssertGreaterThan(form, home + 20, "The new-card subpage is taller than home.")

            vc.tapBackForTest()
            XCTAssertTrue(vc.isConfirmButtonVisibleForTest, "Back restores the pre-selected card and its Pay.")
            guard let back = delegate.heights.last else { return XCTFail("No height after back.") }
            XCTAssertEqual(back, home, accuracy: 1.0, "Returning home restores the home height.")
        }

        // MARK: - Pending / unknown unlock, double-tap while processing

        private func waitForState(_ delegate: MockContentDelegate, _ state: CheckoutPresentationState) {
            let deadline = Date().addingTimeInterval(3.0)
            while delegate.lastState != state, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }

        /// After `.pending` / `.unknown` the sheet enters the LOCKED reconciling state (unlike `.failed`):
        /// Pay stays hidden, inputs and navigation stay non-interactive, and the info notice is shown, so
        /// a second tap cannot resubmit while the earlier attempt is unsettled. Only ✕ stays available.
        func test_pendingAndUnknown_stayLocked_payHidden_andShowInfoNotice() {
            let outcomes: [CheckoutOutcome] = [.pending(txnId: "t"), .unknown(sessionId: "sess_1")]
            for outcome in outcomes {
                let vc = makeVC(savedCards: sampleSavedCards())
                vc.loadViewIfNeeded()
                let delegate = MockContentDelegate()
                vc.delegate = delegate
                vc.tapSavedCardRowForTest("pm_1")
                vc.simulateTapPay()
                XCTAssertFalse(vc.isHomeInteractiveForTest, "Locked while processing (\(outcome)).")
                XCTAssertFalse(vc.isNoticeVisibleForTest)

                vc.applyOutcome(outcome)
                waitUntil { vc.currentViewState == .reconciling }

                XCTAssertEqual(vc.currentViewState, .reconciling, "(\(outcome))")
                XCTAssertTrue(vc.isNoticeVisibleForTest, "Info notice must be shown after \(outcome).")
                XCTAssertFalse(vc.isConfirmButtonVisibleForTest, "Pay must stay hidden after \(outcome).")
                XCTAssertFalse(vc.isHomeInteractiveForTest, "Home must stay locked after \(outcome).")
                XCTAssertFalse(vc.isBackInteractiveForTest, "Back must stay locked after \(outcome).")
                XCTAssertNil(delegate.finishedOutcome, "Pending/unknown must not close the sheet.")
            }
        }

        /// New-card subpage: after `.unknown` the card form is non-interactive and Pay is hidden (the
        /// subpage normally always shows Pay), and a programmatic Pay tap / re-trigger emits NOTHING.
        func test_unknown_onNewCardSubpage_lockedAndNoSecondRequest() {
            let vc = makeVC(savedCards: [])
            vc.loadViewIfNeeded()
            vc.openNewCardForTest()
            vc.fillCardForTest()
            let delegate = MockContentDelegate()
            vc.delegate = delegate

            vc.simulateTapPay()
            guard case .confirmNewCard = delegate.lastRequestedAction else {
                return XCTFail("precondition: first tap should request a confirm")
            }
            delegate.lastRequestedAction = nil
            vc.applyOutcome(.unknown(sessionId: "sess_1"))
            waitUntil { vc.currentViewState == .reconciling }

            XCTAssertFalse(vc.isCardFormInteractiveForTest, "Card form must stay locked after unknown.")
            XCTAssertFalse(vc.isConfirmButtonVisibleForTest, "Pay must be hidden after unknown.")

            vc.simulateTapPay()
            vc.sendTouchOnPayButtonForTest()
            XCTAssertNil(delegate.lastRequestedAction, "No second confirm may be emitted while reconciling.")
        }

        /// Saved-card selection survives `.unknown`, but a programmatic Pay tap still emits nothing, and
        /// page navigation (New card / back) is ignored while reconciling.
        func test_unknown_savedCardPayTapAndNavigationAreIgnored() {
            let vc = makeVC(savedCards: sampleSavedCards())
            vc.loadViewIfNeeded()
            let delegate = MockContentDelegate()
            vc.delegate = delegate
            vc.tapSavedCardRowForTest("pm_1")
            vc.simulateTapPay()
            delegate.lastRequestedAction = nil
            vc.applyOutcome(.unknown(sessionId: "sess_1"))
            waitUntil { vc.currentViewState == .reconciling }

            vc.simulateTapPay()
            XCTAssertNil(delegate.lastRequestedAction, "Re-tapping Pay after unknown must not request a confirm.")
            vc.tapNewCardEntryForTest()
            XCTAssertTrue(vc.isHomeVisibleForTest, "Navigation must be ignored while reconciling.")
            XCTAssertTrue(vc.isNoticeVisibleForTest, "The reconciling notice must not be cleared by navigation.")
            XCTAssertFalse(vc.isConfirmButtonVisibleForTest)
        }

        /// `.failed` keeps today's behavior: inputs interactive again and Pay usable (only pending/unknown lock).
        func test_failed_stillUnlocksInputs_unlikeUnknown() {
            let vc = makeVC(savedCards: sampleSavedCards())
            vc.loadViewIfNeeded()
            let delegate = MockContentDelegate()
            vc.delegate = delegate
            vc.tapSavedCardRowForTest("pm_1")
            vc.simulateTapPay()
            vc.applyOutcome(.failed(txnId: nil, error: CheckoutErrors.paymentFailed()))
            waitUntil { vc.isHomeInteractiveForTest }

            XCTAssertTrue(vc.isHomeInteractiveForTest)
            XCTAssertTrue(vc.isConfirmButtonVisibleForTest)
            XCTAssertTrue(vc.isConfirmButtonEnabledForTest)
        }

        /// A reconciling sheet still accepts a NEW outcome: e.g. a reconciled success auto-closes.
        func test_reconciling_thenSucceeded_autoCloses() {
            let vc = makeVC(savedCards: sampleSavedCards())
            vc.loadViewIfNeeded()
            let delegate = MockContentDelegate()
            vc.delegate = delegate
            vc.tapSavedCardRowForTest("pm_1")
            vc.simulateTapPay()
            vc.applyOutcome(.unknown(sessionId: "sess_1"))
            waitUntil { vc.currentViewState == .reconciling }

            vc.applyOutcome(.succeeded(txnId: "t_late"))
            let deadline = Date().addingTimeInterval(5.0)
            while delegate.finishedOutcome == nil, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            XCTAssertEqual(delegate.finishedOutcome, .succeeded(txnId: "t_late"))
        }

        // MARK: - Header ✕ close availability

        private func waitUntil(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(3.0)
            while !condition(), Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }

        /// In plain `.editing` the ✕ is enabled and cancels.
        func test_close_inEditing_cancels() {
            let vc = makeVC(savedCards: sampleSavedCards())
            vc.loadViewIfNeeded()
            let delegate = MockContentDelegate()
            vc.delegate = delegate
            XCTAssertTrue(vc.isCloseInteractiveForTest)
            vc.invokeHeaderCloseForTest()
            XCTAssertEqual(delegate.cancelCount, 1)
        }

        /// While `.processing` the ✕ is disabled and its action does not cancel.
        func test_close_whileProcessing_isDisabled_andDoesNotCancel() {
            let vc = makeVC(savedCards: sampleSavedCards())
            vc.loadViewIfNeeded()
            let delegate = MockContentDelegate()
            vc.delegate = delegate
            vc.tapSavedCardRowForTest("pm_1")
            vc.simulateTapPay()
            XCTAssertEqual(vc.currentViewState, .processing)
            XCTAssertFalse(vc.isCloseInteractiveForTest)
            XCTAssertTrue(vc.closeHasNotEnabledTraitForTest)
            vc.invokeHeaderCloseForTest()
            XCTAssertEqual(delegate.cancelCount, 0, "✕ must not cancel while a payment is in flight.")
        }

        /// During the success animation (before `didFinishWith`) the ✕ is locked and does not cancel.
        func test_close_duringSuccessAnimation_doesNotCancel() {
            let vc = makeVC(savedCards: sampleSavedCards())
            vc.loadViewIfNeeded()
            let delegate = MockContentDelegate()
            vc.delegate = delegate
            vc.tapSavedCardRowForTest("pm_1")
            vc.simulateTapPay()
            vc.applyOutcome(.succeeded(txnId: "t"))
            waitUntil { vc.currentViewState == .succeeded }
            XCTAssertEqual(vc.currentViewState, .succeeded)
            XCTAssertNil(delegate.finishedOutcome, "Animation must still be running.")
            XCTAssertFalse(vc.isCloseInteractiveForTest)
            vc.invokeHeaderCloseForTest()
            XCTAssertEqual(delegate.cancelCount, 0, "✕ must not cancel during the success animation.")
            waitUntil { delegate.finishedOutcome != nil }
        }

        /// After `.failed`, `.pending` and `.unknown` the ✕ is enabled again and cancels once.
        func test_close_afterNonSuccessOutcomes_isEnabledAgain_andCancels() {
            let outcomes: [CheckoutOutcome] = [
                .failed(txnId: nil, error: CheckoutErrors.paymentFailed()),
                .pending(txnId: "t"),
                .unknown(sessionId: "sess_1"),
            ]
            for outcome in outcomes {
                let vc = makeVC(savedCards: sampleSavedCards())
                vc.loadViewIfNeeded()
                let delegate = MockContentDelegate()
                vc.delegate = delegate
                vc.tapSavedCardRowForTest("pm_1")
                vc.simulateTapPay()
                XCTAssertFalse(vc.isCloseInteractiveForTest)
                vc.applyOutcome(outcome)
                waitUntil { vc.isCloseInteractiveForTest }
                XCTAssertTrue(vc.isCloseInteractiveForTest, "✕ must unlock after \(outcome).")
                XCTAssertFalse(vc.closeHasNotEnabledTraitForTest)
                vc.invokeHeaderCloseForTest()
                XCTAssertEqual(delegate.cancelCount, 1, "✕ must cancel after \(outcome).")
            }
        }

        /// While `.reconciling` the ✕ is interactive (it is the only way out of the locked sheet), exposes
        /// no `.notEnabled` trait, and cancels once.
        func test_close_whileReconciling_isInteractive_andCancels() {
            for outcome in [CheckoutOutcome.pending(txnId: "t"), .unknown(sessionId: "sess_1")] {
                let vc = makeVC(savedCards: sampleSavedCards())
                vc.loadViewIfNeeded()
                let delegate = MockContentDelegate()
                vc.delegate = delegate
                vc.tapSavedCardRowForTest("pm_1")
                vc.simulateTapPay()
                vc.applyOutcome(outcome)
                waitUntil { vc.currentViewState == .reconciling }

                XCTAssertEqual(vc.currentViewState, .reconciling, "(\(outcome))")
                XCTAssertTrue(vc.isCloseInteractiveForTest, "✕ must be interactive while reconciling (\(outcome)).")
                XCTAssertFalse(vc.closeHasNotEnabledTraitForTest)
                vc.invokeHeaderCloseForTest()
                XCTAssertEqual(delegate.cancelCount, 1, "✕ must cancel while reconciling (\(outcome)).")
            }
        }

        /// New-card page: `.pending` and `.unknown` both enter the locked reconciling state (Pay hidden,
        /// card form locked, ✕ available, no second request).
        func test_pendingAndUnknown_onNewCardPage_enterReconciling() {
            for outcome in [CheckoutOutcome.pending(txnId: "t"), .unknown(sessionId: "sess_1")] {
                let vc = makeVC(savedCards: [])
                vc.loadViewIfNeeded()
                vc.openNewCardForTest()
                vc.fillCardForTest()
                let delegate = MockContentDelegate()
                vc.delegate = delegate
                vc.simulateTapPay()
                delegate.lastRequestedAction = nil

                vc.applyOutcome(outcome)
                waitUntil { vc.currentViewState == .reconciling }

                XCTAssertEqual(vc.currentViewState, .reconciling, "(\(outcome))")
                XCTAssertFalse(vc.isCardFormInteractiveForTest, "Card form must stay locked (\(outcome)).")
                XCTAssertFalse(vc.isConfirmButtonVisibleForTest, "Pay must be hidden (\(outcome)).")
                XCTAssertTrue(vc.isCloseInteractiveForTest, "✕ must stay available (\(outcome)).")
                XCTAssertTrue(vc.isNoticeVisibleForTest)
                vc.simulateTapPay()
                XCTAssertNil(delegate.lastRequestedAction, "No second confirm while reconciling (\(outcome)).")
            }
        }

        /// Wallet path: `.pending` and `.unknown` after an Apple Pay confirm enter the locked reconciling
        /// state; a further Apple Pay tap (token still staged) emits nothing.
        func test_pendingAndUnknown_afterWalletConfirm_enterReconciling() {
            for outcome in [CheckoutOutcome.pending(txnId: "t"), .unknown(sessionId: "sess_1")] {
                let vc = makeVC(savedCards: [], methods: [.card, .applePay])
                vc.loadViewIfNeeded()
                let delegate = MockContentDelegate()
                vc.delegate = delegate
                vc.stageWalletToken(Data([1, 2, 3]))
                vc.tapExpressForTest()
                guard case .confirmWallet = delegate.lastRequestedAction else {
                    return XCTFail("precondition: Expected .confirmWallet, got \(String(describing: delegate.lastRequestedAction))")
                }
                delegate.lastRequestedAction = nil

                vc.applyOutcome(outcome)
                waitUntil { vc.currentViewState == .reconciling }

                XCTAssertEqual(vc.currentViewState, .reconciling, "(\(outcome))")
                XCTAssertFalse(vc.isConfirmButtonVisibleForTest, "Pay/spinner must be hidden (\(outcome)).")
                XCTAssertFalse(vc.isHomeInteractiveForTest, "Home (incl. the Apple Pay row) must be locked (\(outcome)).")
                XCTAssertTrue(vc.isCloseInteractiveForTest, "✕ must stay available (\(outcome)).")
                vc.tapExpressForTest()
                XCTAssertNil(delegate.lastRequestedAction, "No second wallet confirm while reconciling (\(outcome)).")
            }
        }

        /// A second real Pay touch while `.processing` must not emit another delegate request.
        func test_payTouchWhileProcessing_doesNotEmitSecondRequest() {
            let vc = makeVC(savedCards: sampleSavedCards())
            vc.loadViewIfNeeded()
            let delegate = MockContentDelegate()
            vc.delegate = delegate
            vc.tapSavedCardRowForTest("pm_1")

            var requests = 0
            final class Counter: CheckoutContentDelegate {
                let inner: MockContentDelegate
                var count = 0
                init(_ inner: MockContentDelegate) { self.inner = inner }
                func content(_ c: CheckoutContentViewController, didRequest action: PaymentSheet.UserAction) {
                    count += 1
                    inner.content(c, didRequest: action)
                }
                func contentDidRequestCancel(_ c: CheckoutContentViewController) {}
                func content(_ c: CheckoutContentViewController, didFinishWith outcome: CheckoutOutcome) {}
                func content(_ c: CheckoutContentViewController, didChangeProcessing isProcessing: Bool) {}
                func content(_ c: CheckoutContentViewController, didUpdateContentHeight height: CGFloat) {}
                func content(_ c: CheckoutContentViewController, didChangeState state: CheckoutPresentationState) {}
            }
            let counter = Counter(delegate)
            vc.delegate = counter

            vc.sendTouchOnPayButtonForTest()
            vc.sendTouchOnPayButtonForTest()
            requests = counter.count

            XCTAssertEqual(vc.currentViewState, .processing)
            XCTAssertEqual(requests, 1, "A Pay touch during processing must not emit a second request.")
        }

        // MARK: - Home page vs new-card subpage (structure B)

        /// With NO saved cards the root is still the HOME page (express + a "New card" entry), not the
        /// card form: a new card needs billing address etc., so the form is always an independent
        /// subpage reached via the "New card" entry. No Pay button until something is submittable.
        func test_noSavedCards_rootIsHomeNotForm_andPayHidden() {
            let vc = makeVC(savedCards: [], methods: [.card, .applePay])
            vc.loadViewIfNeeded()
            XCTAssertTrue(vc.isHomeVisibleForTest, "Home page is the root even with no saved cards.")
            XCTAssertFalse(vc.isNewCardSubpageVisibleForTest, "The card form must not be the root.")
            XCTAssertTrue(vc.isExpressVisibleForTest, "Express shows on the home page.")
            XCTAssertFalse(vc.isConfirmButtonVisibleForTest, "No Pay button with nothing selected.")
        }

        /// Entering the new-card subpage hides express (and the home content); returning home shows it
        /// again. Express is a home-page-only affordance.
        func test_newCardSubpageHidesExpress_homeRestoresIt() {
            let vc = makeVC(savedCards: [], methods: [.card, .applePay])
            vc.loadViewIfNeeded()
            XCTAssertTrue(vc.isExpressVisibleForTest)

            vc.openNewCardForTest()
            XCTAssertTrue(vc.isNewCardSubpageVisibleForTest)
            XCTAssertFalse(vc.isHomeVisibleForTest)
            XCTAssertFalse(vc.isExpressVisibleForTest, "Express must not show on the new-card subpage.")
        }

        // MARK: - Configured-locale formatting

        /// The Pay-button amount is formatted with the host-configured locale, not the device locale.
        /// de-DE uses a comma decimal separator, so its title differs from en-US's.
        func test_payButtonAmountHonorsConfiguredLocale() {
            let en = makeVC(savedCards: [], localeCode: "en-US")
            en.loadViewIfNeeded()
            en.openNewCardForTest()
            en.fillCardForTest()

            let de = makeVC(savedCards: [], localeCode: "de-DE")
            de.loadViewIfNeeded()
            de.openNewCardForTest()
            de.fillCardForTest()

            XCTAssertNotEqual(
                en.payButtonTitleForTest, de.payButtonTitleForTest,
                "the amount must format differently under en-US vs de-DE")
            XCTAssertTrue(
                de.payButtonTitleForTest.contains("19,99"),
                "de-DE must use a comma decimal separator; got \(de.payButtonTitleForTest)")
        }

        /// Error messages localize against the configured locale, not the system/en default.
        func test_errorMessageHonorsConfiguredLocale() {
            let vc = makeVC(savedCards: [], localeCode: "zh-CN")
            vc.loadViewIfNeeded()
            let message = vc.localizedFailureForTest(
                CheckoutError(code: "CHECKOUT_EXPIRED", message: "dev fallback", category: .validation, traceId: nil))
            XCTAssertEqual(message, "结账会话已过期。")
        }

        // MARK: - Contextual close visibility

        /// The ✕ is shown on the home page and hidden on both sub-pages (new-card form and the full
        /// saved-card "View more" list); returning home restores it.
        func test_closeVisibleOnHome_hiddenOnSubpages() {
            let vc = makeVC(savedCards: sampleSavedCards())
            vc.loadViewIfNeeded()
            XCTAssertTrue(vc.isCloseVisibleForTest, "✕ must show on the home page.")

            vc.openNewCardForTest()
            XCTAssertFalse(vc.isCloseVisibleForTest, "✕ must be hidden on the new-card subpage.")

            vc.tapBackForTest()
            XCTAssertTrue(vc.isCloseVisibleForTest, "✕ must return when back on home.")

            vc.tapViewMoreForTest()
            XCTAssertFalse(vc.isCloseVisibleForTest, "✕ must be hidden on the saved-card list subpage.")

            vc.tapBackForTest()
            XCTAssertTrue(vc.isCloseVisibleForTest, "✕ must return when back on home.")
        }

        /// A confirm started from the new-card subpage that ends in `pending`/`unknown` enters the locked
        /// reconciling state. ✕ is the only escape (back is disabled), so it must be re-shown even though
        /// the subpage normally hides it — otherwise the user is trapped.
        func test_closeReappears_whenReconcilingFromNewCardSubpage() {
            for outcome in [CheckoutOutcome.pending(txnId: "t"), .unknown(sessionId: "sess_1")] {
                let vc = makeVC(savedCards: [])
                vc.loadViewIfNeeded()
                vc.openNewCardForTest()
                vc.fillCardForTest()
                XCTAssertFalse(vc.isCloseVisibleForTest, "precondition: ✕ hidden on the subpage (\(outcome)).")
                vc.simulateTapPay()

                vc.applyOutcome(outcome)
                waitUntil { vc.currentViewState == .reconciling }

                XCTAssertEqual(vc.currentViewState, .reconciling, "(\(outcome))")
                XCTAssertTrue(
                    vc.isCloseVisibleForTest,
                    "✕ must be re-shown while reconciling so the user can leave (\(outcome)).")
            }
        }
    }

    // MARK: - Address modes, name options and form values

    /// A US address config whose layout includes first/last name, to prove the per-form name option
    /// (not the backend layout) decides whether names render.
    private struct NameLayoutAddressService: AddressMetadataService {
        /// Whether the postal code field is required by the returned config.
        var postalRequired = true

        func countries(locale: String?) async throws -> AddressCountryList {
            AddressCountryList(countries: [AddressCountry(code: "US", name: "United States")], detectedCountry: "US")
        }

        func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
            func field(_ type: AddressFieldType) -> AddressFieldConfig {
                AddressFieldConfig(
                    type: type, required: type == .postalCode ? postalRequired : true,
                    pattern: nil, label: "x", placeholder: "x")
            }
            let types: [AddressFieldType] = [.country, .firstName, .lastName, .line1, .postalCode]
            return AddressCountryConfig(
                code: countryCode,
                fields: Dictionary(uniqueKeysWithValues: types.map { ($0, field($0)) }),
                layout: [[.country], [.firstName, .lastName], [.line1], [.postalCode]],
                subdivisions: []
            )
        }
    }

    /// A US config with a required 5-digit postal code, to exercise postal gating.
    private struct UsPostalAddressService: AddressMetadataService {
        func countries(locale: String?) async throws -> AddressCountryList {
            AddressCountryList(countries: [AddressCountry(code: "US", name: "United States")], detectedCountry: "US")
        }

        func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
            func field(_ type: AddressFieldType, pattern: String? = nil) -> AddressFieldConfig {
                AddressFieldConfig(type: type, required: true, pattern: pattern, label: "x", placeholder: "x")
            }
            let types: [AddressFieldType] = [.country, .firstName, .lastName, .line1]
            var fields = Dictionary(uniqueKeysWithValues: types.map { ($0, field($0)) })
            fields[.postalCode] = field(.postalCode, pattern: "^[0-9]{5}$")
            return AddressCountryConfig(
                code: countryCode, fields: fields,
                layout: [[.country], [.firstName, .lastName], [.line1], [.postalCode]], subdivisions: [])
        }
    }

    /// A service whose every call fails (metadata outage), so simple mode uses the local fallback.
    private struct ThrowingAddressService: AddressMetadataService {
        struct Down: Error {}
        func countries(locale: String?) async throws -> AddressCountryList { throw Down() }
        func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig { throw Down() }
    }

    @MainActor
    final class CheckoutContentAddressTests: XCTestCase {
        private func makeVC(
            billing: AddressCollectionMode = .automatic,
            shipping: AddressCollectionMode = .automatic,
            collectBilling: Bool = false,
            collectShipping: Bool = false,
            billingEntryUsable: Bool = false,
            shippingEntryUsable: Bool = false,
            billingStyle: Appearance.AddressFormStyle = .full,
            shippingStyle: Appearance.AddressFormStyle = .full,
            localeCode: String? = nil,
            service: any AddressMetadataService = NameLayoutAddressService()
        ) -> (CheckoutContentViewController, AddressDelegate) {
            let session = CheckoutSession(
                id: "s", amount: Amount(minorUnits: 100, currencyCode: "USD"), merchantName: "Demo",
                methods: [.card], expiresAt: Date().addingTimeInterval(600), rsaPublicKey: nil,
                cofEnabled: false, collectBillingAddress: collectBilling,
                collectShippingAddress: collectShipping)
            let vc = CheckoutContentViewController(
                session: session, savedCards: [], appearance: .resolve(.default), localize: { $0 },
                localeCode: localeCode, billingMode: billing, shippingMode: shipping,
                addressService: service, billingEntryUsable: billingEntryUsable,
                shippingEntryUsable: shippingEntryUsable,
                billingStyle: billingStyle, shippingStyle: shippingStyle)
            let delegate = AddressDelegate()
            vc.delegate = delegate
            vc.loadViewIfNeeded()
            vc.openNewCardForTest()
            return (vc, delegate)
        }

        final class AddressDelegate: CheckoutContentDelegate {
            var action: PaymentSheet.UserAction?
            func content(_ content: CheckoutContentViewController, didRequest action: PaymentSheet.UserAction) {
                self.action = action
            }
            func contentDidRequestCancel(_ content: CheckoutContentViewController) {}
            func content(_ content: CheckoutContentViewController, didFinishWith outcome: CheckoutOutcome) {}
            func content(_ content: CheckoutContentViewController, didChangeProcessing isProcessing: Bool) {}
            func content(_ content: CheckoutContentViewController, didUpdateContentHeight height: CGFloat) {}
            func content(_ content: CheckoutContentViewController, didChangeState state: CheckoutPresentationState) {}
        }

        private final class RecordingAddressService: AddressMetadataService, @unchecked Sendable {
            private let inner = NameLayoutAddressService()
            private let lock = NSLock()
            private var _locales: [String?] = []
            var locales: [String?] { lock.lock(); defer { lock.unlock() }; return _locales }
            func countries(locale: String?) async throws -> AddressCountryList {
                lock.lock(); _locales.append(locale); lock.unlock()
                return try await inner.countries(locale: locale)
            }
            func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
                try await inner.countryConfig(countryCode: countryCode, locale: locale)
            }
        }

        func test_pay_noBillingForm_sendsShippingFormValues_andNilBilling() {
            let (vc, delegate) = makeVC(billing: .off, shipping: .simple)
            let shippingForm = vc.shippingAddressViewForTest as? DynamicAddressFormView
            shippingForm?.waitForLoadForTest()
            shippingForm?
                .fillForTest(country: "US", line1: "1 Main", postalCode: "94103", firstName: "Ada", lastName: "L")
            vc.fillCardForTest()
            vc.sendTouchOnPayButtonForTest()
            guard case let .confirmNewCard(_, _, billing, shipping, _, _)? = delegate.action else {
                return XCTFail("expected .confirmNewCard")
            }
            XCTAssertNil(billing)
            XCTAssertEqual(shipping, AddressInput(country: "US", line1: "1 Main", postalCode: "94103", firstName: "Ada", lastName: "L"))
        }

        func test_pay_fullShippingForm_includesFirstAndLastName() {
            let (vc, delegate) = makeVC(billing: .off, shipping: .full)
            let shipping = vc.shippingAddressViewForTest as? DynamicAddressFormView
            shipping?.waitForLoadForTest()
            shipping?.setTextForTest(.firstName, "Ada")
            shipping?.setTextForTest(.lastName, "Lovelace")
            shipping?.setTextForTest(.line1, "1 Main")
            shipping?.setTextForTest(.postalCode, "94103")
            vc.fillCardForTest()
            vc.sendTouchOnPayButtonForTest()
            guard case let .confirmNewCard(_, _, billing, shipping, _, _)? = delegate.action else {
                return XCTFail("expected .confirmNewCard")
            }
            XCTAssertNil(billing)
            XCTAssertEqual(shipping?.firstName, "Ada")
            XCTAssertEqual(shipping?.lastName, "Lovelace")
            XCTAssertEqual(shipping?.line1, "1 Main")
        }

        func test_configuredLocaleReachesDynamicFormCountriesCall() {
            let service = RecordingAddressService()
            let (vc, _) = makeVC(collectBilling: true, localeCode: "zh-CN", service: service)
            (vc.billingAddressViewForTest as? DynamicAddressFormView)?.waitForLoadForTest()
            XCTAssertFalse(service.locales.isEmpty)
            XCTAssertTrue(service.locales.allSatisfy { $0 == "zh-CN" })
        }

        func test_automatic_followsSessionFlags() {
            let (vc, _) = makeVC(collectBilling: true, collectShipping: false)
            XCTAssertTrue(vc.isBillingFormVisibleForTest)
            XCTAssertFalse(vc.isShippingFormVisibleForTest)
        }

        func test_automatic_shippingFlagShowsShippingSection() {
            let (vc, _) = makeVC(collectBilling: false, collectShipping: true)
            XCTAssertFalse(vc.isBillingFormVisibleForTest)
            XCTAssertTrue(vc.isShippingFormVisibleForTest)
        }

        func test_explicitOff_hidesBillingEvenWhenSessionCollects() {
            let (vc, _) = makeVC(billing: .off, collectBilling: true)
            XCTAssertFalse(vc.isBillingFormVisibleForTest)
        }

        func test_fullBillingHasNoNameFields_fullShippingHasNameFields() {
            let (vc, _) = makeVC(collectBilling: true, collectShipping: true)
            let billing = vc.billingAddressViewForTest as? DynamicAddressFormView
            let shipping = vc.shippingAddressViewForTest as? DynamicAddressFormView
            XCTAssertNotNil(billing)
            XCTAssertNotNil(shipping)
            billing?.waitForLoadForTest()
            shipping?.waitForLoadForTest()
            let billingTypes = billing?.renderedFieldTypesForTest ?? []
            let shippingTypes = shipping?.renderedFieldTypesForTest ?? []
            XCTAssertTrue(billingTypes.contains(.line1))
            XCTAssertFalse(billingTypes.contains(.firstName) || billingTypes.contains(.lastName))
            XCTAssertTrue(shippingTypes.contains(.firstName) && shippingTypes.contains(.lastName))
        }

        func test_simpleShippingShowsNameRow_simpleBillingDoesNot() {
            let (vc, _) = makeVC(billing: .simple, shipping: .simple)
            let billing = vc.billingAddressViewForTest as? DynamicAddressFormView
            let shipping = vc.shippingAddressViewForTest as? DynamicAddressFormView
            billing?.waitForLoadForTest()
            shipping?.waitForLoadForTest()
            XCTAssertEqual(billing?.hasNameFieldsForTest, false)
            XCTAssertEqual(shipping?.hasNameFieldsForTest, true)
        }

        func test_simpleShippingReturnsEnteredNames() {
            let (vc, _) = makeVC(billing: .simple, shipping: .simple)
            let shipping = vc.shippingAddressViewForTest as? DynamicAddressFormView
            shipping?.waitForLoadForTest()
            shipping?.fillForTest(country: "US", line1: "1 Main", postalCode: "94103", firstName: "Ada", lastName: "Lovelace")
            XCTAssertEqual(shipping?.addressInput.firstName, "Ada")
            XCTAssertEqual(shipping?.addressInput.lastName, "Lovelace")
        }

        func test_bothForms_shippingFormWithNamePhoneVisible_andValuesReachSubmit() {
            let (vc, delegate) = makeVC(billing: .simple, shipping: .simple)
            XCTAssertTrue(vc.isBillingFormVisibleForTest)
            XCTAssertTrue(vc.isShippingFormVisibleForTest)
            let shippingForm = vc.shippingAddressViewForTest as? DynamicAddressFormView
            let billingForm = vc.billingAddressViewForTest as? DynamicAddressFormView
            billingForm?.waitForLoadForTest()
            shippingForm?.waitForLoadForTest()
            XCTAssertEqual(shippingForm?.hasNameFieldsForTest, true)
            billingForm?
                .fillForTest(country: "US", line1: "1 Main", postalCode: "94103")
            shippingForm?.fillForTest(
                country: "CA", line1: "2 Side", postalCode: "M5V", firstName: "Ada", lastName: "L", phone: "5551234")
            vc.fillCardForTest()
            vc.sendTouchOnPayButtonForTest()
            guard case let .confirmNewCard(_, _, _, shipping, _, _)? = delegate.action else {
                return XCTFail("expected .confirmNewCard")
            }
            XCTAssertEqual(shipping?.country, "CA")
            XCTAssertEqual(shipping?.firstName, "Ada")
            XCTAssertEqual(shipping?.phone, "5551234")
        }

        func test_pay_shippingSectionOff_sendsNilShipping() {
            let (vc, delegate) = makeVC(billing: .simple, shipping: .off)
            let billingForm = vc.billingAddressViewForTest as? DynamicAddressFormView
            billingForm?.waitForLoadForTest()
            billingForm?
                .fillForTest(country: "US", line1: "1 Main", postalCode: "94103")
            vc.fillCardForTest()
            vc.sendTouchOnPayButtonForTest()
            guard case let .confirmNewCard(_, _, billing, shipping, _, _)? = delegate.action else {
                return XCTFail("expected .confirmNewCard")
            }
            XCTAssertNotNil(billing)
            XCTAssertNil(shipping)
        }

        func test_pay_separateShipping_sendsShippingFormValues() {
            let (vc, delegate) = makeVC(billing: .simple, shipping: .simple)
            let billingForm = vc.billingAddressViewForTest as? DynamicAddressFormView
            let shippingForm = vc.shippingAddressViewForTest as? DynamicAddressFormView
            billingForm?.waitForLoadForTest()
            shippingForm?.waitForLoadForTest()
            billingForm?
                .fillForTest(country: "US", line1: "1 Main", postalCode: "94103")
            shippingForm?
                .fillForTest(country: "CA", line1: "2 Side", postalCode: "M5V", firstName: "Ada", lastName: "L")
            vc.fillCardForTest()
            vc.sendTouchOnPayButtonForTest()
            guard case let .confirmNewCard(_, _, _, shipping, _, _)? = delegate.action else {
                return XCTFail("expected .confirmNewCard")
            }
            XCTAssertEqual(shipping?.country, "CA")
            XCTAssertEqual(shipping?.firstName, "Ada")
        }

        func test_automatic_usableBillingEntry_hidesBillingForm() {
            let (vc, _) = makeVC(collectBilling: true, billingEntryUsable: true)
            XCTAssertNil(vc.billingAddressViewForTest)
        }

        func test_automatic_unusableBillingEntry_showsFullBillingForm() {
            let (vc, _) = makeVC(collectBilling: true, billingEntryUsable: false)
            XCTAssertTrue(vc.billingAddressViewForTest is DynamicAddressFormView)
        }

        func test_automatic_formStyleIsIndependentOfVisibility() {
            let (simple, _) = makeVC(
                collectBilling: true, collectShipping: true, billingStyle: .simple, shippingStyle: .simple)
            XCTAssertTrue(simple.billingAddressViewForTest is DynamicAddressFormView)
            XCTAssertTrue(simple.shippingAddressViewForTest is DynamicAddressFormView)

            let (full, _) = makeVC(collectBilling: true, collectShipping: true)
            XCTAssertTrue(full.billingAddressViewForTest is DynamicAddressFormView)
            XCTAssertTrue(full.shippingAddressViewForTest is DynamicAddressFormView)

            // The style never overrides the session flag.
            let (hidden, _) = makeVC(collectBilling: false, billingStyle: .full)
            XCTAssertNil(hidden.billingAddressViewForTest)
        }

        func test_automatic_usableShippingEntry_hidesShippingForm() {
            let (vc, _) = makeVC(collectShipping: true, shippingEntryUsable: true)
            XCTAssertNil(vc.shippingAddressViewForTest)
        }

        func test_explicitSimple_withUsableEntry_showsFormAndReportsFormShown() {
            let (vc, delegate) = makeVC(
                billing: .simple, shipping: .off, collectBilling: true, billingEntryUsable: true,
                service: NameLayoutAddressService(postalRequired: false))
            let billingForm = vc.billingAddressViewForTest as? DynamicAddressFormView
            XCTAssertNotNil(billingForm)
            // Pay from the loaded state: the postal field is optional, so an empty form passes validation.
            billingForm?.waitForLoadForTest()
            vc.fillCardForTest()
            vc.sendTouchOnPayButtonForTest()
            guard case let .confirmNewCard(_, _, _, _, billingShown, shippingShown)? = delegate.action else {
                return XCTFail("expected .confirmNewCard")
            }
            XCTAssertTrue(billingShown)
            XCTAssertFalse(shippingShown)
        }

        func test_pay_noForms_reportsNoFormShown() {
            let (vc, delegate) = makeVC(collectBilling: true, billingEntryUsable: true)
            vc.fillCardForTest()
            vc.sendTouchOnPayButtonForTest()
            guard case let .confirmNewCard(_, _, _, _, billingShown, shippingShown)? = delegate.action else {
                return XCTFail("expected .confirmNewCard")
            }
            XCTAssertFalse(billingShown)
            XCTAssertFalse(shippingShown)
        }

        func test_simpleForms_phoneOnShippingOnly() {
            let (vc, _) = makeVC(billing: .simple, shipping: .simple)
            let billing = vc.billingAddressViewForTest as? DynamicAddressFormView
            let shipping = vc.shippingAddressViewForTest as? DynamicAddressFormView
            billing?.waitForLoadForTest()
            shipping?.waitForLoadForTest()
            XCTAssertEqual(billing?.hasPhoneFieldForTest, false)
            XCTAssertEqual(shipping?.hasPhoneFieldForTest, true)
        }

        func test_fullForms_phoneOnShippingOnly() {
            let (vc, _) = makeVC(billing: .full, shipping: .full)
            let billing = vc.billingAddressViewForTest as? DynamicAddressFormView
            let shipping = vc.shippingAddressViewForTest as? DynamicAddressFormView
            billing?.waitForLoadForTest()
            shipping?.waitForLoadForTest()
            XCTAssertEqual(billing?.hasPhoneFieldForTest, false)
            XCTAssertEqual(shipping?.hasPhoneFieldForTest, true)
        }

        func test_simpleShipping_returnsPhone() {
            let (vc, _) = makeVC(billing: .off, shipping: .simple)
            let shipping = vc.shippingAddressViewForTest as? DynamicAddressFormView
            shipping?.waitForLoadForTest()
            shipping?.fillForTest(country: "US", line1: "1 Main", postalCode: "94103", phone: "5551234")
            XCTAssertEqual(shipping?.addressInput.phone, "5551234")
        }

        func test_fullShipping_returnsPhone() {
            let (vc, _) = makeVC(billing: .off, shipping: .full)
            let shipping = vc.shippingAddressViewForTest as? DynamicAddressFormView
            shipping?.waitForLoadForTest()
            shipping?.setPhoneForTest("5551234")
            XCTAssertEqual(shipping?.addressInput.phone, "5551234")
        }

        // MARK: - Simple mode postal gating (new-card confirm only)

        func test_simpleBilling_invalidPostal_blocksConfirm() {
            let (vc, delegate) = makeVC(billing: .simple, shipping: .off, service: UsPostalAddressService())
            let billing = vc.billingAddressViewForTest as? DynamicAddressFormView
            billing?.waitForLoadForTest()
            billing?.setPostalCodeForTest("1234")
            vc.fillCardForTest()
            vc.sendTouchOnPayButtonForTest()
            XCTAssertNil(delegate.action)
            XCTAssertEqual(billing?.postalErrorMessageForTest, "sunbay.address.postalCode.invalid")
            XCTAssertEqual(vc.currentViewState, .editing)
        }

        func test_simpleBilling_validPostal_confirms() {
            let (vc, delegate) = makeVC(billing: .simple, shipping: .off, service: UsPostalAddressService())
            let billing = vc.billingAddressViewForTest as? DynamicAddressFormView
            billing?.waitForLoadForTest()
            billing?.setPostalCodeForTest("94103")
            vc.fillCardForTest()
            vc.sendTouchOnPayButtonForTest()
            guard case let .confirmNewCard(_, _, billingInput, _, _, _)? = delegate.action else {
                return XCTFail("expected .confirmNewCard")
            }
            XCTAssertEqual(billingInput?.postalCode, "94103")
        }

        func test_simpleBilling_payWhileMetadataLoading_isIgnored_thenConfirmsAfterLoad() {
            let (vc, delegate) = makeVC(billing: .simple, shipping: .off, service: UsPostalAddressService())
            let billing = vc.billingAddressViewForTest as? DynamicAddressFormView
            vc.fillCardForTest(awaitingAddressLoad: false)
            vc.sendTouchOnPayButtonForTest()
            XCTAssertNil(delegate.action, "A Pay tap while address metadata loads must not submit.")
            XCTAssertEqual(vc.currentViewState, .editing)

            billing?.waitForLoadForTest()
            billing?.setPostalCodeForTest("94103")
            vc.sendTouchOnPayButtonForTest()
            guard case let .confirmNewCard(_, _, billingInput, _, _, _)? = delegate.action else {
                return XCTFail("expected .confirmNewCard")
            }
            XCTAssertEqual(billingInput?.postalCode, "94103")
        }

        func test_bothFormsInvalid_showBothErrors_noConfirm() {
            let (vc, delegate) = makeVC(billing: .simple, shipping: .simple, service: UsPostalAddressService())
            let billing = vc.billingAddressViewForTest as? DynamicAddressFormView
            let shipping = vc.shippingAddressViewForTest as? DynamicAddressFormView
            billing?.waitForLoadForTest()
            shipping?.waitForLoadForTest()
            billing?.setPostalCodeForTest("1234")
            shipping?.setPostalCodeForTest("")
            vc.fillCardForTest()
            vc.sendTouchOnPayButtonForTest()
            XCTAssertNil(delegate.action)
            XCTAssertEqual(billing?.postalErrorMessageForTest, "sunbay.address.postalCode.invalid")
            XCTAssertEqual(shipping?.postalErrorMessageForTest, "sunbay.address.postalCode.required")
            XCTAssertEqual(vc.currentViewState, .editing)
        }

        func test_simpleBilling_metadataDown_nonEmptyPostalConfirms_emptyBlocked() {
            let (vc, delegate) = makeVC(billing: .simple, shipping: .off, service: ThrowingAddressService())
            let billing = vc.billingAddressViewForTest as? DynamicAddressFormView
            billing?.waitForLoadForTest()
            vc.fillCardForTest()
            vc.sendTouchOnPayButtonForTest()
            XCTAssertNil(delegate.action)
            XCTAssertEqual(billing?.postalErrorMessageForTest, "sunbay.address.postalCode.required")

            billing?.setPostalCodeForTest("12345")
            vc.sendTouchOnPayButtonForTest()
            guard case let .confirmNewCard(_, _, billingInput, _, _, _)? = delegate.action else {
                return XCTFail("expected .confirmNewCard")
            }
            XCTAssertEqual(billingInput?.postalCode, "12345")
        }

        func test_savedCard_notGatedByAddressValidation() {
            let session = CheckoutSession(
                id: "s", amount: Amount(minorUnits: 100, currencyCode: "USD"), merchantName: "Demo",
                methods: [.card], expiresAt: Date().addingTimeInterval(600), rsaPublicKey: nil,
                cofEnabled: true)
            let vc = CheckoutContentViewController(
                session: session,
                savedCards: [SavedCard(id: "pm_1", brand: "visa", last4: "4242", expMonth: 8, expYear: 2028)],
                appearance: .resolve(.default), localize: { $0 },
                billingMode: .simple, shippingMode: .off, addressService: UsPostalAddressService(),
                cardOnFileEnabled: true)
            let delegate = AddressDelegate()
            vc.delegate = delegate
            vc.loadViewIfNeeded()
            vc.openNewCardForTest()
            let billing = vc.billingAddressViewForTest as? DynamicAddressFormView
            billing?.waitForLoadForTest()
            billing?.setPostalCodeForTest("1234")
            // Prove the new-card path is gated by the invalid postal code first.
            vc.fillCardForTest()
            vc.sendTouchOnPayButtonForTest()
            XCTAssertNil(delegate.action)
            XCTAssertEqual(billing?.postalErrorMessageForTest, "sunbay.address.postalCode.invalid")
            vc.tapBackForTest()
            vc.selectSavedCardForTest("pm_1")
            vc.simulateTapPay()
            guard case let .confirmSavedCard(paymentMethodId)? = delegate.action else {
                return XCTFail("expected .confirmSavedCard, got \(String(describing: delegate.action))")
            }
            XCTAssertEqual(paymentMethodId, "pm_1")
        }

    }

    extension CheckoutContentViewControllerTests {
        // MARK: - Expired saved cards

        private func expiredAndUsableCards() -> [SavedCard] {
            [
                SavedCard(id: "pm_old", brand: "visa", last4: "1111", expMonth: 1, expYear: 2020),
                SavedCard(id: "pm_ok", brand: "mastercard", last4: "5454", expMonth: 12, expYear: 2099),
            ]
        }

        func test_expiredSavedCard_isListedLast_andNotPreSelected() {
            let vc = makeVC(savedCards: expiredAndUsableCards())
            vc.loadViewIfNeeded()
            XCTAssertEqual(vc.highlightedSavedCardIdForTest, "pm_ok")
            XCTAssertEqual(vc.savedCardOrderForTest, ["pm_ok", "pm_old"])
            XCTAssertTrue(vc.isConfirmButtonVisibleForTest)
        }

        func test_allSavedCardsExpired_nothingSelected_payHidden() {
            let vc = makeVC(savedCards: [expiredAndUsableCards()[0]])
            vc.loadViewIfNeeded()
            let delegate = MockContentDelegate()
            vc.delegate = delegate
            XCTAssertNil(vc.highlightedSavedCardIdForTest)
            XCTAssertFalse(vc.isConfirmButtonVisibleForTest)
            vc.simulateTapPay()
            XCTAssertNil(delegate.lastRequestedAction)
        }

        func test_expiredSavedCard_cannotBePickedFromFullList() {
            let vc = makeVC(savedCards: expiredAndUsableCards())
            vc.loadViewIfNeeded()
            let delegate = MockContentDelegate()
            vc.delegate = delegate
            vc.tapViewMoreForTest()
            vc.tapFullListRowForTest("pm_old")
            XCTAssertEqual(vc.highlightedSavedCardIdForTest, "pm_ok")
            vc.selectSavedCardForTest("pm_old")
            vc.simulateTapPay()
            XCTAssertNil(delegate.lastRequestedAction, "An expired card must never be submitted.")
        }

        func test_expiredSavedCardRow_showsExpiredLabel_andIsNotEnabled() {
            let row = SavedCardRow(
                appearance: .resolve(.default), card: expiredAndUsableCards()[0], expiredText: "sunbay.cof.expired")
            XCTAssertEqual(row.expiryTextForTest, "sunbay.cof.expired")
            XCTAssertTrue(row.accessibilityTraits.contains(.notEnabled))
            let ok = SavedCardRow(appearance: .resolve(.default), card: expiredAndUsableCards()[1])
            XCTAssertEqual(ok.expiryTextForTest, "12/99")
            XCTAssertFalse(ok.accessibilityTraits.contains(.notEnabled))
        }
    }
#endif
