import Foundation

/// The canonical set of UI string keys the SDK's checkout UI references.
///
/// Every key here must have an entry in both the `en` and `zh-Hans`
/// `Localizable.strings` tables; `LocalizationKeyCoverageTests` enforces this.
/// The list is plain strings only (no UIKit), so it compiles and runs on the
/// host under `swift test`.
enum SunbayUIStringKeys {
    static let all: [String] = [
        // Sheet structure
        "sunbay.sheet.payTitle",
        "sunbay.sheet.payAmount",
        "sunbay.sheet.pay",
        "sunbay.sheet.orPayUsing",
        "sunbay.sheet.poweredBy",
        "sunbay.sheet.back",
        "sunbay.sheet.close",
        "sunbay.sheet.saveThisCard",
        "sunbay.sheet.applePay",
        "sunbay.sheet.cancel",
        "sunbay.sheet.newCard",
        "sunbay.sheet.savedCards",
        // Card form
        "sunbay.card.number",
        "sunbay.card.expiry",
        "sunbay.card.cvc",
        "sunbay.card.invalid",
        // Address
        "sunbay.address.billingTitle",
        "sunbay.address.shippingTitle",
        "sunbay.address.sameAsBilling",
        "sunbay.address.country",
        "sunbay.address.line1",
        "sunbay.address.postalCode",
        "sunbay.address.loadError",
        // COF
        "sunbay.cof.newPaymentMethod",
        // Common / state
        "sunbay.common.retry",
        "sunbay.notice.pending"
    ]
}
