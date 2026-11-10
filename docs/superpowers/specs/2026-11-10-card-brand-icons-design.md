# Card brand icons in the card form (design)

Status: awaiting approval. Size: small change.

## Intent
The card-number field shows one fixed system `creditcard` icon. Make it behave like the HPP page
(`checkout/src/components/Bankcard/CardNumberInput.tsx`, `CardBrandCarousel.tsx`, `CardBrandIcon.tsx`):
show the session's supported card brands, rotate through the extras, and show only the matching brand once
the user types. Also add the fixed CVV icon used on HPP (`public/imgs/cvv-icon.svg`).

## Goals
- Empty card number: show the first 2 brand icons fixed, and cycle the remaining brands in a third slot
  (interval 2 s, 0.3 s cross-fade). With 2 or fewer brands, show all and do not rotate.
- Non-empty card number: show only the icon of the recognized brand; if none is recognized, show nothing.
- Icons come from the session (`session.methodEntries[].logoURL`, card entries only, backend order,
  after the host's method filter).
- Recognition reuses the existing `localScheme` / `backendScheme` (backend BIN result wins).
- CVV field shows a fixed 34x20 pt icon on the right, with room reserved so text does not overlap it.

## Non-goals / anti-goals
- No L2 (EmbeddedPaymentElement) work; no public API change.
- No card data, BIN, or session data in logs; logo requests carry nothing but the logo URL.
- Nothing persisted: in-memory image cache only, no disk cache.
- Do not change PAN formatting, validation, or BIN recognition logic.

## Approaches considered
1. **Native views + URLSession loader with in-memory cache (chosen).** Matches HPP exactly, keeps icons
   session-driven, no new dependency.
2. Bundle brand icons in the SDK. Rejected: contradicts "icons come from session data" and goes stale.
3. Third-party image library. Rejected: new dependency for a handful of small logos.

## Design (calls made by me)
- `CardBrandIconsView` (UI/Content/Components, UIKit): replaces `brandIconView` in `CardFormView`. Inputs:
  `[CardBrandItem]` (scheme key, logo URL) and `setRecognizedScheme(_:)` / `setEmpty(_:)`. Icon size
  32x20, 4 pt spacing, aspect-fit. Timer paused when not empty, off-window, or fewer than 3 brands.
  Honors Reduce Motion by not cross-fading (switches instantly).
- `CardBrandLogoLoader` (internal, UI layer): `URLSession` fetch + `NSCache`; failures are silent and the
  brand is skipped. If no logo loaded at all, fall back to the current system `creditcard` icon.
- Scheme matching: compare the session `method` (e.g. `VISA`, `DINERSCLUB`) with the resolved scheme
  case-insensitively and trimmed. HPP needs an alias (`dinersclub` -> `diners`) only because its rule key
  is `diners`; the SDK rule key is already `dinersclub` (card-brand-rules.json), so no alias table.
- Wiring: `CheckoutContentViewController` passes the visible CARD `MethodEntry` list to `CardFormView`;
  `CardFormView` updates the icons view on every PAN change and on `setBackendScheme`.
- CVV icon: export `cvv-icon.svg` to PNG @2x/@3x into the SDK resources; `cvvField` trailing is pinned to
  the icon's leading minus 8 pt, as for the PAN field.

## Left to the builder
- Exact resource location/registration for the PNGs in `Package.swift`.
- Verifying the CVV row still fits the floating label on the narrow right half (compact density).
- Updating unit tests and regenerating snapshot reference images if layout changes.
- Whether to add a doc line in `docs/product-spec.md` and `docs/real-api-integration-checklist.md`
  (logo URLs are fetched from the session, not verified against live dev data yet).
