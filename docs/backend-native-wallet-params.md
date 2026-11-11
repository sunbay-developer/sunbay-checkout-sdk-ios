# Native wallet parameters: comparison with web and backend request

Audience: the Checkout backend team. Written by the iOS SDK team on 2026-11-09 (revised the same day).

## 1. Result

The native SDKs (iOS PassKit, Android Google Pay API) can use the **same** `paymentMethods[].ewalletParam` that the web
SDK and the hosted page use. No separate format per `sessionType` is needed. The differences are limited to the items in
section 4.

An earlier version of this document asked for a native-specific format. That was wrong: the values already returned for
the dev test merchant are the same strings PassKit expects, apart from letter case (section 2).

## 2. Apple Pay: web versus native

Values returned today by the dev backend for `APPLE_PAY`:

```json
{
  "supportedNetworks": ["chinaUnionPay", "amex", "discover", "masterCard", "jcb", "visa"],
  "merchantCapabilities": ["supports3DS", "supportsCredit", "supportsDebit"]
}
```

| Field | Web (ApplePayJS) | Native (PassKit `PKPaymentRequest`) | Real difference |
|---|---|---|---|
| `supportedNetworks` | strings as above | `[PKPaymentNetwork]`, whose raw values are `Visa`, `MasterCard`, `AmEx`, `Discover`, `JCB`, `ChinaUnionPay`, ... | Letter case only. The SDK matches names case-insensitively, so the current values work unchanged. |
| `merchantCapabilities` | strings as above | option set (3DS, EMV, Credit, Debit) | None. The SDK maps `supports3DS`, `supportsEMV`, `supportsCredit`, `supportsDebit` to the options. |
| `countryCode` | optional, backend value wins, default `US` | required | None. The SDK uses the same rule: backend value if present, else `US`. |
| `currencyCode`, total | from the session | from the session | None. |
| Billing / shipping contact fields | derived from `collectBillingAddress` / `collectShippingAddress` | same | None, derived by the SDK. |
| Merchant identity | domain validation, no merchant id in the request | `merchantIdentifier` (the Apple Pay merchant id) | **Native only.** See section 4, item 3. |

Case-insensitive matching covers every PassKit network (`amex`/`AmEx`, `chinaUnionPay`/`ChinaUnionPay`, `jcb`/`JCB`,
`masterCard`/`MasterCard`, `vPay`/`VPay`, and so on; verified against the PassKit constants on 2026-11-09). A name the SDK
does not know is ignored; if no supported network remains, the Apple Pay row is not shown.

## 3. Google Pay: web versus native

Values returned today by the dev backend for `GOOGLE_PAY`: `environment`, `merchantId`, `merchantName`, `gatewayId`,
`gatewayMerchantId`, `allowedCardNetworks` (`AMEX`, `DISCOVER`, `MASTERCARD`, `JCB`, `VISA`), `allowedCardAuthMethods`
(`CRYPTOGRAM_3DS`).

| Item | Web | Native (Android `PaymentsClient`) | Real difference |
|---|---|---|---|
| Request JSON (`allowedPaymentMethods`, `tokenizationSpecification`, `merchantInfo`, `transactionInfo`) | built from the fields above | identical JSON | None. |
| `environment` | constructor option of the web `PaymentsClient`, from `ewalletParam` | constructor option (`WalletConstants.ENVIRONMENT_TEST` / `ENVIRONMENT_PRODUCTION`), from the same `ewalletParam` value | Same values, different place. |
| `merchantOrigin` | optional, web only | not used | Android ignores it. |
| `transactionInfo.countryCode` | hard-coded `US` in the web client; any backend value is ignored today | needed | The SDK uses the backend value if present, else `US` (section 4, item 3). |

## 4. What we ask the backend for

No change to the `ewalletParam` format or fields is required. Decisions: native shares the web format; `countryCode` is
optional with default `US`; `environment` is already returned.

1. **Define Apple Pay merchant id and certificate onboarding for native.**
   - `merchantIdentifier` must be listed in the host app's entitlement `com.apple.developer.in-app-payments`, which the
     integrator fixes at build time. The backend cannot choose it.
   - Proposal: the integrator passes it to the SDK (`CheckoutConfiguration.applePayMerchantId`); no new backend field.
     The Apple Pay Payment Processing certificate for that merchant id must be configured on the Sunbay side so tokens can
     be decrypted, so please define how an integrator's Apple Pay merchant id and certificate are registered.
   - If you prefer to return the merchant id, add `merchantIdentifier` to `ewalletParam`; the SDK uses the host value
     first and falls back to the session value. A value not present in the app's entitlement cannot present the sheet.
   - Outcome (2026-11-11): the backend chose to receive it on submit as
     `digitalWalletInfo.applePay.merchantIdentifier` (`docs/api/checkout-api.json`); the SDK sends the merchant id the
     token was authorized with.
2. **Confirm the wallet token formats accepted in `cardEncryptedData`** (with `paymentMethod` `APPLE_PAY` or
   `GOOGLE_PAY`):
   - Apple Pay: `PKPaymentToken.paymentData` (JSON `Data`) converted to a UTF-8 string, unchanged. Not yet verified on a
     real device.
   - Google Pay: `paymentMethodData.tokenizationData.token` (a JSON string), unchanged.
3. **Optional, for non-US merchants later: add `countryCode`** (merchant country, ISO 3166-1 alpha-2) to `ewalletParam` of
   `APPLE_PAY` and `GOOGLE_PAY`. Until then the SDKs use `US`, exactly like the web Apple Pay client today. (The web Google
   Pay client hard-codes `US` and would need a small change to read it; the JS/HPP team owns that.)
4. **Optional: do not return a wallet entry whose required parameters cannot be produced** (for example no supported
   network, or the certificate is not configured). The SDK already hides a wallet whose required parameters are missing
   or empty, but omitting the entry is the cleaner signal.

## 5. What the SDK does with the values (client side, one to one)

- Apple Pay: builds the `PKPaymentRequest` from the session (currency, total, merchant name label) and `ewalletParam`
  (`countryCode`, `supportedNetworks`, `merchantCapabilities`). The only client logic is the name-to-constant lookup in
  section 2 and the `US` default for `countryCode`; there is no validation or merging of other keys, and no host override
  of these values. If no supported network or capability remains, Apple Pay is not shown.
- Contact fields and address handling follow the session flags `collectBillingAddress` and `collectShippingAddress`.
- Tokens are submitted as described in item 4. Success is whatever terminal state the backend returns; the SDK does not poll.

If the backend would rather return PassKit raw values (`AmEx`, `ChinaUnionPay`, ...) for native sessions, that also works,
because the lookup accepts them; it is not required.

## 6. Acceptance checklist

- [ ] Apple Pay merchant id and certificate onboarding for native integrators is defined.
- [ ] Token formats for both wallets are confirmed.
- [ ] (Optional, non-US merchants) `countryCode` is added to `ewalletParam`.
- [ ] (Optional) A wallet that cannot be offered is absent from `paymentMethods`.
