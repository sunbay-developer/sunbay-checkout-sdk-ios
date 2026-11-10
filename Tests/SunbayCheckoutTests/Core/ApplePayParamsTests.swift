import XCTest

@testable import SunbayCheckout

final class ApplePayParamsTests: XCTestCase {
    private func parse(_ json: String) -> ApplePayParams? {
        ApplePayParams.parse(Data(json.utf8))
    }

    func test_parse_readsAllThreeKeys() {
        let params = parse(
            #"{"countryCode":"GB","supportedNetworks":["visa","amex"],"merchantCapabilities":["supports3DS"]}"#)
        XCTAssertEqual(
            params,
            ApplePayParams(
                countryCode: "GB", supportedNetworks: ["visa", "amex"], merchantCapabilities: ["supports3DS"]))
    }

    func test_parse_ignoresExtraKeys() {
        let params = parse(
            #"{"supportedNetworks":["visa"],"merchantCapabilities":["supports3DS"],"merchantId":"merchant.x","other":1}"#)
        XCTAssertEqual(
            params,
            ApplePayParams(countryCode: nil, supportedNetworks: ["visa"], merchantCapabilities: ["supports3DS"]))
    }

    func test_parse_invalidOrNonObject_isNil() {
        XCTAssertNil(parse("not json"))
        XCTAssertNil(parse(#"["visa"]"#))
        XCTAssertNil(parse(#""text""#))
        XCTAssertNil(ApplePayParams.parse(nil))
    }

    func test_parse_dropsNonStringElements() {
        let params = parse(#"{"supportedNetworks":["visa",7,null,{"a":1},"amex"],"merchantCapabilities":["supports3DS"]}"#)
        XCTAssertEqual(params?.supportedNetworks, ["visa", "amex"])
    }

    func test_parse_emptyArraysKept_wrongTypesBecomeEmpty() {
        let empty = parse(#"{"supportedNetworks":[],"merchantCapabilities":[]}"#)
        XCTAssertEqual(empty, ApplePayParams(countryCode: nil, supportedNetworks: [], merchantCapabilities: []))
        let wrong = parse(#"{"countryCode":5,"supportedNetworks":"visa","merchantCapabilities":{"a":1}}"#)
        XCTAssertEqual(wrong, ApplePayParams(countryCode: nil, supportedNetworks: [], merchantCapabilities: []))
    }
}
