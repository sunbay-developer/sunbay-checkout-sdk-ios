# Address form unification and postal-code validation (design)

Status: awaiting approval. Size: small-to-medium change (UI + one pure Core helper + spec edits).

## Intent

Today `SimpleAddressFormView` (default style) is a separate implementation from `DynamicAddressFormView`:
it uses the system region list, has no country-to-postal linkage, and no postal-code validation. The
backend metadata (`AddressFieldConfig.pattern` / `required`) is decoded but never used, and
`DynamicAddressFormView` documents validation that does not exist. The host wants:

1. A valid postal code is required before a new-card payment is submitted (like HPP).
2. Simple mode reuses full mode's components and logic (country list, per-country config, linkage).
3. Validation rules are driven by backend config so they can be changed server-side without an SDK release.

## Goals

- One form implementation. Simple = full filtered to `country` / `line1` / `postalCode`.
- Changing the country updates the postal field label / placeholder (already true for full) and re-validates.
- Submit of a new card is blocked when the postal code is invalid; an inline error is shown under the field.
- Rules come only from the country config:
  - `pattern` present and the value non-empty: the value must match.
  - `required == true`: the value must be non-empty.
  - Neither present: no validation.

## Non-goals

- Validating line1, city, state or other fields (only the postal code in this change).
- Host-provided addresses (`billingAddress:` / `shippingAddress:`) and wallet-returned addresses are not
  validated by this change.
- Google autocomplete, postal-to-state lookup (still deferred).
- Changing `Appearance.billingAddressStyle` public API or its default (`.simple`).

## Anti-goals

- Simple mode must not become unusable when the metadata endpoint is down.
- No postal values in logs or diagnostics (PII rule unchanged).

## Constraints

- Core stays UI-agnostic: the validator lives in `Core/AddressMetadata/` and imports no UIKit.
- English only in code, comments and docs (AGENTS.md).
- Invalid or uncompilable backend `pattern` must not crash and must not block payment (treated as no pattern).

## Approaches considered

- A (chosen): add a visible-fields filter to `DynamicAddressFormView`, delete `SimpleAddressFormView`. One
  implementation; linkage, validation and value preservation written once.
- B: extract a shared address-form controller with two thin views. Cleaner for L2 but a much larger
  refactor of `DynamicAddressFormView` and its tests.
- C: keep `SimpleAddressFormView` and wire the service and validation into it. Smallest diff but duplicates
  linkage and validation, which is the inconsistency being removed.

## Design

1. `PostalCodeValidator` (Core/AddressMetadata, pure): `validate(_ value: String?, config: AddressFieldConfig?) -> Result`
   per the rules above. Pattern is matched against the whole trimmed value (anchored); a pattern that fails
   to compile is ignored.
2. `DynamicAddressFormView`:
   - New init parameter `visibleFields: Set<AddressFieldType>?` (nil = all, current behavior). Simple passes
     `[.country, .line1, .postalCode]`. Rows are filtered after `AddressFormLayoutResolver`; empty rows dropped.
     `options.collectName` / `collectPhone` still apply (shipping).
   - `validate() -> Bool`: validates the postal field against the current country config, shows or clears
     the inline error (`FloatingLabelTextField.setErrorActive` plus a message label), returns validity.
     Re-run on country change and on editing end; error clears on edit.
   - Fix the doc comment so it matches behavior.
3. Fallback for simple only: `FallbackAddressMetadataService` wraps the real service. On failure it returns
   the system region list and a generic config (`country`, `line1`, `postalCode`; postal `required`, no
   `pattern`). Full mode keeps today's failed state with a retry button.
4. `CheckoutContentViewController.handleConfirmNewCard`: after the card-number check and before
   `beginProcessing()`, call `validate()` on the billing and shipping address views; if any is invalid,
   return without submitting. The new-card CTA keeps its current "dimmed but tappable" behavior.
5. Delete `SimpleAddressFormView` and its tests, move its test seams (`fillForTest`, etc.) to
   `DynamicAddressFormView`; update tests that referenced it.
6. Docs: `docs/product-spec.md` address section (simple is no longer "no network"; the "never blocks a submit"
   line is replaced by: new-card submit is blocked on an invalid postal code, other fields are not blocked);
   `docs/real-api-integration-checklist.md` gets an entry for pattern/required being now enforced and the
   open item that backend patterns must be verified per country.
7. Localization: add `sunbay.address.postalCode.invalid` and `sunbay.address.postalCode.required` to
   `en` and `zh-Hans` strings.

## Left to the builder

- Exact error label placement and styling (follow the card-field error style).
- Whether the "editing end" validation also runs while typing (suggested: only after first blur or submit).
- Test updates: keep the existing address test coverage working, and cover the validator rules.

## Open verification

- Real backend `pattern` values per country have not been checked against dev; verify a few (US, CA, GB, CN)
  after implementation.
