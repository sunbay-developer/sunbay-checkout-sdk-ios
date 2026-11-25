# Address skeleton and saved-card logo slot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the address form's flat loading block with skeleton rows, and stop the saved-card row from shifting when its brand logo loads.

**Architecture:** A new `AddressSkeletonView` is used by `DynamicAddressFormView` for the initial load and (after a 150 ms grace period) for country reloads below the still-visible country row. `SavedCardRow` gets a fixed 30x24 brand slot (placeholder → logo fade-in, or a drawn badge), fed by a process-wide `CardBrandLogoLoader.shared` that the content controller prefetches into.

**Tech Stack:** Swift, UIKit, XCTest (UIKit tests run on the iOS Simulator only).

**Spec:** `docs/superpowers/specs/2026-11-25-address-skeleton-and-saved-card-logo-design.md`

## Global Constraints

- English only in code and comments. No public API change (`docs/api/` untouched).
- Skeleton row height `FloatingLabelMetrics.minFieldHeight`, row spacing 12, initial row count 4, grace period 150 ms.
- Brand slot 30x24; logo fade 0.15 s; no animation for a cached logo or with Reduce Motion.
- Logo cache is memory only.
- Test command (run in background, poll the log):
  `xcodebuild test -scheme SunbayCheckout-Package -destination 'platform=iOS Simulator,name=iPhone 17e' -only-testing:SunbayCheckoutTests/<Class> > /tmp/ios-test.log 2>&1 &`
  Pass = `** TEST SUCCEEDED **`.

## Review Focus

- User picks country X, then Y before X loads: X's late response must not rebuild the form (Task 2 test `test_staleCountryResponse_isIgnored`).
- Typed values (line1, city, postal) survive a country change that goes through the skeleton (Task 2 test `test_countryChange_preservesTypedValues`).
- Config fails after a country change: the error + retry state shows, not a stuck skeleton (Task 2 test `test_countryChangeFailure_showsError`).
- Saved card with no `logoUrl`: badge at once, never a permanent placeholder (Task 3 test `test_noLogoURL_showsBadgeImmediately`).
- Expired saved card: the slot content is dimmed like the rest of the row (Task 3 test `test_expiredCard_dimsSlot`).

---

### Task 1: `AddressSkeletonView`

**Files:**
- Create: `Sources/SunbayCheckout/UI/Content/Components/AddressSkeletonView.swift`
- Test: `Tests/SunbayCheckoutTests/UI/AddressSkeletonViewTests.swift`

**Interfaces:**
- Produces: `final class AddressSkeletonView: UIView` with `init(appearance: ResolvedAppearance, rowCount: Int)`, `var rowCount: Int { get set }` (clamped to `>= 1`), DEBUG `var isShimmeringForTest: Bool`.

- [ ] Write tests: `test_rowCount_clampsToAtLeastOne` (`rowCount = 0` → 1), `test_height_matchesRows` (4 rows → fitting height `4 * minFieldHeight + 3 * 12`), `test_reduceMotion_noShimmer` (inject `isReduceMotionEnabled: () -> Bool` returning true; in a window → `isShimmeringForTest == false`).
- [ ] Run, expect FAIL (type missing).
- [ ] Implement. Shimmer: a `CAGradientLayer` over the rows animating `locations` over 1.2 s, started in `didMoveToWindow` when in a window and Reduce Motion is off, removed otherwise.
- [ ] Run, expect PASS.

### Task 2: Use the skeleton in `DynamicAddressFormView`

**Files:**
- Modify: `Sources/SunbayCheckout/UI/Content/Components/DynamicAddressFormView.swift` (`LoadState`, `load()`, `reloadCountryConfig()`, `renderState()`, `configureContainer()`, `validate()`)
- Test: `Tests/SunbayCheckoutTests/UI/DynamicAddressFormViewTests.swift`

**Interfaces:**
- Consumes: `AddressSkeletonView` (Task 1).
- Produces: `init` gains `skeletonDelay: TimeInterval = 0.15` (internal). DEBUG readouts `isSkeletonVisibleForTest: Bool`, `isCountryRowVisibleForTest: Bool`.

- [ ] Write tests (scriptable service with a controllable delay; `skeletonDelay: 0` where the skeleton must show):
  `test_initialLoad_showsSkeleton`, `test_countryChange_slowLoad_keepsCountryRowAndShowsSkeleton`,
  `test_countryChange_fastLoad_neverShowsSkeleton` (delay 10 s, response immediate → skeleton never visible),
  `test_countryChange_preservesTypedValues`, `test_staleCountryResponse_isIgnored`,
  `test_countryChangeFailure_showsError`, `test_validate_returnsFalseDuringCountryReload`.
- [ ] Run, expect FAIL.
- [ ] Implement: add `LoadState.reloadingCountry`; a `requestGeneration: Int` bumped per request, results with an old generation dropped; on country change disable non-country rows, schedule the skeleton after `skeletonDelay` (cancelled when the result arrives); skeleton row count = hidden row count. Replace the flat `skeletonView` and its 120 pt constraint with an `AddressSkeletonView(rowCount: 4)`.
- [ ] Run the class, expect PASS; existing address tests stay green.

### Task 3: Fixed brand slot in `SavedCardRow`, shared loader, prefetch

**Files:**
- Create: `Sources/SunbayCheckout/UI/Content/Components/CardBrandBadge.swift` (moved badge drawing from `CardBrandIconsView`)
- Modify: `CardBrandIconsView.swift` (use `CardBrandBadge`), `SavedCardRow.swift`, `CardBrandLogoLoader.swift` (`static let shared`), `CheckoutContentViewController.swift:54` and `CardElement.swift:128` (use `.shared`), `CheckoutContentViewController.swift` (prefetch when saved cards are set)
- Test: `Tests/SunbayCheckoutTests/UI/SavedCardRowTests.swift` (new), `CardBrandLogoLoaderTests.swift`

**Interfaces:**
- Produces: `enum CardBrandBadge { static func image(scheme: String, appearance: ResolvedAppearance, traits: UITraitCollection) -> UIImage }`, scheme normalized by lowercasing and dropping spaces/underscores/hyphens (`"MASTERCARD"` → `mastercard` → `MC`). `CardBrandLogoLoader.shared`, `func prefetch(_ urls: [URL])`. `SavedCardRow` DEBUG `enum LogoSlotState { case placeholder, logo, badge }`, `var logoSlotStateForTest`.

- [ ] Write tests: `test_loading_showsPlaceholder_inFixedSlot` (slot frame 30x24), `test_loaded_showsLogo_sameSlotWidth` (number label x unchanged between placeholder and logo), `test_loadFailure_showsBadge`, `test_noLogoURL_showsBadgeImmediately`, `test_cachedLogo_showsWithoutAnimation`, `test_expiredCard_dimsSlot`, loader `test_prefetch_thenImage_isCached`.
- [ ] Run, expect FAIL.
- [ ] Implement as in the spec; remove the `brandBadge` `UILabel`. Keep `accessibilityLabel` unchanged.
- [ ] Run classes plus `CardBrandIconsViewTests` and `CheckoutContentViewControllerTests`, expect PASS.

### Task 4: Full run and docs

- [ ] Run the whole `SunbayCheckoutTests` on the simulator. Only the known `BottomSheetLayoutTests.test_install_unmeasured_usesInitialHeightSoEntranceHasAFrame` rounding failure may remain.
- [ ] `swift build` on the host passes.
- [ ] Add one line each to `docs/product-spec.md` (address loading state, saved-card logo slot). No `docs/api/` change.
