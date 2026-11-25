# Address form skeleton and saved-card logo slot (design)

Date: 2026-11-25. Status: approved in conversation. Size: small change. No public API change.

## Intent

Two visual glitches in the card flow:

1. Changing the country in the full billing-address form hides the whole form (including the country
   row) and shows one flat 120 pt block until the new country config arrives. The user sees the form
   vanish into an empty block and the height jump.
2. A saved-card row first shows the brand as text (`MASTERCARD`, `VISA`), then swaps to the 30x24 logo when
   it loads. Text and logo differ in width, so the masked number shifts sideways and the row flickers.

Goal: no empty block, no sideways shift. Non-goals: changing the address data flow, bundling brand logos,
touching the card-number field's brand icons (`CardBrandIconsView` already uses fixed slots).

## Approaches

Address form:
- A. Keep the old fields, dimmed and disabled, until the new config arrives. Simple, but the old country's
  fields (for example "State") show briefly under the new country.
- **B. Skeleton rows (picked).** The country row stays visible; the other rows are replaced by placeholder
  rows shaped like real fields, with a light shimmer. Matches mainstream payment forms; height barely moves.
- C. A spinner under the country row. The height still jumps.

Saved-card logo:
- **Fixed slot + shared cache + prefetch (picked).** No shift, and the logo is usually already cached.
- Bundle common brand logos in the SDK. Fastest, but can drift from the backend logos. Rejected.

## Design

### Address form (`DynamicAddressFormView`)

- New `AddressSkeletonView`: a vertical stack of placeholder rows, spacing 12 (same as the form). Each row is
  a rounded rect of height `FloatingLabelMetrics.minFieldHeight`, `componentBackground` fill and `border`
  outline, with a short bar inside where the label sits. A shimmer sweeps across (about 1.2 s loop). With
  Reduce Motion on, the rows are static.
- Initial load: the flat block is replaced by the skeleton with 4 rows.
- Country change: the country row stays visible and interactive. The other rows are disabled at once. If the
  config arrives within 150 ms, the fields are rebuilt directly and no skeleton is shown. Otherwise the other
  rows are hidden and a skeleton with the same number of rows (at least 1) is shown below the country row.
- A response for a country that is no longer selected is ignored (the user picked again during the load).
- `validate()` returns `false` while a country reload is in progress, as it does during the initial load.
- Load failure keeps the existing error + retry state.

### Saved-card row (`SavedCardRow`)

- The brand sits in a fixed 30x24 slot. While loading, the slot shows a light rounded placeholder.
- A loaded logo fades in over 0.15 s. A logo already in the cache appears at once without animation. With
  Reduce Motion on, there is no fade.
- If the card has no logo URL, there is no loader, or the load fails, the slot shows a text badge drawn in the
  same 30x24 slot (the same badge style the card-number field uses: `MC`, `VISA`, `AMEX`...).
- `CardBrandLogoLoader.shared` is a process-wide in-memory cache. `CheckoutContentViewController` and
  `CardElement` use it. Nothing goes to disk.
- `CheckoutContentViewController` starts loading the saved-card logos as soon as it has the saved cards, so
  they are usually cached when the rows appear (`CardElement` already does this).

## Left to the builder

Exact placeholder colors (derived from `border` / `componentBackground`), shimmer gradient shape, and how the
badge drawing is shared between `CardBrandIconsView` and `SavedCardRow`.
