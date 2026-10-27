#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// CardField 安全规格单测(security-and-pci.md §3 item 2 / §3.1,product-spec §5.3.1)。
    ///
    /// UIKit 仅 iOS 可用。`swift test` 在 macOS 宿主上构建时本文件整体被
    /// `#if canImport(UIKit)` 排除,既不编译也不运行;真正的 RED/GREEN 需对
    /// iOS Simulator SDK 构建(见任务报告)。真机验证由示例 App(Task 13)覆盖。
    final class CardFieldSecurityTests: XCTestCase {
        func test_cardFieldSecurity_disablesKeyboardLearning_andCVVHasNoContentType() {
            let pan = UITextField()
            let exp = UITextField()
            let cvv = UITextField()
            CardFieldSecurity.apply(toPAN: pan, expiry: exp, cvv: cvv)
            for f in [pan, exp, cvv] {
                XCTAssertEqual(f.autocorrectionType, .no)
                XCTAssertEqual(f.spellCheckingType, .no)
                XCTAssertEqual(f.smartDashesType, .no)
            }
            XCTAssertEqual(pan.textContentType, .creditCardNumber)
            XCTAssertNil(cvv.textContentType)  // CVV 绝不进自动填充
            XCTAssertEqual(pan.keyboardType, .asciiCapableNumberPad)
        }
    }
#endif
