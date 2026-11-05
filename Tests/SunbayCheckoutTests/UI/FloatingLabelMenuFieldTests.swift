#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Behavior tests for `FloatingLabelMenuField` (the select/menu counterpart of
    /// `FloatingLabelTextField`).
    ///
    /// UIKit is iOS-only; on the macOS host (`swift test`) this whole file is excluded by
    /// `#if canImport(UIKit)` and is vacuous. The real RED/GREEN requires the iOS Simulator SDK.
    @MainActor
    final class FloatingLabelMenuFieldTests: XCTestCase {
        private func makeAppearance() -> ResolvedAppearance { .resolve(Appearance.default) }

        /// Before any selection the label rests (acts as the placeholder) and no value is shown.
        func test_labelRestsBeforeSelection() {
            let field = FloatingLabelMenuField(appearance: makeAppearance(), title: "Country")
            field.frame = CGRect(x: 0, y: 0, width: 240, height: 56)
            field.layoutIfNeeded()
            XCTAssertFalse(field.isLabelFloatedForTest)
            XCTAssertNil(field.valueTextForTest)
        }

        /// Selecting a value floats the label and shows the value text.
        func test_labelFloatsAndShowsValueAfterSelection() {
            let field = FloatingLabelMenuField(appearance: makeAppearance(), title: "Country")
            field.frame = CGRect(x: 0, y: 0, width: 240, height: 56)
            field.setSelected(title: "United States")
            field.layoutIfNeeded()
            XCTAssertTrue(field.isLabelFloatedForTest)
            XCTAssertEqual(field.valueTextForTest, "United States")
        }

        /// Clearing the selection drops the label back to resting and hides the value.
        func test_clearingSelectionReturnsToResting() {
            let field = FloatingLabelMenuField(appearance: makeAppearance(), title: "State")
            field.setSelected(title: "California")
            field.clearSelection()
            field.frame = CGRect(x: 0, y: 0, width: 240, height: 56)
            field.layoutIfNeeded()
            XCTAssertFalse(field.isLabelFloatedForTest)
            XCTAssertNil(field.valueTextForTest)
        }
    }
#endif
