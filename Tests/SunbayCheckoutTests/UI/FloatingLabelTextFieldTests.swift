#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Behavior tests for `FloatingLabelTextField` (design §Part 2).
    ///
    /// UIKit is iOS-only; on the macOS host (`swift test`) this whole file is excluded by
    /// `#if canImport(UIKit)` and is vacuous. The real RED/GREEN requires building against the iOS
    /// Simulator SDK (see the package scheme). The field floats its label when focused OR non-empty,
    /// reserves a top band so text never overlaps the floated label, applies the float instantly when
    /// page transitions are disabled, and lets its owner force the danger color via `setErrorActive`.
    @MainActor
    final class FloatingLabelTextFieldTests: XCTestCase {
        private func makeAppearance(animations: Bool = true) -> ResolvedAppearance {
            var appearance = Appearance.default
            appearance.pageTransitionsEnabled = animations
            return .resolve(appearance)
        }

        /// A field with content but no focus must start floated (so a pre-filled value is not covered by
        /// a resting label).
        func test_labelFloatsWhenNonEmptyWithoutFocus() {
            let field = FloatingLabelTextField(appearance: makeAppearance())
            field.title = "ZIP"
            field.text = "94107"
            XCTAssertTrue(field.isLabelFloatedForTest)
        }

        /// An empty, unfocused field rests (label sits where a placeholder would).
        func test_labelRestsWhenEmptyAndUnfocused() {
            let field = FloatingLabelTextField(appearance: makeAppearance())
            field.title = "ZIP"
            XCTAssertFalse(field.isLabelFloatedForTest)
        }

        /// With page transitions disabled the float state applies immediately on focus, with no pending
        /// mid-transform.
        func test_floatAppliesInstantlyWhenAnimationsDisabled() {
            let field = FloatingLabelTextField(appearance: makeAppearance(animations: false))
            field.title = "CVC"
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
            window.addSubview(field)
            window.makeKeyAndVisible()
            field.becomeFirstResponder()
            XCTAssertTrue(field.isLabelFloatedForTest)
        }

        /// When the owner marks the field in error, the floated label shows the danger color even while
        /// focused (error precedence over focus/primary).
        func test_errorColorOverridesFocusColor() {
            let appearance = makeAppearance()
            let field = FloatingLabelTextField(appearance: appearance)
            field.title = "Card number"
            field.text = "4242"
            field.setErrorActive(true)
            XCTAssertEqual(field.floatingLabelColorForTest, appearance.danger)
        }

        /// The text / editing rect reserves a top band so the field text does not overlap the floated
        /// label.
        func test_textRectReservesTopBandForLabel() {
            let field = FloatingLabelTextField(appearance: makeAppearance())
            field.title = "MM / YY"
            field.frame = CGRect(x: 0, y: 0, width: 200, height: 52)
            let textRect = field.textRect(forBounds: field.bounds)
            let editingRect = field.editingRect(forBounds: field.bounds)
            XCTAssertGreaterThan(textRect.minY, 0, "text rect must leave room for the floated label")
            XCTAssertGreaterThan(editingRect.minY, 0, "editing rect must leave room for the floated label")
        }
    }
#endif
