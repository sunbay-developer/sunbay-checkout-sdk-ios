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
        .tint(theme.primary)
        // Window-level override (see `WindowAppearance`) so presented sheets follow the mode too.
        .onAppear { WindowAppearance.applyToApp(theme.mode.userInterfaceStyle) }
        .onChange(of: theme.mode) { WindowAppearance.applyToApp($0.userInterfaceStyle) }
    }
}
