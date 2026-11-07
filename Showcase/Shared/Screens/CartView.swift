import SwiftUI

/// What the Result screen needs; captured before the cart is cleared.
struct OrderSnapshot {
    let orderNumber: String
    let amountMinor: Int64
    let callbackLine: String
    let statesLine: String
}

struct CartView: View {
    let popToShop: () -> Void

    @EnvironmentObject private var cart: CartStore
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var lang: LanguageStore
    @EnvironmentObject private var presenter: CheckoutPresenter
    @Environment(\.colorScheme) private var colorScheme

    @State private var snapshot: OrderSnapshot?
    @State private var showResult = false
    @State private var messageKey: String?

    var body: some View {
        VStack(spacing: 0) {
            if cart.isEmpty {
                Spacer()
                Image(systemName: "cart")
                    .font(.system(size: 44))
                    .foregroundColor(.secondary)
                Text(lang.t("cart.empty"))
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(cart.lines, id: \.0.id) { product, quantity in
                            CartLine(product: product, quantity: quantity)
                        }
                    }
                    .padding(16)
                }
            }
            footer
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(lang.t("cart.title"))
        .navigationBarTitleDisplayMode(.inline)
        .background(
            NavigationLink(isActive: $showResult) {
                if let snapshot {
                    ResultView(order: snapshot, popToShop: popToShop)
                }
            } label: { EmptyView() }
            .hidden()
        )
    }

    private var footer: some View {
        VStack(spacing: 12) {
            HStack {
                Text(lang.t("cart.total")).font(.headline)
                Spacer()
                Text(formatUSD(minor: cart.totalMinor))
                    .font(.title3.weight(.bold))
                    .accessibilityIdentifier("cartTotal")
            }
            Text(lang.t("cart.testCardHint"))
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let key = messageKey {
                Text(lang.t(key))
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("paymentMessage")
            }
            Button { Task { await pay() } } label: {
                Text(lang.t("action.pay"))
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                            .fill(theme.primary.opacity(payDisabled ? 0.4 : 1))
                    )
            }
            .buttonStyle(.plain)
            .disabled(payDisabled)
            .accessibilityIdentifier("payButton")
        }
        .padding(16)
        .background(
            Color(UIColor.secondarySystemGroupedBackground).ignoresSafeArea(edges: .bottom)
        )
    }

    private var payDisabled: Bool { cart.isEmpty || presenter.isPresenting }

    private func pay() async {
        messageKey = nil
        let amount = cart.totalMinor
        guard let result = await presenter.pay(
            amountMinor: amount,
            theme: theme,
            language: lang,
            systemIsDark: colorScheme == .dark
        ) else { return }

        switch result.outcome {
        case .succeeded(let txnId):
            snapshot = OrderSnapshot(
                orderNumber: CartStore.makeOrderNumber(),
                amountMinor: amount,
                callbackLine: "succeeded(txnId: \(txnId))",
                statesLine: result.states.map { "\($0)" }.joined(separator: " -> ")
            )
            showResult = true
        case .canceled:
            messageKey = "payment.canceled"
        case .failed:
            messageKey = "payment.failed"
        case .pending:
            messageKey = "result.state.pending"
        case .unknown:
            messageKey = "result.state.unknown"
        }
    }
}

private struct CartLine: View {
    let product: Product
    let quantity: Int
    @EnvironmentObject private var cart: CartStore
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var lang: LanguageStore

    var body: some View {
        HStack(spacing: 12) {
            ProductArtwork(symbol: product.symbol, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(lang.t(product.nameKey)).font(.subheadline.weight(.semibold))
                Text(formatUSD(minor: product.priceMinor * Int64(quantity)))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Stepper(
                value: Binding(
                    get: { quantity },
                    set: { cart.setQuantity(product, $0) }
                ),
                in: 0...99
            ) {
                Text("\(quantity)")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .fixedSize()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: theme.cornerRadius + 6, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
    }
}
