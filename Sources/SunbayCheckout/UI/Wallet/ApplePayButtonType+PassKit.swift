#if canImport(PassKit) && canImport(UIKit)
    import PassKit

    extension ApplePayButtonType {
        /// The PassKit button type that renders this wording (all cases exist since iOS 14).
        var pkType: PKPaymentButtonType {
            switch self {
            case .plain: return .plain
            case .buy: return .buy
            case .setUp: return .setUp
            case .inStore: return .inStore
            case .donate: return .donate
            case .checkout: return .checkout
            case .book: return .book
            case .subscribe: return .subscribe
            case .reload: return .reload
            case .addMoney: return .addMoney
            case .topUp: return .topUp
            case .order: return .order
            case .rent: return .rent
            case .support: return .support
            case .contribute: return .contribute
            case .tip: return .tip
            }
        }
    }
#endif
