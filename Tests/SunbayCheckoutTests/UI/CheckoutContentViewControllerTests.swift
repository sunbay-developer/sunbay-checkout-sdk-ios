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
            appearance: Appearance = .default, cofEnabled: Bool = false
        ) -> CheckoutContentViewController {
            CheckoutContentViewController(
                session: makeSession(methods: methods, cofEnabled: cofEnabled),
                savedCards: savedCards,
                appearance: .resolve(appearance),
                localize: { $0 },
                billingMode: .simple,
                shippingMode: .simple,
                addressService: MockAddressService()
            )
        }

        // MARK: - Tests

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

        /// On the saved-card home page with nothing selected, the Pay button is hidden (a wallet-only
        /// / list home shows no bottom Pay button until a card is selected).
        func test_payButtonHiddenWhenNothingSelectedOnSavedList() {
            let vc = makeVC(savedCards: sampleSavedCards())
            vc.loadViewIfNeeded()
            XCTAssertFalse(
                vc.isConfirmButtonVisibleForTest,
                "With no saved card selected, the Pay button must be hidden on the list home page.")
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

        /// home → select → New card → back: no row stays highlighted and Pay is hidden.
        func test_homeToNewCardAndBack_clearsHighlight_andHidesPay() {
            let vc = makeVC(savedCards: sampleSavedCards())
            vc.loadViewIfNeeded()
            vc.tapSavedCardRowForTest("pm_2")
            XCTAssertEqual(vc.highlightedSavedCardIdForTest, "pm_2")

            vc.tapNewCardEntryForTest()
            vc.tapBackForTest()

            XCTAssertTrue(vc.isHomeVisibleForTest)
            XCTAssertNil(vc.highlightedSavedCardIdForTest, "No saved row may look selected.")
            XCTAssertFalse(vc.isConfirmButtonVisibleForTest, "Pay hidden with nothing selected.")
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
            let vc = makeVC(savedCards: savedCards, methods: [.card, .applePay], cofEnabled: true)
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = vc
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            vc.view.layoutIfNeeded()

            let headerHeight = vc.headerContainerForTest.frame.height
            XCTAssertGreaterThanOrEqual(headerHeight, 44, "Header row too small: \(headerHeight)", file: file, line: line)
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

        /// Selecting a saved card makes the Pay button appear in the fixed bottom bar, which must be
        /// re-reported (no navigation involved); deselecting via navigation shrinks it again.
        func test_reportedHeight_growsWhenPayAppears_shrinksWhenNavigationResets() {
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
            guard let before = delegate.heights.last else { return XCTFail("No initial height reported.") }
            XCTAssertFalse(vc.isConfirmButtonVisibleForTest)

            vc.tapSavedCardRowForTest("pm_1")
            XCTAssertTrue(vc.isConfirmButtonVisibleForTest)
            guard let withPay = delegate.heights.last else { return XCTFail("No height after selection.") }
            XCTAssertGreaterThan(withPay, before + 20, "Pay button appearing must grow the reported height.")

            // New card → back clears the selection: Pay hides again and the height shrinks back.
            vc.tapNewCardEntryForTest()
            vc.tapBackForTest()
            XCTAssertFalse(vc.isConfirmButtonVisibleForTest)
            guard let after = delegate.heights.last else { return XCTFail("No height after reset.") }
            XCTAssertLessThan(after, withPay, "Hiding Pay must shrink the reported height.")
            XCTAssertEqual(after, before, accuracy: 1.0)
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
    }
#endif
