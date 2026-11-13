# Checkout Elements (Block 2): embeddable payment components

Status: awaiting approval (builder-check rulings included). Size: project. Replaces the earlier "rows + form sheet" embedded design. Builds on
Block 1 (`2026-11-12-embedded-foundation-design.md`, implemented): `CheckoutSessionDriver`,
`SavedCardSelection`.

## Intent

Merchants need to embed payment into their own screen and control the layout, including their own Pay button.
We offer one **component per payment-method family**, each with its own parameters and each also controlled by
the global checkout configuration. This mirrors Stripe Web's separate Express Checkout / Card elements that the
merchant arranges on its own page, and keeps card data inside the SDK.

## Decisions already made (product owner)

- Components: `ExpressCheckoutElement` (all quick wallets as one component; today only Apple Pay) and
  `CardElement` (bank card). Any future payment method is another component of the same kind.
- Each component has its own configuration and also honors the global `CheckoutConfiguration`.
- Express can be configured to show only Apple Pay (and later only chosen wallets).
- **`ApplePayButton` (L3) is removed.** Everything goes through `ExpressCheckoutElement`. There are no git tags
  or releases yet, so this is not a breaking change in the semver sense; `ApplePayButtonType` and
  `Appearance.ApplePayButtonStyle` stay (the sheet and the express component use them).
- No atomic field components; a merchant who needs fully custom fields uses a low-level API at its own PCI
  responsibility (separate project).
- Not supported: `CustomerSheet`, `PaymentMethodMessagingElement`. `AddressViewController` stays optional and
  separate; `FlowController` is re-evaluated after this block (the new model reduces its need).
- Merchant owns the Pay button for the card; the SDK does not ship one.

## Assumptions I made (proposals; object if wrong)

- A shared group object `CheckoutElements` loads the session once and owns the single payment lock; components
  are created from it.
- `CardElement` contains: saved cards (radio rows) + a "new card" form + billing/shipping address forms (per
  configuration) + "save this card" checkbox. Saved-card delete/manage is not in v1.
- Component configuration overrides the global value; global filters decide availability (see Precedence).

## Goals

1. Public `CheckoutElements`, `ExpressCheckoutElement`, `CardElement` (UIKit-gated), self-sizing `view`s.
2. Express taps pay immediately and report a `CheckoutOutcome`; the card is paid by `elements.confirm()`.
3. No public way to read card values, wallet tokens, secrets or ciphertext.
4. Reuse Block 1 (`CheckoutSessionDriver`, `SavedCardSelection`) and the existing internal views.
5. Remove `ApplePayButton`; migrate its tests, demo and docs to `ExpressCheckoutElement`.

## Non-goals

SwiftUI wrappers (API is shaped for them), SDK-provided Pay button, saved-card delete/manage, `FlowController`,
`AddressViewController`, address autocomplete, atomic fields, more than one `CardElement` per
`CheckoutElements`.

## Constraints

AGENTS.md: Core UI-agnostic; only `CardEncryptor` touches plaintext and only `CredentialStore` holds secrets;
nothing sensitive in logs/analytics/callbacks/persistence; payment truth is server-confirmed, no polling, no blind
resubmit; English only; small public API (`UserAction`, `CheckoutContext`, `CardInput` stay internal). iOS 15.

## Public API (proposal; names may change)

```swift
@MainActor public final class CheckoutElements {
    public struct Configuration {            // per-session inputs, like PaymentSheet's init
        public var customerAccessSecret: String?
        public var checkoutClientSecret: String?
        public var billingAddress: AddressInput?
        public var shippingAddress: AddressInput?
        public init()
    }
    public static func create(checkout: SunbayCheckout, sessionId: String,
                              configuration: Configuration = .init()) async throws -> CheckoutElements
    public func makeExpressCheckoutElement(_ configuration: ExpressCheckoutElement.Configuration = .init()) -> ExpressCheckoutElement
    public func makeCardElement(_ configuration: CardElement.Configuration = .init()) -> CardElement
    public var paymentOption: PaymentOptionDisplayData? { get }      // display only
    public func confirm() async -> CheckoutOutcome                    // pays the card element's selection
    public func retrievePayment() async throws -> PaymentSnapshot
    public func close()                                               // ends the session, clears the form
}
@MainActor public final class ExpressCheckoutElement {
    public struct Configuration {
        public var methods: Set<ExpressMethod>?          // nil = all available; e.g. [.applePay]
        public var buttonType: ApplePayButtonType?       // nil = global Appearance
        public var buttonStyle: Appearance.ApplePayButtonStyle?
        public init()
    }
    public enum ExpressMethod { case applePay }
    public var view: UIView { get }
    public private(set) var isAvailable: Bool
    public var onAvailabilityChange: ((Bool) -> Void)?
    public var onResult: ((CheckoutOutcome) -> Void)?    // after a tap's payment completes
}
@MainActor public final class CardElement {
    public struct Configuration {
        public var showsSavedCards: Bool?                // nil = follow COF being effective
        public var billingAddress: AddressMode?          // nil = global Appearance
        public var shippingAddress: AddressMode?
        public var showsSaveCardOption: Bool?            // nil = follow COF being effective
        public init()
    }
    public enum AddressMode { case automatic, off }
    public var view: UIView { get }
    public private(set) var isAvailable: Bool
    public private(set) var isComplete: Bool             // ready to pay (selection made / form complete)
    public weak var delegate: CardElementDelegate?        // height changed, completeness/selection changed
    public func clear()
}
public struct PaymentOptionDisplayData: Sendable {  public let label: String; public let image: UIImage?; public let paymentMethodType: String }
```
`create` throws a `CheckoutError` only for a start failure (never a payment outcome).

## Behavior

- **One session, one lock.** `create` runs `CheckoutSessionDriver.loadContext()` once. A single `isConfirming`
  lock covers every payment path (express tap, `confirm()`); a second request while one is in flight yields
  `.failed(ALREADY_PRESENTING)`. While locked the card inputs and express buttons are disabled.
- **Express tap = pay.** The element calls `WalletAuthorizing.authorize` and runs
  `driver.execute(.confirmWallet(authorization, billingFormShown: false, shippingFormShown: false))` in its confirm
  closure (no SDK address form on this path; PassKit collects contacts the session asks for), then reports the
  outcome through `onResult`. Merchant id, params and amount come from the session as in `PaymentSheet`.
- **`confirm()` pays the card.** With a saved card selected: `.confirmSavedCard` (uses only a usable host address
  from `Configuration`, as `PaymentSheet` does). With the new-card form: validate the card and the shown address
  forms (errors appear inline in the fields), then `.confirmNewCard`; invalid input returns
  `.failed(CARD_INPUT_INVALID)` without submitting. No card element or nothing selected ->
  `.failed(NO_PAYMENT_OPTION_SELECTED)`. `confirm()` takes no amount: the amount always comes from the server session.
- **No notices from elements.** `CardElement` shows only inline field validation errors; it does not render
  failure, pending or unknown notices or a spinner (those belong to the merchant's own UI, driven by the
  `CheckoutOutcome` returned by `confirm()`/`onResult`). To let merchants show a proper message, expose a small
  public accessor for the localized user-facing text of a `CheckoutError` (today
  `localizedDisplayMessage(using:)` is internal) if one does not already exist.
- **`paymentOption` content.** Saved card: brand image + "Visa ····4242" from the server list. Typed new card:
  brand image + localized brand name only, no digits; `nil` while the form is empty or incomplete. Apple Pay is not a
  `paymentOption` (it pays on tap). Typed card values are never readable.
- **Host addresses.** `CheckoutElements.updateAddresses(billing:shipping:)` (public) forwards to the controller's
  `updateHostAddresses`, replacing the mutable properties `ApplePayButton` had.
- **Outcomes.** `.succeeded` ends the session (`controller.dismiss()`), clears the form and disables everything;
  `.failed` keeps everything for a retry (the form re-encrypts with a fresh timestamp and `attemptId`);
  `.pending`/`.unknown` lock the elements (no resubmit; `confirm()` returns the stored outcome again; the host
  reconciles with `retrievePayment()`).
- **Session expiry.** A timer on `session.expiresAt` disables the elements, calls `controller.dismiss()`, clears the
  form and makes `confirm()` return `.failed(CHECKOUT_EXPIRED)`. `close()` and deinit also dismiss.
- **"Nothing available" is not a start failure for elements.** `CheckoutSessionDriver.loadContext()` currently
  returns `.startFailed(NO_PAYMENT_METHOD_AVAILABLE)` (and dismisses the controller) when no method survives
  filtering; the sheet needs that. Block 1's `DriverOptions` gets an additive flag
  `failsWhenNoMethodAvailable: Bool = true`; `CheckoutElements.create` sets it to `false`, so the context comes back
  `.ready` with no visible entries and each element derives its own availability. `create` therefore throws only
  when the session itself cannot be loaded (or is expired). `PaymentSheet` and its tests are unchanged.
- **Availability.** An element with nothing to show (the global filter hid its method, the device cannot do Apple
  Pay, no merchant id, CARD hidden) reports `isAvailable == false`, renders a zero-height view and calls
  `onAvailabilityChange(false)` once.

## Precedence of configuration

Per setting: **component configuration > global `CheckoutConfiguration`/`Appearance` default**, with two kinds of
exceptions where the global side always wins: (1) availability: the global `PaymentMethodFilter` and provider
availability (a hidden method cannot be forced on by a component); (2) address forms: the backend decides whether an
address is collected and the host may only switch a form *off* (existing rule). So `CardElement.Configuration`'s
address mode can only switch a form off further (`.automatic` = follow the session and the global switch; `.off` =
hide); it can never show a form the global switch or the session turned off. The address style (`.simple`/`.full`)
comes from the global `Appearance`. Host-address usability is evaluated once at `create` from the global setting
(the controller's `evaluateHostEntries` does not depend on which forms are shown). Appearance (colors, fonts, radius) comes from the global `Appearance` for every component in v1.
`Appearance.expressPosition` and `paymentSheetTitle` are sheet layout settings and do not apply to elements;
`expressPosition == .off` does hide the Apple Pay button in the Express element (consistent with the sheet).

## Internal design

- `Core/Session`: no new Core types are required beyond Block 1; the group object is UIKit-gated UI code that
  owns a `CheckoutSessionDriver`, a `SavedCardSelection` and the lock/state machine (states: ready, confirming,
  finished(outcome), expired).
- **Extract `NewCardEntryView`** (internal) from `CheckoutContentViewController` (ruling: every existing
  `...ForTest` seam of the content view controller stays working through forwarding properties; the sheet's tests are
  not rewritten; the extracted view owns one `setInteractionEnabled(_:)` switch and exposes its validated user action): the card form, scheme resolver,
  rules refresh, "save this card" checkbox and billing/shipping address views together with their validation and the
  production of the validated `.confirmNewCard` user action. Both the sheet (unchanged behavior, all `...ForTest`
  seams kept) and `CardElement` use it. This is a refactor with the existing 87+ tests as the safety net.
- `CardElement.view` composes: saved-card rows (existing `SavedCardRow` look, radio-style, expired dimmed) +
  a "new card" row that expands `NewCardEntryView` inline. With no saved cards the form is shown directly. It is
  self-sizing (`intrinsicContentSize`) and calls `cardElementDidUpdateHeight` on change.
- `ExpressCheckoutElement.view` composes the existing PassKit Apple Pay button view (reuse of `ExpressCheckoutView`
  logic and `ApplePayAvailability` three-factor check). The `ApplePayButton` class is deleted; the code that
  loaded a session per button is replaced by the shared group.
- Keyboard: the element scrolls the focused field into view inside the nearest ancestor `UIScrollView`
  (as the sheet does) but the merchant owns keyboard insets; documented in the integration notes.
- Card scanner needs a presenting view controller: taken from the responder chain of the element's view; with none in the chain the scan button is hidden.

## Security

- Nothing sensitive crosses the public API: values stay in internal views; `PaymentOptionDisplayData` is label,
  brand image and type only; `confirm()` has no amount parameter; no ciphertext, token or secret leaves.
- Card fields are real views in the merchant's hierarchy, so merchant code in the same process could traverse and
  read them. We expose no reading API and keep the existing field hardening (`CardFieldSecurity`: no autocorrect,
  CVV secure entry, no autofill for CVV); we cannot prevent hostile code in the host process. This is the same
  class of risk as any inline card field and is part of the host app's PCI scope. **Release gate:** record it in
  `docs/security-and-pci.md` and get QSA/acquirer confirmation; the fallback for strict merchants is `PaymentSheet`.
- The form is cleared on success, `close()`, deinit, session expiry and `clear()`. Swift `String` cannot be zeroed:
  the claim is "released and cleared", not "erased", same as `PaymentSheet`.
- No waiting window: there is no hidden form (the earlier "continue" design is dropped).

## Testing

- Headless (macOS host): extend the Block 1 driver tests as needed; state-machine tests for the group object using
  `ScriptablePaymentService`/`ScriptableCofService` (lock, unsettled stays locked, success ends the session, expiry,
  `NO_PAYMENT_OPTION_SELECTED`, availability by filter).
- iOS simulator: `NewCardEntryView` extraction keeps all existing content tests green; `CardElement` (saved/new
  selection, inline validation errors, height callback, disabled while confirming); `ExpressCheckoutElement`
  availability and tap routing with a stub `WalletAuthorizing`; migrated `ApplePayButton` tests.
- A compile-time/reflection check that no public type exposes `CardInput`, `UserAction` or card values.
- Demo app: replace the ApplePayButton section with an "Elements" screen (express + card + host Pay button).
- Docs: `product-spec.md`, `capabilities-report.md`, `security-and-pci.md`, `Example/README.md`, the integration
  notes; remove `ApplePayButton` mentions.

## Left to the builder

Exact names; row visuals within the existing theme; the internal shape of `NewCardEntryView`; where the
`CheckoutElements` factory wiring shares code with `PaymentSheet` (a single internal factory on `SunbayCheckout`);
copy and string keys; the new error codes.

## Branching

Block 1 is implemented but uncommitted. The plan assumes Block 1 (and the specs/plans) are committed on
`feature/embedded-foundation` first, and Block 2 is developed on a new branch cut from it.
