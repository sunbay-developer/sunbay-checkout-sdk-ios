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
        "sunbay.sheet.saveThisCardHint",
        "sunbay.sheet.applePay",
        "sunbay.sheet.cancel",
        "sunbay.sheet.newCard",
        "sunbay.sheet.savedCards",
        // Card form
        "sunbay.card.informationTitle",
        "sunbay.card.number",
        "sunbay.card.expiry",
        "sunbay.card.cvc",
        "sunbay.card.cvc.titleFormat",
        "sunbay.card.invalid",
        "sunbay.card.error.numberEmpty",
        "sunbay.card.error.numberIncomplete",
        "sunbay.card.error.numberInvalid",
        "sunbay.card.error.expiryEmpty",
        "sunbay.card.error.expiryIncomplete",
        "sunbay.card.error.expiryMonthInvalid",
        "sunbay.card.error.expiryPast",
        "sunbay.card.error.cvcEmpty",
        "sunbay.card.error.cvcIncomplete",
        "sunbay.card.scan",
        "sunbay.card.scan.hint",
        "sunbay.card.scan.tip",
        "sunbay.card.scan.light",
        // Address
        "sunbay.address.billingTitle",
        "sunbay.address.shippingTitle",
        "sunbay.address.country",
        "sunbay.address.line1",
        "sunbay.address.postalCode",
        "sunbay.address.phone",
        "sunbay.address.error.requiredFormat",
        "sunbay.address.loadError",
        // COF
        "sunbay.cof.newPaymentMethod",
        "sunbay.cof.viewMore",
        // Common / state
        "sunbay.common.retry",
        "sunbay.notice.reconciling"
    ]
}
