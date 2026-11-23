# Sunbay Checkout iOS SDK — Integration Guide

`SunbayCheckout` is the native iOS SDK for taking card and Apple Pay payments inside your own app.
It renders native payment UI, encrypts card data on the device with an RSA public key and sends it
straight to the Sunbay backend. Card data never reaches your app code, logs or callbacks.

For the type-by-type reference see [`api.md`](./api.md).

---

## Table of contents

1. [Overview](#1-overview)
2. [Installation](#2-installation)
3. [Quick start](#3-quick-start)
4. [Core concepts](#4-core-concepts)
5. [Features](#5-features)
6. [Examples](#6-examples)
7. [Theming](#7-theming)
8. [Diagnostics](#8-diagnostics)
9. [Error handling](#9-error-handling)
10. [Security and PCI model](#10-security-and-pci-model)
11. [Testing and verification](#11-testing-and-verification)

---

## 1. Overview

There are two ways to integrate, built on the same payment engine:

| | `PaymentSheet` (L1) | `CheckoutElements` (L2) |
| --- | --- | --- |
| What it is | A ready-made bottom sheet. | Components you place in your own screen. |
| Who owns the Pay button | The SDK. | Your app. |
| Best for | The fastest integration. | A checkout screen with your own layout and branding. |
| Result | `await sheet.present(from:)` returns a `CheckoutOutcome`. | `await elements.confirm()` returns a `CheckoutOutcome`. Express taps report through `onResult`. |

```
SunbayCheckout(configuration:)
   │
   ├─ PaymentSheet(checkout:sessionId:...)  ──▶ present(from:) ──▶ CheckoutOutcome
   │
   └─ CheckoutElements.create(checkout:sessionId:...)
         ├─ makeExpressCheckoutElement()  ──▶ .view, .onResult
         ├─ makeCardElement()             ──▶ .view, .isComplete, .delegate
         └─ confirm()                     ──▶ CheckoutOutcome
```

### What you need from your backend

Your server creates the checkout session (it holds your merchant API key). The app only receives:

- `sessionId`: required.
- `checkoutClientSecret`: issued with the session. The default SDK adapter needs it to load the
  session; without it the load fails with `CHECKOUT_CLIENT_SECRET_MISSING`.
- `customerAccessSecret`: optional. Needed only for saved cards (card-on-file, COF).

Amount, currency, merchant name, available payment methods and address-collection requirements all
come from the session. The app cannot override them.

---

## 2. Installation

### Swift Package Manager

The package is not published to a remote registry or git URL yet. Until it is, add it as a local
package: in Xcode choose **File ▸ Add Package Dependencies… ▸ Add Local…** and select the SDK folder,
or reference it by path (Tuist: `.package(path: "<path to the SDK>")`).

```swift
dependencies: [
    .package(path: "<path to the SDK>"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "SunbayCheckout", package: "SunbayCheckout"),
    ]),
]
```

Once the package is published, releases will be git tags (`MAJOR.MINOR.PATCH`) and you will switch to a
version requirement. A breaking change to the public API bumps MAJOR.
Use the `SunbayCheckout` product only. `SunbayCheckoutTestSupport` is internal scaffolding and must
not ship in an app.

### Requirements

- iOS 15 or later, Swift 5.9 or later.
- A `sessionId` (and normally a `checkoutClientSecret`) from your server.
- For Apple Pay: your own merchant id, see [Apple Pay](#apple-pay).
- For card scanning: `NSCameraUsageDescription` in your Info.plist (otherwise "Scan card" is hidden).

---

## 3. Quick start

### Payment sheet

```swift
import SunbayCheckout

let checkout = SunbayCheckout(
    configuration: CheckoutConfiguration(
        applePayMerchantId: "merchant.com.yourcompany.yourapp"
    )
)

let sheet = PaymentSheet(
    checkout: checkout,
    sessionId: sessionId,                        // from your backend
    customerAccessSecret: customerAccessSecret,  // optional, saved cards
    checkoutClientSecret: checkoutClientSecret   // from your backend
)

let outcome = await sheet.present(from: self)    // self is a UIViewController
switch outcome {
case .succeeded(let txnId):  showSuccess(txnId)
case .failed(_, let error):  showError(error.message)
case .canceled:              break
case .pending, .unknown:     reconcileLater()    // see section 4
}
```

### Embedded elements

```swift
var options = CheckoutElements.Configuration()
options.checkoutClientSecret = checkoutClientSecret
options.customerAccessSecret = customerAccessSecret

let elements = try await CheckoutElements.create(
    checkout: checkout, sessionId: sessionId, configuration: options)

let express = elements.makeExpressCheckoutElement()
express.onResult = { outcome in /* handle */ }

let card = elements.makeCardElement()
card.delegate = self

// Decide what to render before you build the layout (known as soon as `elements` exists):
let methods = elements.paymentMethods
let showExpressLabel = methods.express.contains { $0.isAvailable }

// Add express.view and card.view to your layout. Each is zero-height when unavailable.
// Wire your own Pay button:
let outcome = await elements.confirm()
```

Keep a strong reference to `elements` for as long as its components are on screen. Components hold the
group weakly, and the group keeps them alive.

---

## 4. Core concepts

### Outcomes and reconciliation

Every payment ends in a `CheckoutOutcome`:

- `.succeeded(txnId:)`, `.failed(txnId:error:)` and `.canceled` are final for that attempt.
- `.pending(txnId:)` means the payment is still processing. `.unknown(sessionId:)` means the SDK could
  not confirm the result, for example after a lost response.

The SDK does not poll and never reports an undetermined result as `.failed`. For `.pending` and
`.unknown`, confirm the final state on your server through your webhook, or in the app with
`retrievePayment()`, which returns a `PaymentSnapshot`:

```swift
let snapshot = try await sheet.retrievePayment()   // or elements.retrievePayment()
switch snapshot.status {
case .succeeded:      markPaid(snapshot.txnId)
case .failed:         markFailed(snapshot.failureReason)
case .initial, .requiresAction: scheduleAnotherCheck()
}
```

Treat your webhook as the source of truth for fulfillment.

### Retry

By default the session allows retry after a failure: the sheet stays open and the user can change the
method or try again on the same session. After `.pending` / `.unknown` the sheet locks and only the
close button works, so the user cannot pay twice while the result is unresolved.

### Session lifetime

A session expires on the server. Loading an expired session fails with `CHECKOUT_EXPIRED`;
a completed or closed one fails with `SESSION_COMPLETED` / `SESSION_CLOSED`. Create a new session
from your backend and a new `PaymentSheet` / `CheckoutElements`.

### Threading

`PaymentSheet.present(from:)`, `CheckoutElements`, `ExpressCheckoutElement`, `CardElement` and
`CardElementDelegate` are `@MainActor`. Call them from the main actor, for example from a `Task` started
inside a view controller. `onDiagnostic` always fires on the main thread.

---

## 5. Features

### Apple Pay

Apple Pay needs your own merchant id, registered in your Apple Developer account and added to the
app's Apple Pay capability (`com.apple.developer.in-app-payments`).

```swift
CheckoutConfiguration(applePayMerchantId: "merchant.com.yourcompany.yourapp")
```

If you omit it the SDK uses the merchant id delivered with the session. The id in your entitlement and
the one the SDK uses must match; otherwise the Apple Pay option is hidden. Choose the button wording
with `Appearance.applePayButtonType` (or `ExpressCheckoutElement.Configuration.buttonType`) and its
color with `applePayButtonStyle`.

### Saved cards (card-on-file)

Pass `customerAccessSecret`. Saved cards appear, and a new card can be saved with a checkbox.

```swift
CheckoutConfiguration(cardOnFile: CardOnFileOptions(isEnabled: true, saveByDefault: false))
```

Saved cards require all three: the session allows COF, `isEnabled` is `true` and a
`customerAccessSecret` was passed. The host can turn COF off, never on. Listing failures degrade to
"no saved cards" and never block a payment.

### Address collection

The session decides whether a billing or shipping address is collected. You can only turn a form off,
choose its style, or pass an address you already have:

```swift
var appearance = Appearance()
appearance.shippingAddressEnabled = false     // never show the shipping form
appearance.billingAddressStyle = .full        // backend-layout form instead of the 3-field one

let sheet = PaymentSheet(
    checkout: checkout, sessionId: sessionId, checkoutClientSecret: secret,
    billingAddress: AddressInput(country: "US", line1: "1 Main St", postalCode: "94105"))
```

A usable address passed in suppresses the form and is sent as is. Use
`CheckoutElements.updateAddresses(billing:shipping:)` to change it later.

### Hiding and ordering payment methods

```swift
CheckoutConfiguration(
    paymentMethodFilter: PaymentMethodFilter(hide: [.applePay], order: [.card]))
```

A filter entry that matches nothing is ignored and reported through `onDiagnostic`.

### Sheet title and sizing

```swift
CheckoutConfiguration(paymentSheetTitle: "Pay Sunbay Coffee")

var appearance = Appearance()
appearance.sheetSizing = .init(minHeight: 420, maxHeightFraction: 0.85, mode: .adaptive)
```

### Localization

```swift
CheckoutConfiguration(locale: "zh-CN")   // nil follows the system language
```

English and Simplified Chinese are bundled.

---

## 6. Examples

### Embedded elements with your own Pay button

```swift
final class CheckoutViewController: UIViewController, CardElementDelegate {
    private var elements: CheckoutElements?
    private let payButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await setUpElements() }
    }

    private func setUpElements() async {
        do {
            var options = CheckoutElements.Configuration()
            options.checkoutClientSecret = clientSecret
            let elements = try await CheckoutElements.create(
                checkout: checkout, sessionId: sessionId, configuration: options)
            self.elements = elements

            let express = elements.makeExpressCheckoutElement()
            express.onResult = { [weak self] outcome in self?.handle(outcome) }

            let card = elements.makeCardElement()
            card.delegate = self

            // Stack express.view and card.view in your layout, then your Pay button.
            // No callback fires for the initial value (a default saved card is already complete),
            // so read it once here.
            payButton.isEnabled = card.isComplete
        } catch let error as CheckoutError {
            showError(error)       // the session could not be loaded
        } catch {
            showError(error)
        }
    }

    func cardElementDidUpdateHeight(_ element: CardElement) { view.setNeedsLayout() }
    func cardElementDidChangeCompleteness(_ element: CardElement) {
        payButton.isEnabled = element.isComplete
    }

    @objc private func payTapped() {
        Task {
            guard let elements else { return }
            handle(await elements.confirm())
        }
    }
}
```

### Showing the selected card next to your Pay button

```swift
func cardElementDidChangeSelection(_ element: CardElement) {
    let option = elements?.paymentOption       // "Visa ····4242", brand image
    summaryLabel.text = option?.label
    summaryImageView.image = option?.image     // may be nil until the logo loads
}
```

### Recovering after the app was killed

```swift
// Later, with the same sessionId and a fresh instance:
let elements = try await CheckoutElements.create(checkout: checkout, sessionId: sessionId)
let snapshot = try await elements.retrievePayment()
```

---

## 7. Theming

`Appearance` is a nested value type. Create it, set what you need and put it in the configuration:

```swift
var appearance = Appearance()
appearance.colors.primary = UIColor(sunbayHex: "#ff6000")
appearance.cornerRadius = 10
appearance.density = .compact
appearance.colorScheme = .automatic      // .light / .dark to lock
appearance.expressPosition = .top        // .bottom / .off
appearance.font.base = UIFont(name: "AvenirNext-Regular", size: 16)
appearance.primaryButton.cornerRadius = 22

let checkout = SunbayCheckout(configuration: CheckoutConfiguration(appearance: appearance))
```

Built-in defaults are dynamic colors that follow light and dark mode. `UIColor(sunbayHex:)` returns
`nil` for an invalid string, which then falls back to the default. All options are listed in
[`api.md`](./api.md#appearance).

---

## 8. Diagnostics

Non-fatal advisories (an ignored filter entry, an incomplete host address, a recovered error) never
fail the payment. Subscribe to see them:

```swift
checkout.onDiagnostic = { diagnostic in
    switch diagnostic {
    case .warning(let warning): log("\(warning.code.rawValue): \(warning.reason)")
    case .error(let error, _):  log("\(error.code) trace=\(error.traceId ?? "-")")
    }
}
```

Set the handler right after creating `SunbayCheckout`. Earlier events (last 50) are buffered and
replayed. Diagnostics never contain card values, tokens, secrets or address contents.

---

## 9. Error handling

Errors are `CheckoutError` values with a stable `code`, a `category`, a developer-facing `message`
and an optional `traceId`. They reach you in two ways:

- Inside `CheckoutOutcome.failed(txnId:error:)`.
- As a thrown error from `CheckoutElements.create` and `retrievePayment()`.

Branch on `code`. The full list is in [`api.md`](./api.md#error-codes). Common cases:

| Code | What to do |
| --- | --- |
| `CHECKOUT_CLIENT_SECRET_MISSING` | Pass `checkoutClientSecret`. This is an integration bug. |
| `CHECKOUT_EXPIRED`, `SESSION_COMPLETED`, `SESSION_CLOSED` | Create a new session on your backend. |
| `NETWORK_UNAVAILABLE` | Ask the user to check the connection; retry. |
| `CARD_INPUT_INVALID` | Card or address input is invalid; inline errors are already visible. |
| `PAYMENT_FAILED` | Show a failure message; the user can retry or change method. |
| `WALLET_AUTH_FAILED` | Apple Pay authorization failed; offer another method. |

Show your own user-facing text. `message` is for developers and logs. Include `traceId` when you
contact Sunbay support.

---

## 10. Security and PCI model

- Card data is typed into native SDK controls, encrypted on the device with the session's RSA public
  key, and sent directly to the Sunbay backend. It does not pass through your app code.
- No public property, callback, diagnostic or error carries card values, wallet tokens, secrets or
  ciphertext. `PaymentOptionDisplayData` shows only a label and a brand image.
- `customerAccessSecret` and `checkoutClientSecret` are held in memory only and cleared when the
  session ends. Nothing sensitive is persisted.
- Deliver both secrets from your backend over HTTPS and do not log them.

See `../security-and-pci.md` for the full model.

---

## 11. Testing and verification

- `Example/SunbayCheckoutDemo` is the SDK's own demo app. It runs against the real `.dev` backend.
- Use `environment: .dev` or `.test` for non-production work. The default is `.production`.
- Apple Pay needs a real device with a configured wallet and your merchant id.
- `SunbayCheckoutTestSupport` offers scriptable service doubles for the SDK's own tests. It is not a
  public contract and must not ship in an app.
