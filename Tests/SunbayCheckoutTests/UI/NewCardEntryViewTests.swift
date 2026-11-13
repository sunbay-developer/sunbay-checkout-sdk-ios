#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Tests for the extracted `NewCardEntryView` (card form + save row + address forms).
    @MainActor
    final class NewCardEntryViewTests: XCTestCase {
        /// An address service with a required, 5-digit postal code.
        private struct PostalAddressService: AddressMetadataService {
            func countries(locale: String?) async throws -> AddressCountryList {
                AddressCountryList(countries: [AddressCountry(code: "US", name: "United States")], detectedCountry: "US")
            }

            func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
                func field(_ type: AddressFieldType, _ label: String, pattern: String? = nil) -> AddressFieldConfig {
                    AddressFieldConfig(
                        type: type, required: true, pattern: pattern, label: label, placeholder: label)
                }
                return AddressCountryConfig(
                    code: countryCode,
                    fields: [
                        .country: field(.country, "Country"),
                        .line1: field(.line1, "Address"),
                        .postalCode: field(.postalCode, "ZIP", pattern: "^[0-9]{5}$"),
                    ],
                    layout: [[.country], [.line1], [.postalCode]],
                    subdivisions: [])
            }
        }

        private final class CountingRulesService: CardRulesService, @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0
            var onCall: (() -> Void)?
            var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
            func fetchRules(ifNoneMatch etag: String?) async throws -> CardRulesFetchResult {
                lock.lock()
                calls += 1
                lock.unlock()
                onCall?()
                return .notModified
            }
        }

        private func makeEntry(rulesService: any CardRulesService, store: CardRulesStore, gate: CardRulesRefreshGate)
            -> NewCardEntryView
        {
            NewCardEntryView(
                appearance: .resolve(.default), localize: { $0 }, localeCode: nil, sessionId: "s",
                cardBrandItems: [], cardRuleSet: CardRulesProvider.activeRuleSet(store: store),
                cardBinService: EmptyCardBinService(), cardRulesService: rulesService,
                billingMode: .off, shippingMode: .off, addressService: PostalAddressService(),
                cardOnFileEnabled: false, saveCardByDefault: false, scanPresenter: { nil },
                cardRulesStore: store, cardRulesGate: gate)
        }

        func test_init_triggersRulesRefreshOnce_forBackToBackForms() async {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CardRulesStore(directory: dir)
            let gate = CardRulesRefreshGate()
            let service = CountingRulesService()
            let fetched = expectation(description: "fetched")
            service.onCall = { fetched.fulfill() }
            let first = makeEntry(rulesService: service, store: store, gate: gate)
            let second = makeEntry(rulesService: service, store: store, gate: gate)
            await fulfillment(of: [fetched], timeout: 2)
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(service.callCount, 1)
            withExtendedLifetime((first, second)) {}
        }

        func test_init_withEmptyService_neverFetchesAndKeepsTheGateFree() {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let gate = CardRulesRefreshGate()
            let entry = makeEntry(
                rulesService: EmptyCardRulesService(), store: CardRulesStore(directory: dir), gate: gate)
            XCTAssertTrue(gate.claim(), "the empty default must not consume the gate")
            XCTAssertNil(CardRulesStore(directory: dir).load())
            withExtendedLifetime(entry) {}
        }

        private func makeEntry(
            billing: AddressCollectionMode = .off, cardOnFile: Bool = true, saveByDefault: Bool = false,
            scanPresenter: @escaping () -> UIViewController? = { nil }
        ) -> NewCardEntryView {
            NewCardEntryView(
                appearance: .resolve(.default), localize: { $0 }, localeCode: nil, sessionId: "s",
                cardBrandItems: [], cardRuleSet: CardRulesProvider.activeRuleSet(),
                cardBinService: EmptyCardBinService(), cardRulesService: EmptyCardRulesService(),
                billingMode: billing, shippingMode: .off, addressService: PostalAddressService(),
                cardOnFileEnabled: cardOnFile, saveCardByDefault: saveByDefault,
                scanPresenter: scanPresenter)
        }

        func test_makeConfirmAction_validCard_returnsConfirmNewCardWithSaveFlag() {
            let entry = makeEntry(saveByDefault: false)
            entry.fillCardForTest()
            entry.setSaveCard(true)
            guard case let .confirmNewCard(input, save, billing, shipping, billingShown, shippingShown)? =
                entry.makeConfirmAction()
            else { return XCTFail("Expected a confirmNewCard action") }
            XCTAssertEqual(input.cardNumber, "4242424242424242")
            XCTAssertTrue(save)
            XCTAssertNil(billing)
            XCTAssertNil(shipping)
            XCTAssertFalse(billingShown)
            XCTAssertFalse(shippingShown)
        }

        func test_makeConfirmAction_incompleteCard_returnsNilAndShowsFieldError() {
            let entry = makeEntry()
            XCTAssertNil(entry.makeConfirmAction())
            XCTAssertTrue(entry.hasCardFieldError)
        }

        func test_makeConfirmAction_invalidShownAddress_returnsNilAndFocusesFirstError() {
            let entry = makeEntry(billing: .simple)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
            let host = UIViewController()
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.addSubview(entry)
            entry.frame = CGRect(x: 0, y: 0, width: 358, height: 700)
            entry.fillCardForTest()
            XCTAssertTrue(entry.billingFormShown)
            XCTAssertNil(entry.makeConfirmAction(), "A required postal code is empty.")
            let form = entry.billingAddressView as? DynamicAddressFormView
            XCTAssertNotNil(form?.postalErrorMessageForTest)
            XCTAssertTrue(window.firstResponderForTest != nil, "The first offending field gains focus.")
        }

        func test_isComplete_followsCardValidity() {
            let entry = makeEntry()
            XCTAssertFalse(entry.isComplete)
            entry.fillCardForTest()
            XCTAssertTrue(entry.isComplete)
        }

        func test_detectedBrandName_isBrandOnly_noDigits() {
            let entry = makeEntry()
            XCTAssertNil(entry.detectedBrandName)
            entry.typePANForTest("4242424242424242")
            let name = entry.detectedBrandName
            XCTAssertNotNil(name)
            XCTAssertFalse(name!.contains(where: \.isNumber))
        }

        func test_setInteractionEnabled_false_disablesAllInputs() {
            let entry = makeEntry(billing: .simple)
            entry.setInteractionEnabled(false)
            XCTAssertFalse(entry.isCardFormInteractive)
            XCTAssertFalse(entry.billingAddressView?.isUserInteractionEnabled ?? true)
            entry.setInteractionEnabled(true)
            XCTAssertTrue(entry.isCardFormInteractive)
            XCTAssertTrue(entry.billingAddressView?.isUserInteractionEnabled ?? false)
        }

        func test_clear_emptiesFieldsAndErrors() {
            let entry = makeEntry()
            entry.fillCardForTest()
            XCTAssertTrue(entry.isComplete)
            _ = entry.makeConfirmAction()
            entry.clear()
            XCTAssertFalse(entry.isComplete)
            XCTAssertFalse(entry.hasCardFieldError)
            XCTAssertNil(entry.makeConfirmAction())
            entry.clear()
            XCTAssertFalse(entry.hasCardFieldError)
        }

        func test_clear_alsoEmptiesShownAddressForms() {
            let entry = makeEntry(billing: .simple)
            entry.fillCardForTest()
            let form = entry.billingAddressView as? DynamicAddressFormView
            form?.setPostalCodeForTest("94107")
            form?.setTextForTest(.line1, "1 Main")
            XCTAssertEqual(form?.addressInput.postalCode, "94107")
            entry.clear()
            XCTAssertNil(form?.addressInput.postalCode)
            XCTAssertNil(form?.addressInput.line1)
            XCTAssertNil(form?.postalErrorMessageForTest)
        }
    }

    private extension UIWindow {
        /// The current first responder inside the window, if any.
        var firstResponderForTest: UIView? {
            func find(_ view: UIView) -> UIView? {
                if view.isFirstResponder { return view }
                for sub in view.subviews { if let hit = find(sub) { return hit } }
                return nil
            }
            return find(self)
        }
    }
#endif
