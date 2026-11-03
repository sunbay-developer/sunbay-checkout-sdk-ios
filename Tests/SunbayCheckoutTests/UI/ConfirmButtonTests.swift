#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Unit tests for `ConfirmButton` and `InlineNoticeView` (Task 6) — iOS only; entirely excluded
    /// by `#if canImport(UIKit)` on the macOS host, so they are vacuous under `swift test` and must
    /// run on the iOS simulator.
    ///
    /// These cover the behaviors the brief calls out:
    /// 1. `.processing` disables interaction (`isEnabled == false`);
    /// 2. `.succeeded` invokes the completion within the success display window even when
    ///    `animated: false`;
    /// 3. a color-scheme change re-resolves the `InlineNoticeView`'s CALayer border color (the
    ///    dynamic `danger` color resolves to different `cgColor` snapshots in light vs dark).
    final class ConfirmButtonTests: XCTestCase {
        func test_processingDisablesInteraction() {
            let b = ConfirmButton(appearance: .resolve(.default))
            b.update(status: .processing, animated: false)
            XCTAssertFalse(b.isEnabled)
        }

        func test_succeededInvokesCompletion() {
            let b = ConfirmButton(appearance: .resolve(.default))
            let exp = expectation(description: "done")
            b.update(status: .succeeded, animated: false) { exp.fulfill() }
            wait(for: [exp], timeout: 2)
        }

        func test_schemeChangeReresolvesLayerColors() {
            // InlineNoticeView uses a CALayer border; after a trait change its borderColor must be
            // re-resolved, not keep the stale scheme's cgColor.
            let v = InlineNoticeView(appearance: .resolve(.default))
            v.show(message: "x", severity: .error)
            let light = UITraitCollection(userInterfaceStyle: .light)
            let dark = UITraitCollection(userInterfaceStyle: .dark)
            v.overrideUserInterfaceStyle = .light
            v.traitCollectionDidChangeForTest(light)
            let lightColor = v.layer.borderColor
            v.overrideUserInterfaceStyle = .dark
            v.traitCollectionDidChangeForTest(dark)
            XCTAssertNotEqual(lightColor, v.layer.borderColor)
        }
    }
#endif
