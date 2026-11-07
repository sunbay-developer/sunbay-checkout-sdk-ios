import SwiftUI

/// Product list with a cart button (badge) and a settings gear.
struct ShopView: View {
    @EnvironmentObject private var cart: CartStore
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var lang: LanguageStore

    @State private var showCart = false
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Catalog.products) { product in
                    ProductRow(product: product)
                }
            }
            .padding(16)
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(lang.t("app.title"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityIdentifier("settingsButton")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCart = true } label: {
                    CartBadgeIcon(count: cart.itemCount)
                }
                .accessibilityIdentifier("cartButton")
            }
        }
        .background(
            NavigationLink(isActive: $showCart) {
                CartView(popToShop: { showCart = false })
            } label: { EmptyView() }
            .hidden()
        )
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(theme)
                .environmentObject(lang)
        }
    }
}

private struct CartBadgeIcon: View {
    let count: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "cart")
                .padding(.trailing, count > 0 ? 8 : 0)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.red))
                    .offset(x: 4, y: -6)
            }
        }
        .accessibilityLabel("Cart, \(count)")
    }
}

/// Rounded tinted square with an SF Symbol.
struct ProductArtwork: View {
    let symbol: String
    var size: CGFloat = 56
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        RoundedRectangle(cornerRadius: theme.cornerRadius + 4, style: .continuous)
            .fill(theme.primary.opacity(0.14))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundColor(theme.primary)
            )
    }
}

private struct ProductRow: View {
    let product: Product
    @EnvironmentObject private var cart: CartStore
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var lang: LanguageStore

    var body: some View {
        HStack(spacing: 14) {
            ProductArtwork(symbol: product.symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(lang.t(product.nameKey))
                    .font(.headline)
                Text(formatUSD(minor: product.priceMinor))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button { cart.add(product) } label: {
                Text(lang.t("action.add"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                            .fill(theme.primary)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("add-\(product.id)")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: theme.cornerRadius + 6, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
    }
}
