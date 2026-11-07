import SwiftUI

struct RootView: View {
    @StateObject private var cart = CartStore()
    @StateObject private var theme = ThemeStore()
    @StateObject private var lang = LanguageStore()
    @StateObject private var presenter = CheckoutPresenter()

    var body: some View {
        NavigationView {
            ShopView()
        }
        .navigationViewStyle(.stack)
        .environmentObject(cart)
        .environmentObject(theme)
        .environmentObject(lang)
        .environmentObject(presenter)
        .preferredColorScheme(theme.swiftUIScheme)
        .accentColor(theme.primary)
    }
}
