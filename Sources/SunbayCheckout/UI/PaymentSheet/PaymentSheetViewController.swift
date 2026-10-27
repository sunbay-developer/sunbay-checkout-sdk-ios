#if canImport(UIKit)
    import UIKit

    /// `PaymentSheet` 的内部渲染层（product-spec §2.2）。
    ///
    /// ## 职责边界
    /// 一个最小但真实的模态 `UIViewController`，按已加载 session 与（COF 判定后）已列出的 saved cards
    /// 渲染可用支付方式，并把用户选择经 `onAction` 回报给 `PaymentSheet`：
    /// - **已保存卡列表**（当 `savedCards` 非空）：每张一行，点击 → `.confirmSavedCard(paymentMethodId:)`。
    /// - **新卡表单**（`CardField`，Task 10）+ 一个「保存此卡」开关：点击「支付」→
    ///   `.confirmNewCard(cardInput, save: toggle.isOn)`（开关驱动 save + consent）。
    /// - **Apple Pay 选项**（当 session `.methods` 含 `.applePay`）：此处仅渲染入口；真实钱包授权
    ///   由 L3 `ApplePayButton` 承担，本页的 Apple Pay 行回报 `.cancel` 占位（示例 app/Task 13 接线真实授权）。
    /// - **取消**：导航栏取消按钮 → `.cancel`。
    ///
    /// 本 VC **不持业务规则、不加密、不记录/持久化**任何卡数据：`CardField.cardInput` 承载的明文只
    /// 原样转交 `PaymentSheet`（再由 `CheckoutController.confirmNewCard` 内 `CardEncryptor` 加密），
    /// 用后即弃（§5 / AGENTS.md §2）。
    ///
    /// internal：不对外暴露；完整 UI 由示例 app（Task 13）验证。仅 iOS 可用（`#if canImport(UIKit)`）。
    final class PaymentSheetViewController: UIViewController {
        /// 用户完成一次选择时回调（在主线程）。携带 `PaymentSheet.UserAction`。恰好调用一次。
        var onAction: ((PaymentSheet.UserAction) -> Void)?

        // MARK: - 渲染输入

        private let session: CheckoutSession
        private let savedCards: [SavedCard]

        // MARK: - 子视图

        private let scrollView = UIScrollView()
        private let contentStack = UIStackView()
        private let cardField = CardField()
        private let saveCardSwitch = UISwitch()

        /// 防重入：onAction 只触发一次（终态由 PaymentSheet 收起本页）。
        private var didReportAction = false

        /// 创建支付页 VC。
        ///
        /// - Parameters:
        ///   - session: 已加载并校验未过期的会话（用于渲染商户/金额/可用方式）。
        ///   - savedCards: 已列出的已保存卡（COF 不可用时为空）。
        init(session: CheckoutSession, savedCards: [SavedCard]) {
            self.session = session
            self.savedCards = savedCards
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            // 语义主题色：跟随浅/深色方案，不硬编码固定色（AGENTS.md §5.4 同理）。
            view.backgroundColor = .systemBackground
            buildLayout()
        }

        // MARK: - 布局

        private func buildLayout() {
            // 取消入口（顶部）。
            let cancelButton = UIButton(type: .system)
            cancelButton.setTitle("Cancel", for: .normal)
            cancelButton.addTarget(self, action: #selector(handleCancel), for: .touchUpInside)

            // 商户 / 金额抬头。
            let title = UILabel()
            title.text = session.merchantName
            title.font = .preferredFont(forTextStyle: .headline)
            title.textColor = .label

            scrollView.translatesAutoresizingMaskIntoConstraints = false
            contentStack.axis = .vertical
            contentStack.spacing = 16
            contentStack.translatesAutoresizingMaskIntoConstraints = false

            view.addSubview(scrollView)
            scrollView.addSubview(contentStack)
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
                contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
                contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
                contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
            ])

            contentStack.addArrangedSubview(cancelButton)
            contentStack.addArrangedSubview(title)

            // 已保存卡列表（COF；仅当有卡）。
            if !savedCards.isEmpty {
                let header = sectionLabel("Saved cards")
                contentStack.addArrangedSubview(header)
                for card in savedCards {
                    contentStack.addArrangedSubview(savedCardRow(card))
                }
                contentStack.addArrangedSubview(separator())
            }

            // 新卡表单。
            contentStack.addArrangedSubview(sectionLabel("New card"))
            cardField.translatesAutoresizingMaskIntoConstraints = false
            contentStack.addArrangedSubview(cardField)

            // 「保存此卡」开关（驱动 save + consent）。
            let saveRow = UIStackView()
            saveRow.axis = .horizontal
            saveRow.spacing = 8
            let saveLabel = UILabel()
            saveLabel.text = "Save this card"
            saveLabel.textColor = .label
            saveRow.addArrangedSubview(saveLabel)
            saveRow.addArrangedSubview(saveCardSwitch)
            contentStack.addArrangedSubview(saveRow)

            // 新卡「支付」按钮。
            let payButton = UIButton(type: .system)
            payButton.setTitle("Pay", for: .normal)
            payButton.addTarget(self, action: #selector(handlePayNewCard), for: .touchUpInside)
            contentStack.addArrangedSubview(payButton)

            // Apple Pay 选项（当后端允许）。真实授权由 L3 ApplePayButton 承担（见类型说明）。
            if session.methods.contains(.applePay) {
                contentStack.addArrangedSubview(separator())
                let applePayButton = UIButton(type: .system)
                applePayButton.setTitle("Apple Pay", for: .normal)
                applePayButton.addTarget(self, action: #selector(handleApplePay), for: .touchUpInside)
                contentStack.addArrangedSubview(applePayButton)
            }
        }

        private func sectionLabel(_ text: String) -> UILabel {
            let label = UILabel()
            label.text = text
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = .secondaryLabel
            return label
        }

        private func separator() -> UIView {
            let line = UIView()
            line.backgroundColor = .separator
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            return line
        }

        /// 构造一行已保存卡（点击 → confirmSavedCard）。用 tag 携带下标以定位卡。
        private func savedCardRow(_ card: SavedCard) -> UIButton {
            let button = UIButton(type: .system)
            button.contentHorizontalAlignment = .leading
            button.setTitle("\(card.brand) •••• \(card.last4)", for: .normal)
            if let index = savedCards.firstIndex(where: { $0.id == card.id }) {
                button.tag = index
            }
            button.addTarget(self, action: #selector(handleSavedCardTap(_:)), for: .touchUpInside)
            return button
        }

        // MARK: - 动作

        @objc private func handleCancel() {
            report(.cancel)
        }

        @objc private func handleSavedCardTap(_ sender: UIButton) {
            guard savedCards.indices.contains(sender.tag) else { return }
            report(.confirmSavedCard(paymentMethodId: savedCards[sender.tag].id))
        }

        @objc private func handlePayNewCard() {
            // 字段不齐全 → 不发起（最小校验由 CardField 承担）；保持页面可继续编辑。
            guard let input = cardField.cardInput else { return }
            report(.confirmNewCard(input, save: saveCardSwitch.isOn))
        }

        @objc private func handleApplePay() {
            // 本页只渲染入口；真实 PassKit 授权由 L3 ApplePayButton 承担。占位回报 cancel，
            // 示例 app（Task 13）接线真实授权后改为 .confirmWallet(token:)。
            report(.cancel)
        }

        /// 回报一次用户动作（只触发一次）。
        private func report(_ action: PaymentSheet.UserAction) {
            guard !didReportAction else { return }
            didReportAction = true
            onAction?(action)
        }
    }
#endif
