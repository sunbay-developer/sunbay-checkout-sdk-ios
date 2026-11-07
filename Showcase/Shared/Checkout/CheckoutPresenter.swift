import Foundation
import SunbayCheckout
import UIKit

/// The result of one presented checkout: the SDK outcome plus the presentation states observed.
struct PaymentResult {
    let outcome: CheckoutOutcome
    let states: [CheckoutPresentationState]
}

/// Presents the SDK `PaymentSheet` on the frontmost view controller using the public API only.
@MainActor
final class CheckoutPresenter: ObservableObject {
    @Published private(set) var isPresenting = false

    static let defaultMerchantId = "merchant.native.com.sunbay.dev"
    /// Merchant id baked into Info.plist (`ShowcaseMerchantId`) from the generate-time override.
    static var bundleMerchantId: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "ShowcaseMerchantId") as? String
        return (value?.isEmpty == false ? value : nil) ?? defaultMerchantId
    }
    private static let sessionId = "showcase_session_001"
    private static let customerAccessSecret = "demo_secret"

    /// Pure configuration builder (no UI), kept separate so it is unit-testable.
    nonisolated static func makeConfiguration(
        theme: ThemeStore,
        language: ShowcaseLanguage,
        systemIsDark: Bool,
        merchantId: String = CheckoutPresenter.defaultMerchantId
    ) -> CheckoutConfiguration {
        CheckoutConfiguration(
            environment: .dev,
            applePayMerchantId: merchantId,
            appearance: theme.appearance(systemIsDark: systemIsDark),
            locale: language.localeCode
        )
    }

    /// Presents the sheet. Returns `nil` if a presentation is already in flight or no presenter is found.
    func pay(
        amountMinor: Int64,
        theme: ThemeStore,
        language: LanguageStore,
        systemIsDark: Bool
    ) async -> PaymentResult? {
        guard !isPresenting, let presenter = Self.topViewController() else { return nil }
        isPresenting = true
        defer { isPresenting = false }

        let configuration = Self.makeConfiguration(
            theme: theme,
            language: language.language,
            systemIsDark: systemIsDark,
            merchantId: Self.bundleMerchantId
        )
        let checkout = SunbayCheckout(
            configuration: configuration,
            paymentService: ShowcasePaymentService(amountMinor: amountMinor, sessionId: Self.sessionId),
            cofService: ShowcaseCofService()
        )
        let sheet = PaymentSheet(
            checkout: checkout,
            sessionId: Self.sessionId,
            customerAccessSecret: Self.customerAccessSecret
        )
        var states: [CheckoutPresentationState] = []
        sheet.onStateChange = { states.append($0) }
        let outcome = await sheet.present(from: presenter)
        return PaymentResult(outcome: outcome, states: states)
    }

    /// Frontmost view controller of the key window, walking `presentedViewController`.
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
            ?? scenes.first as? UIWindowScene
        guard var top = windowScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? windowScene?.windows.first?.rootViewController
        else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
