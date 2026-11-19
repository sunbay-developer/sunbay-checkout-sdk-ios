# Sunbay Checkout iOS SDK — API Reference

Complete reference for the `SunbayCheckout` Swift package. For a narrative walkthrough and
examples, see [`guide.md`](./guide.md).

> **Maintenance contract.** This file and `guide.md` describe the public API. Any change to a public
> symbol, its defaults, its behavior or its error codes must update these documents in the same
> change (see `AGENTS.md`, "API documentation contract").

Requirements: iOS 15+, Swift 5.9+, Swift Package Manager. `import SunbayCheckout`.

---

## Table of contents

- [Public surface at a glance](#public-surface-at-a-glance)
- [`SunbayCheckout`](#sunbaycheckout)
- [`CheckoutConfiguration`](#checkoutconfiguration)
- [`PaymentSheet`](#paymentsheet)
- [`CheckoutElements`](#checkoutelements)
- [`ExpressCheckoutElement`](#expresscheckoutelement)
- [`CardElement`](#cardelement)
- [`Appearance`](#appearance)
- [`CardOnFileOptions`](#cardonfileoptions)
- [`PaymentMethodFilter`](#paymentmethodfilter)
- [`AddressInput`](#addressinput)
- [Results: `CheckoutOutcome`, `PaymentSnapshot`](#results)
- [Errors: `CheckoutError`](#errors-checkouterror)
- [Diagnostics: `CheckoutDiagnostic`](#diagnostics-checkoutdiagnostic)
- [Service protocols (injection)](#service-protocols-injection)
- [Utilities](#utilities)
- [Error codes](#error-codes)
- [Environments](#environments)
- [Localization](#localization)

---

## Public surface at a glance

| Layer | Symbols |
| --- | --- |
| Entry point | `SunbayCheckout`, `CheckoutConfiguration`, `sunbayCheckoutVersion` |
| L1 sheet | `PaymentSheet`, `CheckoutPresentationState` |
| L2 elements | `CheckoutElements`, `ExpressCheckoutElement`, `CardElement`, `CardElementDelegate`, `PaymentOptionDisplayData` |
| Configuration | `Appearance`, `CardOnFileOptions`, `PaymentMethodFilter`, `PaymentMethodID`, `ApplePayButtonType` |
| Input data | `AddressInput` |
| Results and errors | `CheckoutOutcome`, `PaymentSnapshot`, `TxnStatus`, `CheckoutError`, `CheckoutDiagnostic`, `CheckoutWarning` |
| Service injection (advanced) | `PaymentService`, `CofService`, `AddressMetadataService` and their models (`CheckoutSession`, `SavedCard`, `Amount`, `SubmitRequest`, `PaymentMethodKind`, `Address*` types) |
| Utilities | `UIColor(sunbayHex:)` |

UIKit-bound types (`Appearance`, `PaymentSheet`, the Elements, `UIColor(sunbayHex:)`) exist only where
`canImport(UIKit)` is true. `CheckoutConfiguration.appearance` is likewise absent off-UIKit.

---

## `SunbayCheckout`

```swift
public final class SunbayCheckout {
    public let configuration: CheckoutConfiguration
    public var onDiagnostic: ((CheckoutDiagnostic) -> Void)?

    public convenience init(configuration: CheckoutConfiguration)

    public convenience init(
        configuration: CheckoutConfiguration,
        paymentService: any PaymentService,
        cofService: any CofService,
        addressMetadataService: (any AddressMetadataService)? = nil
    )
}
```

The SDK entry point. Create one instance and pass it to `PaymentSheet` or `CheckoutElements.create`.

| Member | Description |
| --- | --- |
| `init(configuration:)` | Talks to the real Sunbay backend for `configuration.environment`. This is what merchants use. |
| `init(configuration:paymentService:cofService:addressMetadataService:)` | Injects custom service implementations (mocks, custom adapters). Not needed for a normal integration. See [Service protocols](#service-protocols-injection). |
| `configuration` | The configuration the instance was created with. |
| `onDiagnostic` | Receives non-fatal diagnostics on the main thread. Events raised before a handler is set are buffered (last 50) and replayed in order when it is assigned. See [Diagnostics](#diagnostics-checkoutdiagnostic). |

---

## `CheckoutConfiguration`

```swift
public struct CheckoutConfiguration: Sendable, Equatable {
    public enum Environment: Sendable, Equatable { case dev, test, production }

    public let environment: Environment
    public let applePayMerchantId: String?
    public let appearance: Appearance?          // UIKit only
    public let locale: String?
    public let paymentSheetTitle: String?
    public let cardOnFile: CardOnFileOptions
    public let paymentMethodFilter: PaymentMethodFilter

    public init(
        environment: Environment = .production,
        applePayMerchantId: String? = nil,
        appearance: Appearance? = nil,
        locale: String? = nil,
        paymentSheetTitle: String? = nil,
        cardOnFile: CardOnFileOptions = CardOnFileOptions(),
        paymentMethodFilter: PaymentMethodFilter = PaymentMethodFilter()
    )
}
```

| Field | Default | Description |
| --- | --- | --- |
| `environment` | `.production` | Backend the SDK talks to. Pass `.dev` / `.test` only for non-production work. See [Environments](#environments). |
| `applePayMerchantId` | `nil` | Your Apple Pay merchant id (`merchant.com...`). It must match the id in your app's Apple Pay entitlement. When `nil`, the id delivered with the session is used. Without any merchant id, the Apple Pay option is hidden. |
| `appearance` | `nil` (= `Appearance.default`) | UI theme. See [`Appearance`](#appearance). |
| `locale` | `nil` | BCP-47 code such as `"en"` or `"zh-CN"`. `nil` follows the system language. See [Localization](#localization). |
| `paymentSheetTitle` | `nil` | Replaces the title on the sheet's home page only. `nil` uses the localized default. Other pages keep their own titles. |
| `cardOnFile` | `CardOnFileOptions()` | Saved-card switches. See [`CardOnFileOptions`](#cardonfileoptions). |
| `paymentMethodFilter` | no filtering | Hides and reorders payment methods. See [`PaymentMethodFilter`](#paymentmethodfilter). |

---

## `PaymentSheet`

The black-box payment page: a bottom sheet with the saved-card list, a new-card form and an Apple Pay
row. Available on UIKit platforms only.

```swift
public final class PaymentSheet {
    public var onStateChange: ((CheckoutPresentationState) -> Void)?

    public convenience init(
        checkout: SunbayCheckout,
        sessionId: String,
        customerAccessSecret: String? = nil,
        checkoutClientSecret: String? = nil,
        billingAddress: AddressInput? = nil,
        shippingAddress: AddressInput? = nil
    )

    @MainActor public func present(from presenter: UIViewController) async -> CheckoutOutcome
    public func retrievePayment() async throws -> PaymentSnapshot
}
```

### `init`

| Parameter | Description |
| --- | --- |
| `checkout` | The SDK entry point. |
| `sessionId` | The checkout session id, created by your backend. |
| `customerAccessSecret` | Saved-card (COF) credential, issued by your backend. Held in memory only and never logged. Without it there are no saved cards and no "save card" checkbox. |
| `checkoutClientSecret` | Client secret issued by your backend together with the session. Held in memory only and never logged. **Required by the default backend adapter:** without it the session load fails with `CHECKOUT_CLIENT_SECRET_MISSING`. |
| `billingAddress` / `shippingAddress` | An address your app already knows. It is sent as is, wins over what the user types, and is never validated. See [`AddressInput`](#addressinput). |

### `present(from:)`

Presents the sheet modally on `presenter` and suspends until the presentation ends. Returns the result
of one presentation as a [`CheckoutOutcome`](#results).

- The session loads once per presentation. If loading fails, the sheet is not shown and `present`
  returns `.failed` with the load error.
- After `.failed` the sheet stays open and the user can retry on the same session (no reload).
- After `.pending` / `.unknown` the sheet locks (only the close button works) and shows a neutral
  "we are confirming this payment" notice. The SDK does not poll. Closing returns that same outcome
  so the host knows to reconcile.
- The user closing or pulling the sheet down before any unsettled attempt returns `.canceled`.
- A success closes the sheet automatically and returns `.succeeded`.

Presentation style: a custom bottom sheet on iPhone (all supported iOS versions); a system form sheet
on iPad, Mac (Catalyst) and visionOS. `Appearance.sheetSizing` applies to the iPhone sheet only.

### `onStateChange`

Observes the coarse in-sheet phase on the main actor. Informational only, for analytics.

| `CheckoutPresentationState` | Meaning |
| --- | --- |
| `.editing` | Choosing a method or filling the form. Also reported while the sheet is locked on an unresolved payment, even though inputs are locked. |
| `.processing` | A confirm is in flight. |
| `.succeeded` | Payment succeeded; the sheet is closing. |
| `.failed` | Payment failed; the sheet stays open for retry. |

### `retrievePayment()`

Looks up the latest payment result for the session without any UI. Use it after `.pending` /
`.unknown`, or to recover after the app was killed. Throws on a lookup failure.

---

## `CheckoutElements`

The embeddable alternative to the sheet. `@MainActor`: create and use it from the main actor. `CheckoutElements` loads the session once and creates
components you place in your own screen. All components of one group share one payment lock, one
expiry timer and one outcome history. Your app owns any Pay button.

```swift
@MainActor public final class CheckoutElements {
    public struct Configuration {
        public var customerAccessSecret: String?
        public var checkoutClientSecret: String?
        public var billingAddress: AddressInput?
        public var shippingAddress: AddressInput?
        public init()
    }

    public static func create(
        checkout: SunbayCheckout,
        sessionId: String,
        configuration: Configuration = Configuration()
    ) async throws -> CheckoutElements

    public func makeExpressCheckoutElement(
        _ configuration: ExpressCheckoutElement.Configuration = .init()
    ) -> ExpressCheckoutElement

    public func makeCardElement(
        _ configuration: CardElement.Configuration = .init()
    ) -> CardElement

    public var paymentOption: PaymentOptionDisplayData? { get }

    public func confirm() async -> CheckoutOutcome
    public func retrievePayment() async throws -> PaymentSnapshot
    public func updateAddresses(billing: AddressInput?, shipping: AddressInput?)
    public func close()
}
```

`Configuration` has the same per-session inputs as the `PaymentSheet` initializer.

| Member | Description |
| --- | --- |
| `create(checkout:sessionId:configuration:)` | Loads the session. Throws a `CheckoutError` only when the session cannot be loaded or is expired (`SESSION_LOAD_FAILED`, `CHECKOUT_EXPIRED`, `SESSION_COMPLETED`, `SESSION_CLOSED`, or an error from the backend). "No method available" or "Apple Pay unavailable" never throw: the components report `isAvailable == false` and render zero-height views. |
| `makeExpressCheckoutElement(_:)` | Creates a quick-wallet component (Apple Pay). May be called more than once. |
| `makeCardElement(_:)` | Creates the card component. A group has exactly one: a second call returns the same instance and ignores the new configuration. |
| `paymentOption` | Display data for the currently selected card option, or `nil` when nothing payable is selected or the typed card is incomplete. See [`PaymentOptionDisplayData`](#paymentoptiondisplaydata). |
| `confirm()` | Pays whatever the card element has selected. The amount always comes from the server session. See below. |
| `retrievePayment()` | Same as `PaymentSheet.retrievePayment()`. |
| `updateAddresses(billing:shipping:)` | Replaces the host addresses used by later payments. |
| `close()` | Ends the session: disables the components and clears the in-memory credential. Deinit does the same. |

`confirm()` results:

| Situation | Result |
| --- | --- |
| No card component, or nothing selected | `.failed` with `NO_PAYMENT_OPTION_SELECTED` |
| New-card form or a shown address form invalid | `.failed` with `CARD_INPUT_INVALID` (nothing submitted, inline errors shown) |
| Payment attempted | `.succeeded` / `.failed` / `.pending` / `.unknown` |
| Session ended or a payment already settled | The stored outcome is returned again |

Keep the `CheckoutElements` instance alive while its components are on screen. If only a component is
retained and the group is released, the group's deinit closes the session and the component stops
being able to pay.

### `PaymentOptionDisplayData`

```swift
public struct PaymentOptionDisplayData: @unchecked Sendable {
    public let label: String               // "Visa ····4242" (saved card) or the brand name (typed card)
    public let image: UIImage?             // brand logo; may be nil until it has loaded
    public let paymentMethodType: String   // e.g. "CARD"
}
```

Display only. It never carries card numbers, tokens or secrets. The host is not notified when `image`
arrives; read `paymentOption` again (for example from `cardElementDidChangeSelection`).

---

## `ExpressCheckoutElement`

`@MainActor`. The quick-wallet component (today only Apple Pay). A tap presents the Apple Pay sheet
and pays immediately.

```swift
@MainActor public final class ExpressCheckoutElement {
    public enum ExpressMethod: Sendable, Hashable { case applePay }

    public struct Configuration {
        public var methods: Set<ExpressMethod>?                       // nil = every available wallet
        public var buttonType: ApplePayButtonType?                    // nil = Appearance.applePayButtonType
        public var buttonStyle: Appearance.ApplePayButtonStyle?       // nil = Appearance.applePayButtonStyle
        public init()
    }

    public var view: UIView { get }
    public private(set) var isAvailable: Bool
    public var onAvailabilityChange: ((Bool) -> Void)?
    public var onResult: ((CheckoutOutcome) -> Void)?
}
```

| Member | Description |
| --- | --- |
| `view` | Self-sizing view to add to your layout. Zero height while unavailable. |
| `isAvailable` | `true` when the device can pay with Apple Pay, a merchant id is configured, the session offers Apple Pay, the `PaymentMethodFilter` does not hide it, `Appearance.expressPosition` is not `.off`, and `Configuration.methods` allows it. Known as soon as the element exists. |
| `onAvailabilityChange` | Called once, asynchronously, with the initial availability. A handler assigned after an `await` following creation can miss it; `isAvailable` is authoritative, so read it directly. |
| `onResult` | Called on the main actor with the final `CheckoutOutcome` after a tap. The user dismissing the Apple Pay sheet gives `.canceled`; an authorization failure gives `.failed` (`WALLET_AUTH_FAILED`). The wallet token never appears here. |

---

## `CardElement`

The bank-card component: the saved-card list (when card-on-file is effective), a "New card" row, and
the inline new-card form (card fields, optional "save this card" checkbox, billing and shipping address
forms). Your app places `view` in its layout and owns the Pay button; it calls
`CheckoutElements.confirm()` to pay.

```swift
@MainActor public final class CardElement {
    public struct Configuration {
        public var showsSavedCards: Bool?        // nil = follow card-on-file being effective
        public var billingAddress: AddressMode?  // nil = follow the session and the global switch
        public var shippingAddress: AddressMode?
        public var showsSaveCardOption: Bool?    // nil = follow card-on-file being effective
        public init()
    }

    public enum AddressMode: Sendable { case automatic, off }

    public var view: UIView { get }
    public private(set) var isAvailable: Bool
    public var isComplete: Bool { get }
    public weak var delegate: CardElementDelegate?
    public func clear()
}

@MainActor public protocol CardElementDelegate: AnyObject {
    func cardElementDidUpdateHeight(_ element: CardElement)
    func cardElementDidChangeSelection(_ element: CardElement)      // optional, default no-op
    func cardElementDidChangeCompleteness(_ element: CardElement)   // optional, default no-op
}
```

| Member | Description |
| --- | --- |
| `view` | Self-sizing view. Zero height while unavailable. Read `view.intrinsicContentSize` once after adding it (or let Auto Layout do it); `cardElementDidUpdateHeight` fires only for later changes. |
| `isAvailable` | `true` when the session offers `CARD` and the `PaymentMethodFilter` does not hide it. |
| `isComplete` | `true` when a saved card is selected or the typed card is valid. It does not cover address forms: `confirm()` validates those and returns `CARD_INPUT_INVALID` if incomplete. Use it to enable your Pay button. |
| `delegate` | Receives height, selection and completeness changes. Held weakly. |
| `clear()` | Clears the typed card values, the save-card choice and every visible address field. |

Composition: with saved cards, the first usable one is selected and the form stays collapsed behind
the "New card" row; expired cards are dimmed and cannot be selected. Without saved cards the form is
shown directly.

Address precedence: the backend session decides whether an address is collected. The global switches
(`Appearance.billingAddressEnabled` / `shippingAddressEnabled`) and `Configuration.billingAddress` /
`shippingAddress` can only turn a form off, never on. An address passed through
`CheckoutElements.Configuration` suppresses the form as it does in `PaymentSheet`.

Result and lock: the element shows no failure, pending or unknown notices and no spinner, only inline
field validation errors. While a payment is in flight all inputs are disabled. After `.failed` the form
and selection stay so a retry works. On every terminal state (`.succeeded`, `.pending`, `.unknown`,
`close()`, an ended session) the typed values are cleared and the element stays disabled.

---

## `Appearance`

A nested value type. Create it with `Appearance()` (or `Appearance.default`), then set only what you
want to change. Every color is an optional `UIColor`; `nil` uses the built-in dynamic default.

```swift
var appearance = Appearance()
appearance.colors.primary = UIColor(sunbayHex: "#ff6000")
appearance.cornerRadius = 12
```

| Property | Type | Default | Description |
| --- | --- | --- | --- |
| `colors` | `Colors` | all `nil` | See below. |
| `font` | `Font` | system | `base: UIFont?` (nil = system font), `sizeScaleFactor: CGFloat = 1.0`. |
| `primaryButton` | `PrimaryButton` | inherit | `backgroundColor: UIColor?` (nil = `colors.primary`), `textColor: UIColor?` (nil = white), `cornerRadius: CGFloat?` (nil = `cornerRadius`). |
| `cornerRadius` | `CGFloat` | `10` | Corner radius of grouped components, in points. |
| `borderWidth` | `CGFloat` | `1` | Border width of grouped components. `0` gives a borderless look. |
| `shadow` | `Shadow` | `.none` | `Shadow(color:opacity:offset:radius:)`, plus `.none`, `.soft`, `.medium`. |
| `colorScheme` | `ColorScheme` | `.automatic` | `.light`, `.dark` or `.automatic`. Drives `overrideUserInterfaceStyle`. |
| `density` | `Density` | `.comfortable` | `.comfortable` or `.compact`. |
| `expressPosition` | `ExpressPosition` | `.top` | Apple Pay row on the sheet's home page: `.top`, `.bottom` or `.off`. `.off` also makes `ExpressCheckoutElement` unavailable. The row never appears on the new-card subpage. |
| `applePayButtonType` | `ApplePayButtonType` | `.plain` | Apple Pay button wording. See below. |
| `applePayButtonStyle` | `ApplePayButtonStyle` | `.automatic` | `.automatic` (black on light, white on dark), `.black`, `.white`. |
| `billingAddressEnabled` | `Bool` | `true` | Whether the billing form may be shown. Whether it is shown still follows the session's `collectBillingAddress`; `false` never shows it (a host-passed billing address is still sent). The host cannot force the form on. |
| `shippingAddressEnabled` | `Bool` | `true` | Same rules, following `collectShippingAddress`. |
| `billingAddressStyle` | `AddressFormStyle` | `.simple` | `.simple` (country, line 1, postal code) or `.full` (backend-layout driven). |
| `shippingAddressStyle` | `AddressFormStyle` | `.simple` | `.simple` adds first and last name. `.full` is backend-layout driven. |
| `cardScanning` | `CardScanning` | `.automatic` | `.automatic` shows "Scan card" only when the app declares `NSCameraUsageDescription`, a camera exists and access is not denied or restricted. `.disabled` never shows it. Scanning is on-device only. |
| `sheetSizing` | `SheetSizing` | adaptive | See below. |
| `pageTransitionsEnabled` | `Bool` | `true` | Slide animation between pages in the sheet. "Reduce Motion" always downgrades it to a cross-fade. |

`Colors` fields (all `UIColor?`, `nil` = built-in default): `primary`, `background`,
`componentBackground`, `text`, `textSecondary`, `border`, `danger`, `success`.

`ApplePayButtonType` cases: `.plain` (logo only), `.buy`, `.setUp`, `.inStore`, `.donate`, `.checkout`,
`.book`, `.subscribe`, `.reload`, `.addMoney`, `.topUp`, `.order`, `.rent`, `.support`, `.contribute`,
`.tip`. PassKit renders and localizes the text.

`SheetSizing(minHeight: CGFloat? = nil, maxHeightFraction: CGFloat = 0.9, mode: Mode = .adaptive)`:

| `Mode` | Behavior |
| --- | --- |
| `.adaptive` | Fits the content, clamped to `[minHeight, screenHeight × maxHeightFraction]`. |
| `.fixedFraction(f)` | `screenHeight × f` (`f` clamped to `0...1`, then by `minHeight` and `maxHeightFraction`). |
| `.large` | Fills the available height (screen minus top safe area minus keyboard). Ignores `maxHeightFraction`. |

`maxHeightFraction` is a hard cap: there is no pull-up gesture. Out-of-range inputs are sanitized
(fractions clamped to `0...1`, a NaN or negative `minHeight` ignored; if `minHeight` exceeds the cap it
wins but never exceeds the available height). The height is re-evaluated when content changes, on
rotation and when the keyboard shows or hides.

---

## `CardOnFileOptions`

```swift
public struct CardOnFileOptions: Sendable, Equatable {
    public var isEnabled: Bool        // default true
    public var saveByDefault: Bool    // default false
    public init(isEnabled: Bool = true, saveByDefault: Bool = false)
}
```

Card-on-file (saved cards) is effective only when all of these hold:

1. The session allows it (`supportStoreCard`; absent means allowed).
2. `isEnabled` is `true`.
3. The host passed a `customerAccessSecret`.

The session switch always wins: the host can turn COF off but never on. When COF is not effective, the
SDK shows no saved cards and no "save card" checkbox, makes no saved-card list request and never sends
`storeCard`. `saveByDefault` only pre-ticks the checkbox; the card is saved only if the checkbox is
still on at submit.

---

## `PaymentMethodFilter`

```swift
public struct PaymentMethodFilter: Sendable, Equatable {
    public var hide: [PaymentMethodID]
    public var order: [PaymentMethodID]
    public init(hide: [PaymentMethodID] = [], order: [PaymentMethodID] = [])
}

public struct PaymentMethodID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public static let card: PaymentMethodID        // "CARD": every card entry (new and saved)
    public static let applePay: PaymentMethodID    // "APPLE_PAY"
}
```

- Identifiers are case-sensitive. A logical key (`CARD`, `APPLE_PAY`) is matched first; otherwise the
  identifier is matched against the raw backend method (for example `"AMEX"`).
- `hide` wins over `order`.
- `order` is stable: unlisted items keep their relative order after the listed ones. It never moves a
  group (the express group position comes from `Appearance.expressPosition`).
- An identifier that matches nothing is ignored and reported as a `PAYMENT_METHOD_FILTER_IGNORED`
  diagnostic. The filter never fails a payment.

---

## `AddressInput`

An address your app already knows. All fields are optional and default to `nil`.

```swift
public struct AddressInput: Sendable, Equatable {
    public var country: String?       // ISO country code
    public var line1: String?
    public var line2: String?
    public var city: String?
    public var state: String?         // subdivision code
    public var postalCode: String?
    public var district: String?
    public var firstName: String?
    public var lastName: String?
    public var phone: String?
    public var email: String?
    public init(country: String? = nil, line1: String? = nil, /* ... same order as the properties */)
}
```

Rules:

- An address is used only when the session collects that kind (`collectBillingAddress` /
  `collectShippingAddress`) and the entry is complete. Otherwise it is not sent and an
  `ADDRESS_INCOMPLETE` diagnostic is reported.
- A host address wins over what the user types in the SDK form on the card path (and the form is not
  shown when a usable host address exists). The host address is never validated by the SDK.
- On the Apple Pay path, a contact returned by the wallet wins over the host address.
- A new-card submit is blocked only by an invalid postal code in the SDK's own address form.

---

## Results

### `CheckoutOutcome`

```swift
public enum CheckoutOutcome: Sendable, Equatable {
    case succeeded(txnId: String)
    case failed(txnId: String?, error: CheckoutError)
    case canceled
    case pending(txnId: String?)
    case unknown(sessionId: String)
}
```

| Case | Meaning | What the host should do |
| --- | --- | --- |
| `.succeeded` | The server confirmed success. | Show success; still treat the webhook as the source of truth for fulfillment. |
| `.failed` | The payment failed or could not start. `error` explains why. | Show the error; the user can usually retry. |
| `.canceled` | The user cancelled. | Return to your own screen. |
| `.pending` | The payment is processing (non-terminal). | Reconcile with `retrievePayment()` or your webhook. |
| `.unknown` | The result could not be confirmed (for example a lost response). | Reconcile with `retrievePayment()` or your webhook using `sessionId`. |

The SDK never reports an undetermined result as `.failed`, never client-polls the backend, and never
blindly resubmits. Payment truth is the server-confirmed terminal state.

### `PaymentSnapshot`

```swift
public struct PaymentSnapshot: Sendable, Equatable {
    public let sessionId: String
    public let status: TxnStatus
    public let txnId: String?
    public let failureReason: String?
    public let sessionStatus: String?   // ACTIVE / COMPLETED / INACTIVE / EXPIRED; nil on older backends
}

public enum TxnStatus: String, Sendable {
    case initial = "I"          // initial / processing
    case succeeded = "S"        // terminal
    case failed = "F"           // terminal
    case requiresAction = "R"   // further action required
}
```

`status` describes the latest transaction only; one session can hold several attempts.

---

## Errors: `CheckoutError`

```swift
public struct CheckoutError: Error, Sendable, Equatable {
    public enum Category: Sendable, Equatable { case configuration, validation, network, runtime, payment }
    public let code: String
    public let message: String      // developer-facing
    public let category: Category
    public let traceId: String?     // backend trace id; nil when unavailable
}
```

Branch on `code`, not on `message`. Errors never contain card values, wallet tokens, secrets or
ciphertext. Send `traceId` to Sunbay support when reporting a backend problem.

---

## Diagnostics: `CheckoutDiagnostic`

```swift
public enum CheckoutDiagnostic: Sendable, Equatable {
    case warning(CheckoutWarning)
    case error(CheckoutError, sessionId: String?)   // a non-terminal error the SDK recovered from
}

public struct CheckoutWarning: Sendable, Equatable {
    public struct Code: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral { /* ... */ }
    public let code: Code
    public let ignored: [String]    // names of ignored inputs, never values
    public let reason: String
    public let sessionId: String?
}
```

Set `SunbayCheckout.onDiagnostic` to receive these. Warnings never contain card values, tokens,
secrets or address contents.

| Warning code | Raised when |
| --- | --- |
| `PAYMENT_METHOD_FILTER_IGNORED` | A `PaymentMethodFilter` identifier matched nothing usable. |
| `ADDRESS_INCOMPLETE` | A host address the session collects was incomplete and was not used. |
| `ADDRESS_ENTRY_IGNORED` | A host address was overridden by a form draft or a wallet contact. |
| `WALLET_PARAMS_INVALID` | Wallet parameters were invalid and were ignored. |

Diagnostic errors include `SAVED_CARDS_FAILED`, `SAVED_CARD_DELETE_FAILED` and `ADDRESS_METADATA_FAILED`.
Saved-card listing failures never block a payment: the SDK shows no saved cards instead.

---

## Service protocols (injection)

Advanced. A normal integration uses `SunbayCheckout(configuration:)` and never touches these. They
exist so tests, demos and custom backends can replace the real adapters.

```swift
public protocol PaymentService: Sendable {
    func loadSession(_ id: String) async throws -> CheckoutSession
    func submit(_ req: SubmitRequest) async throws -> PaymentSnapshot
    func getResult(sessionId: String) async throws -> PaymentSnapshot
    /// Queries the session state plus the state of the attempt submitted with `attemptId`.
    /// Default implementation forwards to `getResult(sessionId:)`.
    func getResult(sessionId: String, attemptId: UUID) async throws -> PaymentSnapshot
}

public protocol CofService: Sendable {
    func listPaymentMethods(customerAccessSecret: String, sessionId: String) async throws -> [SavedCard]
    func deleteCard(savedCardId: String, customerAccessSecret: String, sessionId: String) async throws
    // deleteCard has a default implementation that throws CARD_DELETE_UNSUPPORTED
}

public protocol AddressMetadataService: Sendable {
    func countries(locale: String?) async throws -> AddressCountryList
    func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig
}
```

Supporting public types: `CheckoutSession` (id, `Amount`, merchant name, `Set<PaymentMethodKind>`,
expiry, RSA public key, COF flag, session type, collect-address flags), `Amount` (`minorUnits`,
`currencyCode`), `PaymentMethodKind` (`.card`, `.applePay`, `.savedCard`), `SavedCard` (id, brand,
last4, expiry, logo URL), `SubmitRequest` (redacts secrets in `description`), and the address metadata
models `AddressCountry`, `AddressSubdivision`, `AddressFieldType`, `AddressFieldConfig`,
`AddressCountryConfig`, `AddressCountryList`. See the source doc comments for field-level detail.

---

## Utilities

| Symbol | Description |
| --- | --- |
| `sunbayCheckoutVersion` | `public let` string with the SDK's semantic version. |
| `UIColor(sunbayHex:)` | Failable convenience init. Accepts `#RGB`, `#RRGGBB`, `#RRGGBBAA`; the `#` is optional and case is ignored. Returns `nil` for any other input. |

---

## Error codes

Stable string codes in `CheckoutError.code`. Categories are the `CheckoutError.Category` value.

| Code | Category | Meaning |
| --- | --- | --- |
| `CHECKOUT_CLIENT_SECRET_MISSING` | configuration | The default adapter needs `checkoutClientSecret` to load the session and none was supplied. |
| `NO_PAYMENT_METHOD_AVAILABLE` | configuration | After filtering, no payment method is available for the sheet. |
| `WALLET_PARAMS_INVALID` | configuration | Apple Pay parameters are invalid (also reported as a warning). |
| `SESSION_LOAD_FAILED` | network | The session could not be loaded. |
| `NETWORK_UNAVAILABLE` | network | The network was unavailable, or a submit or query failed. |
| `INVALID_RESPONSE` | network | The server response could not be processed. |
| `SAVED_CARDS_FAILED` | network | Listing saved cards failed (diagnostic only). |
| `SAVED_CARD_DELETE_FAILED` | network | Deleting a saved card failed (diagnostic only). |
| `ADDRESS_METADATA_FAILED` | network | Loading address metadata failed (diagnostic only). |
| `CHECKOUT_EXPIRED` | validation | The session expired. |
| `SESSION_COMPLETED` | validation | The session is already completed. |
| `SESSION_CLOSED` | validation | The session is closed. |
| `CARD_ON_FILE_UNAVAILABLE` | validation | A saved-card action was requested while card-on-file is not effective. |
| `NO_PAYMENT_OPTION_SELECTED` | validation | `CheckoutElements.confirm()` found nothing selected. |
| `CARD_INPUT_INVALID` | validation | `CheckoutElements.confirm()` found invalid card or address input. Nothing was submitted. |
| `PAYMENT_FAILED` | payment | The payment ended in the failed state. `message` carries the server reason when given. |
| `ALREADY_PRESENTING` | runtime | A payment is already in progress on this controller. |
| `CARD_ENCRYPTION_FAILED` | runtime | Local card encryption failed (missing public key or an encryption error). |
| `CARD_DELETE_UNSUPPORTED` | runtime | The injected `CofService` does not support deleting cards. |
| `UNSUPPORTED_CAPABILITY` | runtime | The backend asked for a further action the SDK cannot handle. |
| `WALLET_AUTH_FAILED` | runtime | Apple Pay authorization failed. |
| `WALLET_CONFIRM_REJECTED` | runtime | The backend rejected the Apple Pay payment after authorization. |
| `WALLET_PRESENT_FAILED` | runtime | The Apple Pay sheet could not be presented. |
| `WALLET_CANCELED` | runtime | The user dismissed the Apple Pay sheet (surfaced as `.canceled`). |
| `WALLET_UNSUPPORTED_PLATFORM` | runtime | Apple Pay is not supported on this platform. |

Backend errors can also surface with their own code and `traceId`.

---

## Environments

| `Environment` | Backend host |
| --- | --- |
| `.production` (default) | `https://checkout.sunbay.us` |
| `.test` | `https://checkout.sunbay-uat.us` |
| `.dev` | `https://checkout.sunbay-dev.com` |

---

## Localization

The SDK ships `en` and `zh-Hans` strings. `CheckoutConfiguration.locale` accepts a BCP-47 code
(`"en"`, `"zh"`, `"zh-CN"`, `"zh-Hans"`). `nil` follows the system's preferred languages and falls back
to `en`. The locale also drives amount formatting on the Pay button and is sent to the backend as the
`Accept-Language` header.
