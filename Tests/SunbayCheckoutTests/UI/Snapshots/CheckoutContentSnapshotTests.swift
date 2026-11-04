#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Optional, opt-in snapshot coverage for the redesigned `CheckoutContentViewController` key
    /// screens in light + dark (spec §8, Task 13).
    ///
    /// ## Why this is not part of the `swift test` gate
    /// UIKit is iOS-only, so on the macOS host (`swift test`) this whole file is excluded by
    /// `#if canImport(UIKit)` and is vacuous — it never runs there. On the iOS Simulator the tests are
    /// additionally gated behind an **opt-in environment flag**: absent `SUNBAY_SNAPSHOTS=1` each test
    /// throws `XCTSkip` at the top, so the default simulator run reports them as *skipped*, never as a
    /// pass/fail. This keeps both the host `swift test` gate and the simulator default run unaffected
    /// (spec §8: "snapshots optional, NOT in the swift test gate").
    ///
    /// ## Dependency-free approach (AGENTS.md §1 "SPM-primary / self-contained")
    /// No third-party snapshot library. A view controller's view is rendered at a fixed device size
    /// into a `UIImage` via `UIGraphicsImageRenderer`, with `overrideUserInterfaceStyle` toggled for
    /// light/dark. The PNG is then either:
    ///   - **recorded** — when `SUNBAY_SNAPSHOTS=1` *and* `SUNBAY_SNAPSHOTS_RECORD=1` — written to a
    ///     `__Snapshots__` directory next to this file and the test passes; or
    ///   - **compared** — when `SUNBAY_SNAPSHOTS=1` without record — byte-compared against the
    ///     committed reference PNG and failed on mismatch (or when the reference is missing).
    ///
    /// Reference PNGs are not committed by default (they can be generated on a dev machine with the
    /// record flags); this matches the "optional / best-effort" nature of the task.
    @MainActor
    final class CheckoutContentSnapshotTests: XCTestCase {
        // MARK: - Opt-in gating

        /// Whether the snapshot suite is opted in (`SUNBAY_SNAPSHOTS=1`).
        private var isOptedIn: Bool {
            ProcessInfo.processInfo.environment["SUNBAY_SNAPSHOTS"] == "1"
        }

        /// Whether to (re)record references instead of comparing (`SUNBAY_SNAPSHOTS_RECORD=1`).
        private var isRecording: Bool {
            ProcessInfo.processInfo.environment["SUNBAY_SNAPSHOTS_RECORD"] == "1"
        }

        /// The first line of every test: skip unless explicitly opted in.
        private func requireOptIn() throws {
            try XCTSkipUnless(isOptedIn, "snapshots opt-in: set SUNBAY_SNAPSHOTS=1")
        }

        // MARK: - Fixtures (mirrors CheckoutContentViewControllerTests)

        /// A trivial in-memory address-metadata service (simple mode never consults it, but the init
        /// requires one).
        private struct MockAddressService: AddressMetadataService {
            func countries(locale: String?) async throws -> AddressCountryList {
                AddressCountryList(
                    countries: [AddressCountry(code: "US", name: "United States")], detectedCountry: "US")
            }

            func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
                AddressCountryConfig(
                    code: countryCode,
                    fields: [.country: AddressFieldConfig(
                        type: .country, required: true, pattern: nil, label: "Country", placeholder: "Country")],
                    layout: [[.country]],
                    subdivisions: []
                )
            }
        }

        private func makeSession(cofEnabled: Bool = false) -> CheckoutSession {
            CheckoutSession(
                id: "sess_1",
                amount: Amount(minorUnits: 1999, currencyCode: "USD"),
                merchantName: "Demo Merchant",
                methods: [.card],
                expiresAt: Date().addingTimeInterval(600),
                rsaPublicKey: nil,
                cofEnabled: cofEnabled
            )
        }

        private func makeVC(savedCards: [SavedCard], cofEnabled: Bool = false) -> CheckoutContentViewController {
            CheckoutContentViewController(
                session: makeSession(cofEnabled: cofEnabled),
                savedCards: savedCards,
                appearance: .resolve(.default),
                localize: { $0 },
                billingMode: .simple,
                shippingMode: .simple,
                addressService: MockAddressService()
            )
        }

        private var sampleSavedCards: [SavedCard] {
            [
                SavedCard(id: "pm_1", brand: "visa", last4: "4242", expMonth: 8, expYear: 2028),
                SavedCard(id: "pm_2", brand: "mastercard", last4: "5454", expMonth: 1, expYear: 2027),
            ]
        }

        // MARK: - Tests (key screens × light/dark)

        /// Home with no saved cards: the new-card subpage is the root.
        func test_snapshot_newCard_noSavedCards() throws {
            try requireOptIn()
            let vc = makeVC(savedCards: [])
            vc.loadViewIfNeeded()
            vc.openNewCardForTest()
            try verifySnapshot(of: vc, named: "newCard_noSavedCards")
        }

        /// Home with saved cards: the one-tap saved-card list is the root.
        func test_snapshot_savedCardList() throws {
            try requireOptIn()
            let vc = makeVC(savedCards: sampleSavedCards)
            try verifySnapshot(of: vc, named: "savedCardList")
        }

        /// New-card subpage showing an inline field error on the PAN field. Tapping Pay with an empty
        /// (incomplete) form drives `handleConfirmNewCard`'s `cardInput == nil` branch, which surfaces
        /// the inline number-field error — a deterministic way to reach the error state through the
        /// existing public test seam without adding a new one.
        func test_snapshot_newCard_fieldError() throws {
            try requireOptIn()
            let vc = makeVC(savedCards: [])
            vc.loadViewIfNeeded()
            vc.openNewCardForTest()
            vc.simulateTapPay()
            try verifySnapshot(of: vc, named: "newCard_fieldError")
        }

        /// Processing state: confirm a filled new card and capture the spinning CTA / disabled inputs.
        func test_snapshot_processing() throws {
            try requireOptIn()
            let vc = makeVC(savedCards: [])
            vc.loadViewIfNeeded()
            vc.openNewCardForTest()
            vc.fillCardForTest()
            vc.simulateTapPay()
            try verifySnapshot(of: vc, named: "processing")
        }

        // Note: the `.succeeded` screen is intentionally not snapshotted. Applying `.succeeded` runs the
        // success animation and then calls `didFinishWith` to auto-close after
        // `minimumFlightTime + successDisplayDuration`; the terminal success UI is transient and not
        // deterministically capturable without reaching into private animation timing, so per the
        // task's "cover fewer and note it" guidance it is omitted.

        // MARK: - Render helper

        /// The fixed render size (iPhone 12/13/14 logical points).
        private static let renderSize = CGSize(width: 390, height: 844)

        /// Renders `vc`'s view at a fixed size for both light and dark and records/compares each.
        private func verifySnapshot(of vc: CheckoutContentViewController, named name: String) throws {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let suffix = style == .light ? "light" : "dark"
                let image = render(vc, style: style)
                XCTAssertGreaterThan(image.size.width, 0, "Rendered image must be non-empty (\(name)-\(suffix))")
                guard let png = image.pngData() else {
                    return XCTFail("Could not encode PNG for \(name)-\(suffix)")
                }
                try recordOrCompare(png, named: "\(name)-\(suffix)")
            }
        }

        /// Renders a view controller's view into a `UIImage` at `renderSize` under a given style.
        ///
        /// Dependency-free: forces the interface style on the VC and its view, lays out at a fixed size,
        /// then draws the view's layer into an image context. This reliably captures the composed
        /// content offscreen.
        ///
        /// Known limitation: offscreen (window-less) rendering does not re-resolve every
        /// `UITraitCollection`-dependent dynamic color against the forced style, so the light and dark
        /// captures of the same screen can come out visually identical on some OS versions. The style is
        /// still applied (via `overrideUserInterfaceStyle`) and distinct light/dark files are produced;
        /// treat the pair as "best-effort" rather than a guaranteed theme diff. See the task-13 report.
        private func render(_ vc: UIViewController, style: UIUserInterfaceStyle) -> UIImage {
            vc.loadViewIfNeeded()
            vc.overrideUserInterfaceStyle = style
            let view = vc.view!
            view.overrideUserInterfaceStyle = style
            view.frame = CGRect(origin: .zero, size: Self.renderSize)
            view.setNeedsLayout()
            view.layoutIfNeeded()

            let renderer = UIGraphicsImageRenderer(size: Self.renderSize)
            return renderer.image { context in
                view.layer.render(in: context.cgContext)
            }
        }

        // MARK: - Record / compare

        /// Records the PNG (if `SUNBAY_SNAPSHOTS_RECORD=1`) or byte-compares it to the committed
        /// reference, failing on mismatch or a missing reference.
        private func recordOrCompare(_ png: Data, named name: String) throws {
            let url = Self.snapshotDirectory().appendingPathComponent("\(name).png")

            if isRecording {
                try FileManager.default.createDirectory(
                    at: Self.snapshotDirectory(), withIntermediateDirectories: true)
                try png.write(to: url)
                return
            }

            guard let reference = try? Data(contentsOf: url) else {
                return XCTFail(
                    "No reference snapshot at \(url.path). Record it with "
                        + "SUNBAY_SNAPSHOTS=1 SUNBAY_SNAPSHOTS_RECORD=1.")
            }
            // Dependency-free equality: size + byte compare. Rendering must be deterministic for this to
            // be stable across runs on the same simulator/OS.
            XCTAssertEqual(
                png, reference, "Snapshot \(name) differs from reference. Re-record if the change is intended.")
        }

        /// The `__Snapshots__` directory next to this source file.
        private static func snapshotDirectory() -> URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("__Snapshots__")
        }
    }
#endif
