#if DEBUG
import XCTest
@testable import SunbayCheckout

final class NetworkDebugLoggerTests: XCTestCase {
    func testEnabledOnlyForDevWithLaunchArgument() {
        let args = ["app", NetworkDebugLogger.launchArgument]
        XCTAssertTrue(NetworkDebugLogger.isEnabled(environment: .dev, arguments: args))
        XCTAssertFalse(NetworkDebugLogger.isEnabled(environment: .dev, arguments: ["app"]))
        XCTAssertFalse(NetworkDebugLogger.isEnabled(environment: .test, arguments: args))
        XCTAssertFalse(NetworkDebugLogger.isEnabled(environment: .production, arguments: args))
    }

    func testRedactsSensitiveKeysAtAnyDepth() {
        let body = Data("""
        {"sessionId":"s1","cardEncryptedData":"AAA","nested":{"customerAccessSecret":"BBB","items":[{"walletToken":"CCC","ok":1}]}}
        """.utf8)
        let text = NetworkDebugLogger.describeBody(body)
        XCTAssertTrue(text.contains("s1"))
        for secret in ["AAA", "BBB", "CCC"] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertTrue(text.contains(NetworkDebugLogger.redactedPlaceholder))
    }

    func testNonJSONBodyIsNeverPrinted() {
        let text = NetworkDebugLogger.describeBody(Data("card=4111".utf8))
        XCTAssertFalse(text.contains("4111"))
    }

    func testRedactsSensitiveHeaders() {
        let headers = NetworkDebugLogger.redactHeaders(["Authorization": "Bearer x", "Accept": "application/json"])
        XCTAssertEqual(headers["Authorization"], NetworkDebugLogger.redactedPlaceholder)
        XCTAssertEqual(headers["Accept"], "application/json")
    }
}
#endif
