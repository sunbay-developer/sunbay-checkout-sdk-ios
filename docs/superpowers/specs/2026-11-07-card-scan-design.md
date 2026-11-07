# Offline card scanning — design

## Intent
Let a payer fill the card number (and expiry) by pointing the camera at the card, as Stripe's
"Scan card" does. Convenience and fewer typos, without weakening the PCI boundary.

## Goals
- A themed "Scan card" button in the "Card information" header row of the new-card page.
- 100% on-device: AVFoundation capture + Apple Vision text recognition. No network, no third-party
  dependency, no model download.
- Auto-detect support; show the button only when scanning can work. Host can force it off.

## Non-goals / anti-goals
- CVC is never scanned (not on the card front). Cardholder name is not scanned.
- No frame, image, or recognized text is persisted, logged, or returned to the host.
- No third-party scanner SDK (would break "small, stable, self-contained").

## Approaches considered
1. **Own scanner on Apple Vision (chosen).** System frameworks only; full control over UI/theme/parsing.
2. Embed Stripe CardScan: heavy transitive deps + ML model, license/size coupling. Rejected.
3. System `captureTextFromCamera`: not card-aware, no theming. Rejected.

## Design
- **Public API:** `Appearance.cardScanning: Appearance.CardScanning = .automatic` with cases
  `.automatic` (show when supported) and `.disabled` (never show).
- **Availability (automatic):** button is shown only if ALL hold: host did not disable; host
  `Info.plist` has `NSCameraUsageDescription` (a missing key crashes on camera access); a camera
  exists (simulator has none); camera access is not denied/restricted. Decision logic is a pure
  function in Core (`CardScanSupport`), host-testable.
- **Core (no UIKit):** `CardScanParser` extracts PAN (13–19 digits, Luhn, digits possibly split
  into groups) and expiry (`MM/YY|MM/YYYY`, not expired, latest wins) from recognized lines.
  `CardScanStabilizer` requires the same PAN in 2 frames, then waits briefly for an expiry.
- **UI:** `CardScanViewController` (full-screen modal, card-frame guide, cancel) runs capture +
  `VNRecognizeTextRequest` (on-device, language correction off), stops at first stable result.
  `CardFormView.applyScannedCard(...)` writes into the existing fields (through the normal
  formatters) and moves focus to CVC. Button tint = `appearance.primary`.
- **Strings:** `sunbay.card.scan`, `sunbay.card.scan.hint` in en + zh-Hans.

## Left to the builder
Exact guide-frame geometry and haptics; the demo app gets `NSCameraUsageDescription` so the real
flow can be tried on device.
