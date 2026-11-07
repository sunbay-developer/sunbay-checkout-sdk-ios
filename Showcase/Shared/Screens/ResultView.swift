import SwiftUI

struct ResultView: View {
    let order: OrderSnapshot
    let popToShop: () -> Void

    @EnvironmentObject private var cart: CartStore
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var lang: LanguageStore

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72))
                    .foregroundColor(theme.primary)
                    .padding(.top, 24)
                VStack(spacing: 4) {
                    Text(lang.t("result.state.succeeded")).font(.title2.weight(.bold))
                    Text(lang.t("result.thanks")).font(.subheadline).foregroundColor(.secondary)
                }
                VStack(spacing: 12) {
                    row(lang.t("result.orderNumber"), order.orderNumber, id: "orderNumber")
                    Divider()
                    row(lang.t("result.amount"), formatUSD(minor: order.amountMinor), id: "orderAmount")
                }
                .padding(16)
                .background(card)

                VStack(alignment: .leading, spacing: 8) {
                    Text(lang.t("result.callback")).font(.footnote.weight(.semibold)).foregroundColor(.secondary)
                    Text(order.callbackLine)
                        .font(.system(.footnote, design: .monospaced))
                        .accessibilityIdentifier("callbackLine")
                    Text(order.statesLine.isEmpty ? "-" : order.statesLine)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("callbackStates")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(card)

                Button {
                    cart.clear()
                    popToShop()
                } label: {
                    Text(lang.t("action.continueShopping"))
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                                .fill(theme.primary)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("continueButton")
            }
            .padding(16)
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(lang.t("result.title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: theme.cornerRadius + 6, style: .continuous)
            .fill(Color(UIColor.secondarySystemGroupedBackground))
    }

    private func row(_ title: String, _ value: String, id: String) -> some View {
        HStack {
            Text(title).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.body.weight(.semibold)).accessibilityIdentifier(id)
        }
    }
}
