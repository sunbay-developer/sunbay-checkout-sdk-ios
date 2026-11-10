# Native wallet parameters: backend request

Audience: the Checkout backend team. Written by the iOS SDK team on 2026-11-09.

Scope: sessions created with `sessionType = "sdk"` (the native iOS and Android SDKs). Sessions of type `embedded` and
`hosted_page` (web SDK and the hosted payment page) keep today's behavior and must not change.

## 1. Why this is needed

For wallets, `paymentMethods[].ewalletParam` of the load-session response (`POST /checkout/web/session/{sessionId}`)
carries the wallet request parameters. Today it has the **web** shape:

- `APPLE_PAY`: `{ merchantCapabilities: [...], supportedNetworks: [...] }` using ApplePayJS strings
  (`"supports3DS"`, `"chinaUnionPay"`, and so on).
- `GOOGLE_PAY`: `{ environment, merchantId, merchantName, gatewayId, gatewayMerchantId, allowedCardNetworks,
  allowedCardAuthMethods }`.

The native SDKs do not process these values (no mapping, no validation, no merging). They use exactly what the backend
returns. So for `sessionType = "sdk"` the backend must return values the native APIs accept as they are.

The native iOS SDK currently hard-codes country `US`, networks Visa/MasterCard/Amex and capability 3DS, so it ignores
the other networks the backend enables (for example China UnionPay). Android needs the same country fix.

## 2. Requested changes (checklist)

| # | Change | Applies to |
|---|---|---|
| 1 | Return `ewalletParam` for `APPLE_PAY` with the native fields in section 3.2 | `sessionType=sdk` |
| 2 | Return `supportedNetworks` as PassKit raw values (section 3.3), not ApplePayJS strings | `sessionType=sdk` |
| 3 | Return the merchant country `countryCode` for `APPLE_PAY` and `GOOGLE_PAY` | `sessionType=sdk` |
| 4 | Keep the `GOOGLE_PAY` fields as they are, add `countryCode`, and confirm the `environment` value per backend environment (section 4.3) | `sessionType=sdk` |
| 5 | Do not return a wallet entry at all when its required parameters cannot be produced (section 5) | `sessionType=sdk` |
| 6 | Confirm the Apple Pay merchant id and processing-certificate strategy (section 3.4) | `sessionType=sdk` |
| 7 | Confirm the wallet token formats accepted in `cardEncryptedData` (section 6) | submit |

## 3. Apple Pay (iOS, PassKit `PKPaymentRequest`)

### 3.1 All native request inputs

| Native parameter | Type | Required | Provided by |
|---|---|---|---|
| `merchantIdentifier` | String | yes | host app configuration (section 3.4) |
| `countryCode` | ISO 3166-1 alpha-2 | yes | **backend (new)** |
| `currencyCode` | ISO 4217 | yes | session `currency` |
| `paymentSummaryItems` | array, at least 1; the last item is the total, labelled with the merchant name | yes | session `totalAmount`, `merchantName` (optionally `productAmount`, `taxAmount`, `surchargeAmount`, `tipAmount`) |
| `supportedNetworks` | `[PKPaymentNetwork]` | yes | **backend (new format)** |
| `merchantCapabilities` | option set: 3DS, EMV, Credit, Debit (3DS is mandatory) | yes | **backend** |
| `requiredBillingContactFields` | set of `post`, `name`, `phone`, `email`, `phoneticName` | no | SDK, from session `collectBillingAddress` |
| `requiredShippingContactFields` | same set | no | SDK, from session `collectShippingAddress` |

The SDK derives contact fields itself, the same way the hosted page does: billing asks for `post` and `name`;
shipping asks for `post`, `name` and `phone`. It skips a kind when the host app already supplied a complete address
for it. The backend does not need to return anything for contact fields.

### 3.2 Requested `ewalletParam` for `APPLE_PAY`

```json
{
  "countryCode": "US",
  "supportedNetworks": ["Visa", "MasterCard", "AmEx", "Discover", "JCB", "ChinaUnionPay"],
  "merchantCapabilities": ["supports3DS"]
}
```

| Field | Type | Required | Rules |
|---|---|---|---|
| `countryCode` | string | yes | Merchant country, ISO 3166-1 alpha-2, upper case. |
| `supportedNetworks` | string[] | yes | Non-empty. Only the exact, case-sensitive values in section 3.3. Return only networks your acquirer accepts. |
| `merchantCapabilities` | string[] | yes | Non-empty and contains `"supports3DS"`. Allowed values: `supports3DS`, `supportsEMV`, `supportsCredit`, `supportsDebit` (same strings as web). |

### 3.3 Allowed `supportedNetworks` values

These are the `rawValue` strings of the PassKit constants (verified with the current Xcode SDK on 2026-11-09). They are
case-sensitive and differ from the ApplePayJS web strings (`"visa"`, `"masterCard"`, `"amex"`, `"chinaUnionPay"`).

| PassKit constant | Value to return | | PassKit constant | Value to return |
|---|---|---|---|---|
| `.visa` | `Visa` | | `.cartesBancaires` | `CartesBancaires` |
| `.masterCard` | `MasterCard` | | `.eftpos` | `Eftpos` |
| `.amex` | `AmEx` | | `.electron` | `Electron` |
| `.discover` | `Discover` | | `.interac` | `Interac` |
| `.JCB` | `JCB` | | `.maestro` | `Maestro` |
| `.chinaUnionPay` | `ChinaUnionPay` | | `.vPay` | `VPay` |
| `.girocard` | `girocard` | | `.privateLabel` | `PrivateLabel` |
| `.mada` | `mada` | | `.elo` | `Elo` |
| `.mir` | `Mir` | | `.quicPay` | `QUICPay` |

Availability of some constants depends on the iOS version; the SDK passes the list through unchanged.

### 3.4 Merchant id and processing certificate (decision needed)

`merchantIdentifier` must be listed in the host app's entitlement `com.apple.developer.in-app-payments`, which is fixed at
build time by the integrator's Apple developer account. The backend therefore cannot choose it. Proposed model:

- The integrator passes its Apple Pay merchant id to the SDK (`CheckoutConfiguration.applePayMerchantId`).
- The Apple Pay Payment Processing certificate for that merchant id must be configured on the Sunbay side (gateway or
  acquirer) so tokens can be decrypted.
- The backend needs a merchant-onboarding step that registers the Apple Pay merchant id and certificate for each
  integrator. Please confirm how this is done today for the web (domain verification) and for native.

If you prefer to return the merchant id in the session, add `merchantIdentifier` to the `ewalletParam` above. The
SDK will use the host value first and fall back to the session value; a value that is not in the app's entitlement
cannot present the Apple Pay sheet.

## 4. Google Pay (Android, `PaymentsClient`)

The Google Pay request JSON is the same on web and Android, so the current `ewalletParam` fields are already enough.
Only the items marked below change.

### 4.1 `isReadyToPay` and `loadPaymentData` inputs

| Request field | Provided by |
|---|---|
| `apiVersion`, `apiVersionMinor` | SDK, fixed `2` and `0` |
| `allowedPaymentMethods[0].type` | SDK, fixed `CARD` |
| `parameters.allowedAuthMethods` | backend `allowedCardAuthMethods` (`PAN_ONLY`, `CRYPTOGRAM_3DS`) |
| `parameters.allowedCardNetworks` | backend `allowedCardNetworks` (for example `VISA`, `MASTERCARD`, `AMEX`, `DISCOVER`, `JCB`) |
| `tokenizationSpecification.type` | SDK, fixed `PAYMENT_GATEWAY` |
| `tokenizationSpecification.parameters.gateway` | backend `gatewayId` |
| `tokenizationSpecification.parameters.gatewayMerchantId` | backend `gatewayMerchantId` |
| `merchantInfo.merchantId` | backend `merchantId` (Google merchant id, required in production) |
| `merchantInfo.merchantName` | backend `merchantName` |
| `transactionInfo.totalPrice` | session `totalAmount` as a string |
| `transactionInfo.currencyCode` | session `currency` |
| `transactionInfo.totalPriceStatus` | SDK, fixed `FINAL` |
| `transactionInfo.countryCode` | **backend (new)**, currently hard-coded `US` |
| `billingAddressRequired`, `billingAddressParameters` | SDK, from session `collectBillingAddress` (`format: FULL`) |
| `shippingAddressRequired`, `shippingAddressParameters` | SDK, from session `collectShippingAddress` |
| `emailRequired` | SDK, fixed `false` |

### 4.2 Requested `ewalletParam` for `GOOGLE_PAY`

Same as today, plus `countryCode`:

```json
{
  "environment": "TEST",
  "merchantId": "<google merchant id>",
  "merchantName": "<display name>",
  "gatewayId": "<gateway>",
  "gatewayMerchantId": "<gateway merchant id>",
  "allowedCardNetworks": ["VISA", "MASTERCARD", "AMEX", "DISCOVER", "JCB"],
  "allowedCardAuthMethods": ["PAN_ONLY", "CRYPTOGRAM_3DS"],
  "countryCode": "US"
}
```

### 4.3 Differences from web

- `environment` (`TEST` or `PRODUCTION`) is not part of the request JSON on Android. It selects the `PaymentsClient`
  environment (`WalletConstants.ENVIRONMENT_TEST` or `ENVIRONMENT_PRODUCTION`). Observation: the dev backend currently
  returns `"PRODUCTION"` for the dev test merchant. Please confirm what each backend environment should return.
- `merchantOrigin` is web only (domain context) and is not used on Android.
- Google requires the integration to be reviewed in the Google Pay and Wallet Console before production access. The
  review process was not verified by the SDK team; please confirm who owns it.
- Google Pay is not planned for the iOS SDK in the first release.

## 5. Missing or invalid parameters

The SDK does not validate wallet parameters. If a wallet cannot be offered for a session (for example, no supported
network is enabled, or the certificate is not configured), **omit that wallet's entry from `paymentMethods`** instead of
returning an incomplete `ewalletParam`. The SDK then does not show the wallet, and no client logic is involved.

One session may contain both `APPLE_PAY` and `GOOGLE_PAY` entries for `sessionType = "sdk"`: each platform uses the
wallet it supports and ignores the other.

## 6. Tokens submitted to `payment/submit`

Both wallets submit the token in `cardEncryptedData`, with `paymentMethod` set to `APPLE_PAY` or `GOOGLE_PAY`.

| Wallet | What the SDK sends today |
|---|---|
| Apple Pay | `PKPaymentToken.paymentData` (JSON `Data`) converted to a UTF-8 string, unchanged |
| Google Pay | `paymentMethodData.tokenizationData.token` (a JSON string), unchanged |

Please confirm that the backend accepts these formats exactly. The Apple Pay format has not yet been verified on a real
device.

## 7. Related context (no backend change needed for these)

- The SDK sends billing and shipping addresses as `payerBillingInfo` and `payerShippingAddress` when the session
  requires them. Wallets return their own addresses; the SDK maps them to the same fields.
- A wallet payment is successful only when the backend reports a terminal state; the SDK does not poll.

## 8. Acceptance checklist

- [ ] A `sessionType = "sdk"` session returns `APPLE_PAY` with the three fields in section 3.2, using the exact
      values from section 3.3.
- [ ] A `sessionType = "sdk"` session returns `GOOGLE_PAY` with `countryCode` added and the environment confirmed.
- [ ] A `sessionType = "embedded"` or `"hosted_page"` session returns the same data as before.
- [ ] A wallet that is not configured is absent from `paymentMethods`.
- [ ] Merchant id and processing certificate onboarding is defined (section 3.4).
- [ ] Token formats are confirmed (section 6).
