# Sunbay Checkout iOS SDK — Product Spec (self-contained)

> Status: design finalized (ready for implementation planning)
> Date: 2026-10-26
> Scope: iOS native SDK, first release. Android and cross-platform (RN/Flutter) are separate repos.
> Audience: iOS SDK engineers / AI agents working **inside this repo**.
> This document is **self-contained**: it inlines all backend-contract, COF, and security context
> originally gathered from the `checkout` web repo, so no cross-repo access is required.
> Convention: identifiers/field names in English (external contract); explanatory prose in Chinese.

---

## 0. 背景

早期验证项目 `sunbay-pay-sdk`(「SDK 自带黑盒页 + 银行卡走嵌入式 WebView 托管页」)已废弃——
WebView 收卡实现复杂、UI 风格难与宿主一致、键盘体验难控制。

**本 SDK 采用纯 Native 方案**:银行卡表单原生化,砍掉「嵌入式 WebView 收卡 + bridge 适配」整条链路。
继承旧 demo 中质量较好的抽象(actor 协调器、五态结果、协议注入、最小货币单位);Apple Pay 真机探针
代码可借鉴。

首版实现 **L1(PaymentSheet 黑盒页)+ L3(ApplePayButton)**;**L2(EmbeddedPaymentElement)**预留 v2。
**COF(保存卡)是首期功能。**

---

## 1. 整体架构分层

三层 UI 形态(对齐 Stripe iOS 粗粒度模型,**不做**原子字段拆分),共享一个 UI 无关 Core。
架构一次规划到位,公开 API 按版本交付:首版 L1 + L3,L2 预留。

```
Host App (ISV)
  服务端创建 session → sessionId [+ customerAccessSecret] 经 HTTPS 交给 App
  → 调 SDK 公开入口 → 接收 CheckoutOutcome
        │ 公开 API(小而稳定,语义化版本)
        ▼
UI 壳层(可替换,按版本交付;不含业务逻辑)
  ┌ PaymentSheet [L1 首版] 全屏 VC, present(sessionId) → outcome
  ├ ApplePayButton [L3 首版] 独立钱包按钮(长期控件,事件用闭包)
  └ EmbeddedElement [L2 预留/v2] 宿主内嵌整块(将来需 delegate)
        │ 依赖 Core 接口(UI 不感知后端/加密细节)
        ▼
Core 层(UI 无关,纯逻辑,可单测)
  CheckoutController(actor,唯一编排者)
    · 会话生命周期 / 单活跃会话 / 状态机
    · 幂等(attemptId)/ 结果去重 / "提交失败先查询"
    · 可用方式 = session 授权 ∩ 设备能力
    ├ PaymentService(protocol, mock/real 可换):loadSession / submit / getResult
    ├ CardEncryptor:RSA 本地加密(唯一接触明文卡数据的边界)
    ├ WalletAuthorizer:PassKit → 钱包 token
    ├ CofService:列卡(直连 PSP, customerAccessSecret 鉴权)
    ├ ActionHandler:redirect / qrCode / showContent 分发
    └ CredentialStore:内存持有 secret,终态即清,绝不落盘/日志
  Models:Session / CheckoutOutcome(5态) / CheckoutError / Amount / SavedCard
```

### 三条核心原则

1. **Core 完全 UI 无关**。`CheckoutController` 不 import 任何 UIKit/PassKit UI 类型,只依赖协议。
   这是 L2 零返工扩展的根本保证。
2. **单一编排者**。三条支付路径(新卡 / Apple Pay / COF 历史卡)都经 `CheckoutController` 一个入口,
   共享状态机、幂等、去重、"失败先查询"。COF 不是独立链路,只是 `submit` 字段差异 + 一个列卡能力。
   避免按支付方式切 Handler 的过度抽象(旧 demo 的教训:WebView 那条线才是复杂度来源)。
3. **敏感数据边界内聚**。接触明文卡的只有 `CardEncryptor`,接触 secret 的只有 `CredentialStore`。

**依赖方向**(单向无环):`UI 壳 → CheckoutController → {PaymentService, CardEncryptor,
WalletAuthorizer, CofService, ActionHandler, CredentialStore} → Models`。壳之间、Core 服务之间互不依赖。

---

## 2. 公开 API 设计(首版 L1 + L3)

### 2.1 配置入口

```swift
public struct CheckoutConfiguration {
    /// Defaults to `.production`; pass `.dev` / `.test` only to target a non-production backend.
    public enum Environment { case dev, test, production }
    public let environment: Environment
    /// Apple Pay merchant id, host-provided. When nil, the id delivered by the
    /// session is used (two merchant-id models, same code path; host config wins).
    public let applePayMerchantId: String?
    public let appearance: Appearance?       // theme / colors / dark-light; CONSUMED by the UI layer
    public let locale: String?
    /// Card-on-file options (saved cards + "save this card"). Defaults to `CardOnFileOptions()`.
    public let cardOnFile: CardOnFileOptions

    public init(environment: Environment = .production, applePayMerchantId: String? = nil,
                appearance: Appearance? = nil, locale: String? = nil, paymentSheetTitle: String? = nil,
                cardOnFile: CardOnFileOptions = CardOnFileOptions(),
                paymentMethodFilter: PaymentMethodFilter = PaymentMethodFilter())
}

/// Hides and reorders payment methods. Identifiers are case-sensitive.
public struct PaymentMethodFilter: Sendable, Equatable {
    public var hide: [PaymentMethodID]
    public var order: [PaymentMethodID]
    public init(hide: [PaymentMethodID] = [], order: [PaymentMethodID] = [])
}

public struct CardOnFileOptions: Sendable, Equatable {
    /// Host switch. Defaults to `true`. Can only turn COF off, never on (see the rule below).
    public var isEnabled: Bool
    /// Initial state of the "save card" checkbox. Defaults to `false`. The user's checkbox at submit
    /// time, not this value, decides whether `storeCard: true` is sent.
    public var saveByDefault: Bool

    public init(isEnabled: Bool = true, saveByDefault: Bool = false)
}

// Note: saving a card needs a billing address (`payerBillingInfo`): collected by the sheet or passed by the host (see Address collection modes).

public final class SunbayCheckout {
    /// Builds the default HTTP services for the configured environment (the real backend).
    public init(configuration: CheckoutConfiguration)
    /// Non-fatal advisories and recovered errors (see "Diagnostics" below). Delivered on the main thread.
    public var onDiagnostic: ((CheckoutDiagnostic) -> Void)?
    /// Injects scripted services (examples, e2e, test support).
    public init(configuration: CheckoutConfiguration, paymentService: any PaymentService, cofService: any CofService, addressMetadataService: (any AddressMetadataService)? = nil)
}

// The host backend creates the session and returns sessionId + checkoutClientSecret
// (+ customerAccessSecret). Both secrets are held in memory only.
PaymentSheet(checkout:sessionId:customerAccessSecret:checkoutClientSecret:)
ApplePayButton(checkout:sessionId:...checkoutClientSecret:)
```

**Effective COF rule.** COF is active only when all three hold: the session allows it
(`supportStoreCard`, absent means `true`), `configuration.cardOnFile.isEnabled` is `true`, and the host
passed a non-nil `customerAccessSecret`. The host can never enable COF that the session disabled. When
COF is not effective: no `card/list` request, no saved-card UI, no save checkbox, and `storeCard` is never
sent.

**Payment method filter.** `PaymentMethodFilter` lets the host hide and reorder the session's payment methods.

- Identifiers are case-sensitive. Matching tries the logical key first (`CARD` covers every entry whose backend
  `type` is `CARD`, that is new card and saved cards; `APPLE_PAY`), then the raw backend method (for example
  `AMEX`). `PaymentMethodID` has `.card` and `.applePay` constants and is string-literal expressible.
- `hide` wins over `order`. `order` is stable: listed items come first in the listed order, unlisted items keep
  their original order after them. `order` never moves a group (the express group position comes from
  `Appearance.expressPosition`).
- `hide: ["CARD"]` hides the new-card row and the saved cards and skips the saved-card list request; Apple Pay
  stays.
- An identifier that matches nothing is ignored and reported once as `PAYMENT_METHOD_FILTER_IGNORED`; the filter
  never fails a payment because of a bad identifier.
- A provider is available iff the session has a matching entry, its static check passes and the filter did not
  hide it. If none is available, `PaymentSheet.present` returns `.failed` with code `NO_PAYMENT_METHOD_AVAILABLE`
  (category `.configuration`) before any UI is shown.

**Diagnostics.** `SunbayCheckout.onDiagnostic` delivers `CheckoutDiagnostic` events: `.warning(CheckoutWarning)`
(non-fatal advisories about host input) and `.error(CheckoutError, sessionId:)` (non-terminal errors the SDK
recovered from).

- Delivery is on the main thread, in order. Events raised before the handler is assigned are buffered (the last
  50 are kept, oldest dropped) and replayed in order on first assignment.
- Warning codes: `PAYMENT_METHOD_FILTER_IGNORED`, `ADDRESS_INCOMPLETE`, `ADDRESS_ENTRY_IGNORED`,
  `WALLET_PARAMS_INVALID`. A warning is deduplicated per code plus identifiers. `ignored` lists names only
  (`billingAddress`, `shippingAddress`, filter identifiers, `supportedNetworks`, `merchantCapabilities`), never
  values.
- Warnings never change a payment result and never appear on `CheckoutOutcome`. Terminal failures are returned
  as the outcome and are not mirrored as diagnostics. Diagnostics never contain card values, wallet tokens,
  secrets or address contents.

#### `Appearance`(Stripe 风格嵌套;UI 层已消费)

`Appearance` 不再是「只存不用」的惰性数据包:UI 层会把它解析为具体的 `UIColor`/`CGFloat`/`UIFont`
并注入每个组件(见 UI 重设计设计文档
`docs/superpowers/specs/2026-11-03-checkout-sdk-ui-redesign-design.md` §4)。整个类型置于
`#if canImport(UIKit)`,`CheckoutConfiguration.appearance` 相应 `#if` 包裹(Core 不消费外观)。

```swift
public struct Appearance: Sendable, Equatable {
    public static let `default` = Appearance()
    public init() {}

    public var colors: Colors = .init()
    public var font: Font = .init()
    public var primaryButton: PrimaryButton = .init()
    public var cornerRadius: CGFloat = 10
    public var borderWidth: CGFloat = 1              // 0 → borderless (hairline divider)
    public var shadow: Shadow = .none
    public var colorScheme: ColorScheme = .automatic // drives overrideUserInterfaceStyle (light/dark/follow-system)
    public var density: Density = .comfortable
    public var expressPosition: ExpressPosition = .top
    public var applePayButtonType: ApplePayButtonType = .plain   // wording on the Apple Pay button (PassKit renders and localizes it)
    public var billingAddressEnabled: Bool = true    // visibility follows the session's collectBillingAddress; false = never show the form
    public var shippingAddressEnabled: Bool = true   // same, for collectShippingAddress
    public var billingAddressStyle: AddressFormStyle = .simple   // form look when shown
    public var shippingAddressStyle: AddressFormStyle = .simple
    public var pageTransitionsEnabled: Bool = true // forward/back slide between in-sheet pages

    public enum ColorScheme: Sendable { case light, dark, automatic }
    public enum Density: Sendable { case comfortable, compact }
    public enum ExpressPosition: Sendable { case top, bottom, off }
    public enum AddressFormStyle: Sendable { case simple, full }

    public struct Colors: Sendable, Equatable {       // primary/background/componentBackground/text/
        public init() {}                              // textSecondary/border/danger/success,全部 UIColor?,
        public var primary: UIColor?                  // nil → 内置语义默认(含成对 light/dark 品牌色)
        public var background: UIColor?
        public var componentBackground: UIColor?
        public var text: UIColor?
        public var textSecondary: UIColor?
        public var border: UIColor?
        public var danger: UIColor?
        public var success: UIColor?
    }
    public struct Font: Sendable, Equatable {
        public init() {}
        public var base: UIFont?
        public var sizeScaleFactor: CGFloat = 1.0
    }
    public struct PrimaryButton: Sendable, Equatable {
        public init() {}
        public var backgroundColor: UIColor?          // nil → colors.primary
        public var textColor: UIColor?                // nil → white(对比度校验)
        public var cornerRadius: CGFloat?             // nil → 继承 Appearance.cornerRadius
    }
    public struct Shadow: Sendable, Equatable {
        public let color: UIColor; public let opacity: Float
        public let offset: CGSize; public let radius: CGFloat
        public static let none: Shadow
        public static let soft: Shadow
        public static let medium: Shadow
    }
}

/// Hex-oriented merchants: a public convenience `UIColor(sunbayHex:)`,容忍 `#RGB` / `#RRGGBB` /
/// `#RRGGBBAA`(`#` 可选、大小写不敏感),非法输入返回 `nil`(调用方决定回退)。
public extension UIColor { convenience init?(sunbayHex: String) }
```

- `Appearance.default` 即全默认构造;所有 `UIColor?` 为 `nil` 时走内置动态默认色(结构色用系统语义
  `.systemBackground`/`.label`/`.separator`,品牌/危险/成功用成对 light/dark 品牌 token)。
- `colorScheme` 驱动容器与内容根视图的 `overrideUserInterfaceStyle`(`.automatic`→跟随系统,
  `.light`/`.dark` 锁定),实现 dark/light/跟随系统。
- 这是相对旧「扁平 `String?` 外观」的破坏性重构,属发布前可接受,文档随之更新。

#### 页内状态机(in-sheet state machine)

PaymentSheet 不再把所有终态都「关页后才回传」:页内有一个可见状态机
`editing → processing →（succeeded | failed）`(详见 UI 设计文档 §3):

- `editing`——选方式/填表,完全可交互。
- `processing`——confirm 进行中,表单禁用、CTA 转圈、禁止下拉关闭。
- `succeeded`——CTA 环形→对勾动画,随后自动关闭(终态)。
- `failed(reason)`——CTA 上方红色内联告警块,页面保持打开可重试。
- `pending` / `unknown` **不是可见状态**:收到后回到 `editing`,通过中性信息条
  (`InlineNoticeView(.info)`)提示一行,不自动关闭;对账仍由宿主 `retrievePayment()` 负责。
- 字段级错误(卡号/有效期/CVC)不属于该状态机,是 `CardFormView` 自身的内部状态。

状态变化通过 `PaymentSheet.onStateChange` 暴露为公开的 `CheckoutPresentationState`(见 §2.2)。

#### 内容/容器分层(content/container split)

UI 层拆成两层,单向依赖 `Container → Content → Theme`:

- **Container 层**——「如何被托管」。首版 L1 为 `PaymentSheetContainerViewController`
  (English: custom bottom-sheet presentation on iPhone, built on `UIPresentationController`;
  `Appearance.sheetSizing` is honored on all iOS 15+ versions, with a hard `maxHeightFraction` cap;
  iPad / Mac / visionOS use the system form sheet. 自定义底部弹窗,不再依赖系统 `UISheetPresentationController`)。
- **Content 层**——host-agnostic、可复用的支付 UI(`CheckoutContentViewController` + 各组件),
  只通过 `CheckoutContentDelegate` 回报,不依赖容器。这正是 **L2 内嵌零返工**的接缝:将来加一个
  内嵌容器复用同一 Content 即可。

#### Address collection (visibility and style)

Two independent dimensions; the backend decides **whether** to collect, the host can only switch a form **off**:

- **Visibility** follows the checkout session. A form for a kind is shown iff the session collects that kind
  (`collectBillingAddress` / `collectShippingAddress`), the host has not disabled it
  (`Appearance.billingAddressEnabled` / `shippingAddressEnabled`, default `true`), and there is no usable host entry
  for it. The host cannot force a form on when the session does not ask for one. When disabled, the SDK shows
  nothing and uses the host-provided address, if any.
- **Style** is `Appearance.billingAddressStyle` / `shippingAddressStyle`:
  - `.simple` (default): country / line1 / postal code, plus first and last name when the form is a shipping form (names come from
    `AddressFormOptions.collectName`; billing has no names); phone is not shown in simple mode. Rendered by the same form as
    `.full` (`DynamicAddressFormView`): metadata-driven, with a per-country postal label and rule and the country
    list from `GET /api/address/country`. If metadata fails to load or is empty, it falls back to the system
    country list and a generic config (postal code required, no pattern).
  - `.full`: backend-layout-driven address form. Data comes from `AddressMetadataService`
    (Core/AddressMetadata, no UIKit); the default `SunbayCheckout(configuration:)` wires the real HPP adapter
    (`HTTPAddressMetadataService`: `GET /api/address/country` and `GET /api/address/country/{code}`).
    Shipping asks for first/last name, billing does not (like HPP).

Host-provided addresses: `PaymentSheet(... billingAddress:shippingAddress:)` and
`ApplePayButton(... billingAddress:shippingAddress:)` take an optional `AddressInput` each. Addresses are PII:
never logged, never returned in callbacks and never part of a diagnostic. The rules (aligned with the JS SDK):

- **Complete.** Billing needs non-blank `country`, `city`, `line1` and `postalCode`. Shipping needs those plus
  `firstName`, `lastName` and `phone`.
- **Usable host entry** for a kind: the session collects that kind and the sanitized entry is complete. If the
  session collects the kind and the entry is present but incomplete, it is not used and `ADDRESS_INCOMPLETE` is
  reported. If the session does not collect the kind, the entry is not used and `ADDRESS_INCOMPLETE` is not reported
  (but see `ADDRESS_ENTRY_IGNORED` below, which depends on the entry's presence only).
- **Draft.** A sanitized form value with at least one non-blank field other than `country` (the country
  pre-fill alone does not count).
- **New card, per kind.** A draft wins; if a host entry was also present (even when the session does not collect the kind), `ADDRESS_ENTRY_IGNORED` is reported.
  Otherwise the usable host entry is used.
- **Wallet (Apple Pay), per kind.** The address returned by the Apple Pay sheet; else (no form shown for that
  kind) the usable host entry. If a form is shown for the kind and a host entry is present, the entry is ignored for
  the wallet and `ADDRESS_ENTRY_IGNORED` is reported once, even when the wallet-returned contact wins.
- **Saved card.** Usable host entries only.
- **Postal-code validation.** A new-card submit is blocked when the postal code violates the country's
  `required` / `pattern`. Rules come only from backend config (except the local fallback used by simple mode when metadata is unavailable); if neither is present there is no validation.
  Patterns are matched against the whole trimmed value, and uncompilable patterns are ignored. Other address
  fields never block a submit (the backend decides). Saved-card and wallet paths are not gated, and
  host-provided addresses are not validated. A new-card submit is ignored while address metadata is still loading; it
  does not block when full-mode metadata failed to load, when the selected country has no postal-code field, or when the
  postal field is not rendered.
- **Failure reason.** `failureReason` on a failed result becomes `CheckoutError.message` under code
  `PAYMENT_FAILED`; a blank reason becomes the default "The payment failed."
- **Session loading.** `PaymentSheet` loads the session once per presentation. It is not reloaded between
  attempts; an expired session surfaces as a backend rejection shown inline.

Deferred: Google address autocomplete (a browser Maps key cannot be used from apps; options: an HPP proxy,
recommended; Google Places SDK for iOS with per-bundle keys; MapKit `MKLocalSearchCompleter`) and
postal-code to state lookup. The per-form name-field options are internal and not exposed.

### 2.2 L1 — 黑盒支付页 `PaymentSheet`

```swift
public final class PaymentSheet {
    public init(
        checkout: SunbayCheckout,
        sessionId: String,
        /// COF only; host backend delivers it over HTTPS. Memory-held, never logged.
        customerAccessSecret: String? = nil
    )
    @MainActor
    public func present(from presenter: UIViewController) async -> CheckoutOutcome
    /// Observe the in-sheet presentation state (see §2.1); default nil, does not change auto-close.
    public var onStateChange: ((CheckoutPresentationState) -> Void)?
    /// Query status independent of the UI (crash/kill recovery).
    public func retrievePayment() async throws -> PaymentSnapshot
}

/// The host-visible presentation state surfaced by `onStateChange` (maps the in-sheet state machine).
public enum CheckoutPresentationState: Sendable { case editing, processing, succeeded, failed }
```

- **COF 自动纳入**:传 `customerAccessSecret` 且 session `cofEnabled=true` → 页内自动显示已绑卡列表
  (选中已绑卡后点 Pay 即付 / select a saved card, then tap Pay to pay,零验证)+ 新卡可勾选保存。宿主零额外代码。COF 可用性裁决权在后端(`cofEnabled` 下发),
  客户端自动跟随,避免"客户端以为能用但后端拒绝"的错位。
- `present` 返回单次展示结果;`pending/unknown` 需配合 `retrievePayment` 或服务端 webhook 对账。

### 2.3 L3 — 独立 Apple Pay 按钮 `ApplePayButton`

```swift
public final class ApplePayButton: UIControl {
    public init(checkout: SunbayCheckout, sessionId: String,
                style: ApplePayButtonStyle = .automatic)
    /// Availability = backend-allowed ∩ device-capable ∩ merchant-id-configured.
    public var isAvailable: Bool { get }
    public var onAvailabilityChange: ((Bool) -> Void)?
    public var onResult: ((CheckoutOutcome) -> Void)?
}
```

长期存在的 UI 控件,事件用闭包(iOS 惯例);只用 Core 的 `WalletAuthorizer` + `CheckoutController`,
不碰卡表单。

### 2.4 结果与错误(公开类型,五态)

```swift
public enum CheckoutOutcome: Sendable {
    case succeeded(txnId: String)                 // server-confirmed terminal
    case failed(txnId: String?, error: CheckoutError)
    case canceled                                  // user dismissed; NOT a terminal txn
    case pending(txnId: String?)                   // keep querying
    case unknown(sessionId: String)                // network/timeout; must retrieve, never blind-retry
}

public struct CheckoutError: Error, Sendable {
    public let code: String          // stable code, not for display logic
    public let message: String       // display only
    public let category: Category    // configuration / validation / network / runtime / payment
    public let traceId: String?
    // never carries card values, wallet tokens, or raw backend payloads
}
```

### 2.5 事件返回方式

一次性流程用 async(`present`);持续事件源用闭包(`ApplePayButton`)。不教条统一(与 Stripe 一致)。

### 2.6 首版不导出(v2)

`EmbeddedPaymentElement` — L2,目录预留,首版不导出;将来需 delegate(高度/选项变化),架构已预留。

---

## 3. 三条支付路径数据流

全部经 `CheckoutController` 单一编排,共享尾部"提交 → 结果确认 → 四态去重"。

### 3.1 新卡支付(匿名,可选存卡)

```
Host → PaymentSheet.present(sessionId)
Controller → PaymentService.loadSession(sessionId)
          ← Session { rsaPublicKey, 可用方式, 金额(锁定), cofEnabled }
Controller → 校验 session 有效/未过期;可用方式 = 授权 ∩ 设备能力
UI → 渲染新卡表单(CardField:关纠错/关学习/CVV 不自动填充)
User → 输入卡号/有效期/CVV [可勾选"保存此卡"]
UI → Controller.confirmNewCard(cardInput, save?)
Controller → CardEncryptor.encrypt(card, rsaPublicKey)   # 明文仅此刻在内存
          → 立即清空表单与中间变量
Controller → 生成 attemptId(幂等键),单活跃锁
Controller → PaymentService.submit({ paymentMethod:"CARD", cardEncryptedData, sessionId,
                                     attemptId, storeCard?, checkoutClientSecret? })
          ├─ 成功响应 → map 四态(按 action 分发,见 §4.5)
          └─ 网络失败/超时 → 不重发, getResult(sessionId) 对账
Controller → 结果去重(sessionId+attemptId/txnId,终态只回调一次)
PaymentSheet → return Outcome
```

**Saving a card has no separate endpoint**: it is only a boolean option on the new-card payment,
`storeCard=true` (sent only when the session has `supportStoreCard`); the backend stores the card after a
successful payment. There is no consent object on the wire. Whether the backend requires a consent record is an
open item (see `docs/real-api-integration-checklist.md`).

### 3.2 Apple Pay(L1 页内 或 L3 独立按钮)

```
Controller → PaymentService.loadSession → 钱包参数 + merchantId(host 配置 > session 下发)
Controller → WalletAuthorizer.canMakePayments()   # 设备能力检测
UI → 仅 available 时显示 Apple Pay 按钮
User → 点击 → PassKit PKPaymentAuthorizationController(系统 sheet)
系统 → 授权 → PKPayment.token(加密钱包 token)
Controller → 生成 attemptId
Controller → PaymentService.submit({ paymentMethod:"APPLE_PAY", walletToken, sessionId, attemptId,
                                     checkoutClientSecret? })
          └─ 失败/超时 → getResult 对账
Controller → 四态去重 → Outcome
```

钱包授权成功 ≠ 交易成功;只有后端确认的终态才算。

**Apple Pay request rules.**

- Parameters come from the `APPLE_PAY` entry's `ewalletParam` (a JSON string holding an object, or an object).
  Only `countryCode`, `supportedNetworks` and `merchantCapabilities` are read; no other key is used. Parsing is
  tolerant: a malformed value never fails the session.
- `countryCode` is the non-blank backend value uppercased, else `US`. `currencyCode` and the amount come from
  the session. The summary label is the merchant name, else "Total".
- Networks are matched to PassKit constants case-insensitively; unknown names are dropped and duplicates
  removed. Capabilities `supports3DS`, `supportsEMV`, `supportsCredit` and `supportsDebit` are mapped; unknown
  names are dropped.
- Apple Pay is unavailable (the button/row is hidden and `WALLET_PARAMS_INVALID` is reported once, naming
  `supportedNetworks` and/or `merchantCapabilities`) when either list is empty after mapping, or when
  `ewalletParam` is absent.
- Contacts: the sheet requests a contact for a kind iff the session collects that kind and (there is no usable
  host entry for it, or a form for that kind is shown). Billing requests `postalAddress` and `name`; shipping
  requests `postalAddress`, `name` and `phoneNumber`. Returned contacts are submitted as returned (a shipping
  contact without phone or name is not rejected); `customerName` falls back to the address names and
  `customerEmail` is nil when the sheet returns none.

### 3.3 COF 历史卡快捷支付(首期,零验证)

```
Host → PaymentSheet.present(sessionId, customerAccessSecret)
Controller → CredentialStore.hold(customerAccessSecret)   # 仅内存
Controller → PaymentService.loadSession → Session{ cofEnabled=true }
Controller → CofService.listPaymentMethods(customerAccessSecret)  # 直连 PSP, Bearer
          ← [ SavedCard{ id(已绑定本 session), brand, last4, exp } ]   # 脱敏
UI → 渲染已绑卡列表(选卡后点 Pay 即付,无 CVC / 无 3DS)
User → 选卡 → 点 Pay → Controller.confirmSavedCard(paymentMethodId)
Controller → 生成 attemptId
Controller → PaymentService.submit({ paymentMethod:"TOKEN", savedCardId, customerAccessSecret,
                                     sessionId, attemptId, checkoutClientSecret? })
          ├─ 后端风控放行 → 四态
          └─ 后端风控要求 step-up → TxnStatus='R' → ActionHandler(首期无 step-up UI → pending)
Controller → 成功 → 清 CredentialStore → Outcome(失败/unknown 保留凭证以便重试)
```

- 列卡返回的 `paymentMethodId` 在后端已凭 `customerAccessSecret` 绑定本 session + Customer,
  选卡 → submit **不需额外绑定参数**。
- `paymentMethodId` 是**临时、交易级**引用(绑 session/customer/固定金额),非长期可复用扣款凭证。

**三条路径共性**:单活跃会话、一次点击一个 attemptId、提交失败先查询不盲目重发、终态去重只回调一次、
成功/dismiss/过期才清凭证(失败/unknown 保留,供宿主可见的重试,ruling R7)。

---

## 4. 状态机与生命周期

### 4.1 主状态机

```
idle → loadingSession → ready → authorizing → submitting → 终态
         │(失败)          │(选方式/填卡/选卡) │(PassKit/加密)
         ▼                │                  ▼
      loadFailed          │             confirmed?
      (invalidSession/    │          ┌──────┴──────┐
       networkUnavailable)│          ▼             ▼
           用户随时可关闭 → canceled  succeeded(S)  failed(F)
                                     pending(I)    unknown
                                     requiresAction(R → ActionHandler)
```

- **服务端确认终态**:`succeeded(S)` / `failed(F)`——不可逆,只回调一次。
- **非终态**:`pending(I)` / `requiresAction(R)`——需 `retrievePayment` 继续查。
- **UI 终态但非交易终态**:`canceled`(只关 UI)、`unknown`(网络中断)——都不能据此判断未扣款,必须查询。

### 4.2 并发与幂等不变量(Core 强制,actor 串行化)

| 不变量 | 规则 |
|---|---|
| 单活跃会话 | 一个实例同时只允许一个 checkout;第二次 → alreadyPresenting,不新建 attempt |
| 一次点击一个 attemptId | 同一次点击只生成一个幂等键;重复点击被单活跃锁挡 |
| 提交失败先查询 | submit 失败/超时 → 绝不盲目重发 → getResult 对账 |
| 结果去重 | 以 sessionId + attemptId/txnId 识别,终态只回调一次 |
| 成功/关闭/过期清凭证 | 支付成功/UI 关闭/session 过期 → 清 CredentialStore;失败/unknown 保留以便重试 |

载体:`actor CheckoutController`,Swift actor 天然串行化,无需手写锁。

### 4.3 App 生命周期(纯 Native 特有)

| 事件 | 行为 |
|---|---|
| 进后台 | The SDK does not poll; nothing to stop. The in-flight attempt keeps its attemptId |
| 回前台 | If an attempt was in flight, the SDK makes at most one `getResult` query, then reports `unknown`; the host reconciles via `retrievePayment` / webhook |
| App 被杀→重启 | UI 会话丢失;宿主用 retrievePayment(sessionId) 恢复。**不持久化任何敏感数据**;仅非敏感 sessionId 由宿主自存 |
| Polling | None. The SDK never client-polls: a non-terminal result is `pending`; a lost response gets one query, then `unknown` |

### 4.4 No client polling

The SDK has no polling parameters. A non-terminal submit result maps to `pending`; after a lost response the SDK
queries once, then reports `unknown` (never `failed`). The host reconciles via `retrievePayment` / webhook.

### 4.5 ActionHandler:`requiresAction`(R) 按类型分发

| action.type | 行为 | 首版 |
|---|---|---|
| `redirect`(第三方 APM 跳转,如支付宝 web;**非 3DS 专属**,场景少) | 用系统 `ASWebAuthenticationSession`(带 returnUrl 回跳)打开支付页 → pending → the host confirms the final state via `retrievePayment` / webhook (no SDK polling) | **实现** |
| `qrCode` / `showContent` | failed(UNSUPPORTED_CAPABILITY),不静默 | 不实现 |
| 未知类型 | failed(UNSUPPORTED_CAPABILITY) | — |

**边界澄清**:砍掉的是"嵌入式 WebView 加载 Sunbay 托管页收卡"。这里 `redirect` 是"打开第三方 APM
支付网页",用系统安全浏览器打开,不接触卡数据,属标准做法,不违背安全大方向。

**三端对齐现状**(Sunbay 产品线):`redirect` 全线实现;`qrCode`/`showContent` 全线为协议预留、运行时
UNSUPPORTED_CAPABILITY。iOS 首版遵循同一策略,不超前实现二维码。

---

## 5. 安全约束(摘要;完整见 `docs/security-and-pci.md`)

1. 明文卡只存在于卡输入控件 + CardEncryptor 加密前瞬时变量,加密后立即清零(边界内聚)。
2. PAN/CVV/有效期关 autocorrection + spellChecking + smart 系列;**CVV 不设 textContentType**;
   PAN 可用系统扫卡/自动填充(Apple 官方安全通道)。
3. 零持久化:明文卡、钱包 token、customerAccessSecret、checkoutClientSecret、paymentMethodId 一律不写
   UserDefaults/文件/Keychain/剪贴板;只内存持有,终态即清。
4. 零日志泄漏:敏感字段绝不进 print/os_log/埋点/崩溃上报;CheckoutError 只带 code/message/traceId。
5. TLS 强制;SSL pinning 后期可选。防截屏后期可选(仅卡输入页)。
6. customerAccessSecret 短 TTL(建议 5–10 分钟且不晚于 session)+ 内存 + 终态即撤。

**COF 零验证**:客户明确要求"选卡零验证快捷支付"。可接受的前提是双层临时凭证
(customerAccessSecret 短 TTL + paymentMethodId 绑 session/customer/固定金额)把残余风险从"任意金额
盗刷"收窄到"本笔固定订单可能被代付/重放",再由幂等键 + 终态即撤压缩。**不焊死"永不验证"**:预留
requires_action 路径,后端风控需要时触发 step-up,无需改客户端。

---

## 6. 版本路线图 + 目录结构

### 6.1 版本路线图

| 版本 | 范围 |
|---|---|
| v0.x(首版) | L1 PaymentSheet + L3 ApplePayButton + COF 快捷支付(零验证) + 新卡 RSA 加密 + redirect action;mock 示例 App + Apple Pay 真机探针;Core 协议解耦 |
| 真实后端联调 | 接口 ready 后替换 mock 适配器;沙箱端到端;锁定支持矩阵/包名/最低 OS |
| v1.0 | 公开 API 冻结;合规说明材料;发布门槛验收 |
| v1.x(后期) | L2 EmbeddedPaymentElement(minor,非破坏) |
| 后期可选 | 3DS/CVC step-up、qrCode/showContent、卡输入页防截屏、SSL pinning、越狱检测(协议/路径已预留) |

语义化版本:加 L2 = minor,不破坏现有接口;Core 从第一天 UI 无关 → L2 零返工。

### 6.2 目录结构

```
checkout-sdk-native/ios/
├── Package.swift                      # SPM 入口(按 git tag 分发)
├── README.md / AGENTS.md              # English
├── docs/
│   ├── product-spec.md                # 本文件(自包含完整设计)
│   └── security-and-pci.md            # 安全合规
├── Sources/SunbayCheckout/
│   ├── Public/                        # SunbayCheckout / CheckoutConfiguration / CheckoutOutcome / CheckoutError
│   ├── UI/
│   │   ├── Theme/                      # ResolvedAppearance / ColorHex / AppearanceDefaults
│   │   ├── Content/                    # CheckoutContentViewController + delegate + state
│   │   │   └── Components/             # CardFormView / SavedCardList / ExpressCheckout / ConfirmButton /
│   │   │                               #   InlineNotice / DynamicAddressForm / Footer / SheetHeader
│   │   ├── Container/                  # PaymentSheetContainerViewController (L1 bottom sheet)
│   │   ├── PaymentSheet/               # L1 public entry [首版]
│   │   ├── Wallet/                     # L3 ApplePayButton [首版]
│   │   ├── CardField/                  # CardFieldSecurity(PCI 键盘/自动填充硬化,保留复用)
│   │   └── Embedded/                   # L2 [预留,首版空占位]
│   ├── Core/
│   │   ├── CheckoutController.swift    # actor 编排 + 状态机
│   │   ├── PaymentService.swift        # protocol (mock/real)
│   │   ├── CofService.swift            # 列卡(直连 PSP)
│   │   ├── CardEncryptor.swift         # RSA 本地加密(明文边界)
│   │   ├── WalletAuthorizer.swift      # PassKit
│   │   ├── ActionHandler.swift         # redirect/qrCode 分发
│   │   ├── CredentialStore.swift       # 内存持有 secret,终态即清
│   │   ├── AddressMetadata/            # AddressMetadataService 协议 + 模型 + cache + HTTP 适配器(无 UIKit;本阶段未接真实数据)
│   │   ├── Localization/               # i18n subsystem [见 §9]
│   │   └── Models/
│   └── Resources/Localizations/        # {en,zh-Hans}.lproj/Localizable.strings
├── Sources/SunbayCheckoutTestSupport/ # public-API-only shared doubles (e2e + Example) [见 §9]
├── Tests/
│   ├── SunbayCheckoutTests/           # XCTest:状态机/加密/幂等/恢复
│   └── SunbayCheckoutE2ETests/        # protocol-driven e2e (host, swift test) [见 §9]
└── Example/
    ├── SunbayCheckoutDemo/            # Tuist-generated App (Project.swift + Sources/ checked in)
    └── ApplePayProbe/                 # Apple Pay 真机探针
```

---

## 7. Backend contract (verified live against dev for the core payment path)

> Core payment path (load session, submit, result) is implemented by `HTTPPaymentService` over the
> internal `SunbayAPIClient` and verified against dev. Saved-card list and other items remain a mock
> baseline behind `CofService`. Open items: `docs/real-api-integration-checklist.md` §2.
> Hosts: dev `https://checkout.sunbay-dev.com`, test `https://checkout.sunbay-uat.us`, production
> `https://checkout.sunbay.us`; routes under `/api/checkout/web/...`. Envelope `{code,msg,data,traceId}`;
> success is `code == "0"` (string).

### 7.1 Load session

`POST /api/checkout/web/session/{sessionId}` with the `checkoutClientSecret` in the body. Key fields:

```
Session {
  sessionId, currency,
  totalAmount,      // decimal STRING in MAJOR units; so are the other amount fields,
                    // including productList[].amount and productList[].num (also strings)
  expiresAt,        // "yyyy-MM-dd HH:mm:ss" in UTC
  collectBillingAddress, collectShippingAddress,
  paymentMethods: [{ method, type, name, logoUrl }],  // CARD logos feed the card-number field icons
  merchantName, merchantLogoUrl,
  rsaPublicKey,     // Base64, per session; used to encrypt card data
  supportStoreCard? // absent => true; false forces saved cards off
}
```

- The SDK converts amount strings to minor units by the currency's fraction digits.
- The backend response still carries the legacy `storeCard` and not yet `supportStoreCard` (rename
  pending). The SDK reads only `supportStoreCard`; absent means `true`.
- Session creation is the host backend's job: open API `create-session` with `sessionType: "sdk"` and
  `customerId` returns `sessionId`, `checkoutClientSecret` (`ccs_`) and `customerAccessSecret` (`cas_`).

### 7.2 卡数据 RSA 本地加密(复刻 web `encryptCardData`,逻辑完全内联)

明文结构(含时间戳,防重放):

```jsonc
{ "cardNumber": "...", "expiryMonth": "..", "expiryYear": "....",
  "cvv": "...", "timeStamp": "<Date.now() 毫秒字符串>" }
```

加密步骤(与 web 一致,iOS 侧用 Security framework 实现等价逻辑):
1. 组装上面的 payload(timeStamp 实时生成,结果不可缓存复用)。
2. JSON 序列化。
3. 用 session 下发的 `rsaPublicKey`(Base64)做 RSA 加密;**明文超过单块长度时分块加密,密文拼接为
   单个合法 base64**(兼容 RSA-1024 / 2048;web 用 JSEncryptLong 的 encryptLong,iOS 需实现等价分块)。
4. 结果作为 `cardEncryptedData` 提交。

- 后端校验时间戳约 5 分钟误差。
- **padding 等细节待后端确认**(web 的 JSEncrypt 默认 PKCS#1 v1.5);iOS `SecKeyCreateEncryptedData`
  需选用与后端解密一致的算法(如 `.rsaEncryptionPKCS1`)。**这是必须与后端对齐的点,实现前确认。**

### 7.3 Submit payment

`POST /api/checkout/web/payment/submit`. The public `SubmitRequest` (obsolete `paymentMethodId`,
`savePaymentMethod` and `Consent` were removed):

```swift
SubmitRequest(
    sessionId, paymentMethod,       // "CARD" / "APPLE_PAY" / "TOKEN" (saved card)
    attemptId,                      // SDK-local in-flight guard only; not sent
    cardEncryptedData,              // new card ciphertext (§7.2)
    walletToken,                    // Apple Pay token; sent in cardEncryptedData
    savedCardId,                    // with paymentMethod "TOKEN"
    storeCard,                      // save this payment's card
    customerAccessSecret,           // saved-card path
    checkoutClientSecret
)
```

- `storeCard: true` requires `payerBillingInfo` in the body; without it the backend rejects the submit with `C01`.
- Address mapping: the body carries `payerBillingInfo` and `payerShippingAddress`, each an `AddressInfo` with
  keys `country, state, city, address, address2, postalCode, firstName, lastName, phone, email`
  (`line1` -> `address`, `line2` -> `address2`; `district` is not sent). Empty or whitespace-only values are
  omitted, and an address with no remaining field is omitted entirely. Which value is
  used per kind is decided by the address rules in §2.1.
- Shipping has its own form with first name, last name and phone; there is no "same as billing" option (the
  checkbox was removed when the JS-aligned address rules landed). Product follow-up: a partial "same as billing"
  (copy the address fields, still collect shipping name and phone) can be restored if product wants it; it is
  tracked in `docs/real-api-integration-checklist.md`.
- Which address is submitted per payment path follows the rules in "Address collection modes" (§2.1): per kind a
  draft form value or the usable host entry for a card, the wallet's returned address (else the usable host
  entry) for Apple Pay, usable host entries only for a saved card.
- The body also carries an optional `userDeviceInfo` (see `security-and-pci.md` §4.1).
- Apple Pay: the body carries `digitalWalletInfo: { applePay: { merchantIdentifier } }` with the merchant id the
  token was authorized with (`PKPaymentRequest.merchantIdentifier`, i.e. host `applePayMerchantId` first, then the
  session). It is sent only for `APPLE_PAY` and omitted when blank. `docs/api/checkout-api.json` marks it optional
  and "not consumed by decryption yet", but the dev backend rejects an Apple Pay submit without it
  (`merchantIdentifier is required`), so the SDK always sends it.
- A 5xx or lost response is ambiguous: at most one result query, then `unknown`. A non-network business
  error is a definite failure. The SDK never blindly resubmits.
- Open: Apple Pay token wire format, `paymentMethod` for new cards (`CARD` vs brand), whether submit
  needs `sessionType`.

### 7.4 Payment result

`POST /api/checkout/web/payment/result/{sessionId}` returns `txnId`, `txnStatus`, `sessionId`,
`totalAmount`, `currency`, optional `failureReason`, `resultUrl` and `action`. `txnStatus` is `S`, `F` or
`R` only; there is no `I`. Mapping: `S` succeeded, `F` failed (only from an explicit `F`), `R` with a known
action goes to `ActionHandler` (§4.5), `R` with an unknown action or an undetermined result is
pending/unknown, resolved by the host via `retrievePayment` / webhook.

### 7.5 List saved cards (COF)

Verified live against dev (2026-11-09). `POST /api/checkout/web/card/list`, JSON body:

```jsonc
{ "sessionId": "<sessionId>", "customerAccessSecret": "cas_..." }
```

The standard envelope applies; on success `data` is:

```jsonc
{ "cards": [ { "savedCardId": "sc_...", "maskedCardNumber": "**** **** **** 4242",
               "cardBrand": "visa", "expiryMonth": "12", "expiryYear": "29",
               "cardholderName": "..." } ] }
```

Field mapping to `SavedCard`: `savedCardId` -> `id` (the value passed to `confirmSavedCard(paymentMethodId:)`),
`cardBrand` -> `brand` (lower-case), last four digits of `maskedCardNumber` -> `last4`, `expiryMonth` ->
`expMonth`, `expiryYear` (two digits expanded to four) -> `expYear`. `cardholderName` is not displayed.
An item with an invalid required field is skipped. `data: {}` and `cards: []` both mean no saved cards.

Errors (HTTP 200 with a business code): a wrong secret returns `S06` (Unauthorized); a missing secret
returns `C16`. The scope is derived from the credentials; the client never sends a customer id.

Listing never blocks payment: any failure (network, `S06`, decoding) degrades to "no saved cards" and is
never surfaced as a payment error. The secret never appears in logs or errors.

### 7.6 COF 凭证与授权模型(完整内联)

**双凭证**:

| 凭证 | 持有者 | 能做什么 | 绝不能做 |
|---|---|---|---|
| `checkoutClientSecret` | 前端/SDK(EMBED/SDK session) | 支付当前订单、读 session、用新卡付 | 不能列/用历史卡;HPP 不签发 |
| `customerAccessSecret`(Customer Grant) | 前端/SDK(仅 COF) | 按 scopes 列/用/存历史卡 | 跨 Customer / 跨 merchant / 换 session 一律拒 |

- 两者由商户后端经**已认证用户的 HTTPS 响应体**交给 App,**从不进 URL**;SDK 仅内存持有。
- `mode`:`HPP`(默认/现状,不支持 COF)/ `EMBED`(Web SDK)/ **`SDK`(Native,本 SDK)**。
- scopes:`payment_methods:list` / `:use` / `:save`(`:remove` 首期不发给支付 SDK)。
- Grant 与 `(merchant, customer, checkoutSession, scopes, mode)` 强绑定;短 TTL(建议 5–10 分钟,不晚于
  session);终态即撤。
- **凭证发放方式甲/乙对 SDK 透明**:商户后端负责(甲=create-session + 独立 customer-grants;乙=
  create-session 内联)。SDK 只接收最终 `sessionId` + `customerAccessSecret`,不感知甲/乙。
- **用历史卡的交易级校验(后端责任)**:卡归属该 Customer、固定订单金额、幂等键、风控。按 COF 既有
  威胁模型,用历史卡本应触发交易级二次认证(3DS/CVC);**本 SDK 首期按客户要求零验证,依靠后端风控 +
  双层临时凭证兜底**(见 §5 与 security-and-pci.md)。

### 7.7 错误码(映射后端 {code,msg,data,traceId};code==='0' 为成功)

建议(后端在现有体系内分配):`CHECKOUT_EXPIRED`、`CUSTOMER_GRANT_EXPIRED`、
`CUSTOMER_GRANT_REVOKED`、`PAYMENT_METHOD_NOT_OWNED`、`PAYMENT_METHOD_NOT_ALLOWED`、
`CONSENT_REQUIRED`、`PAYMENT_REQUIRES_ACTION`、`ORDER_ALREADY_PAID`、`COF_NOT_ALLOWED_FOR_MODE`、
`UNSUPPORTED_CAPABILITY`。

---

## 8. 待确认项(P0 优先,实施中持续对齐后端)

1. [P0] RSA 加密 **padding / 算法**与后端解密一致(§7.2)——**写 CardEncryptor 前必须确认**。
2. [P0] Apple Pay merchant ID 两种模式的证书/网关对应。
3. [P0] Native session 鉴权、attemptId/幂等契约、结果查询/服务端通知。
   - Backend-contract TBD (reconciliation gate): `PaymentSnapshot` is SESSION-level and carries no
     attemptId. The Core reconciliation gate (`CheckoutController.resolveReconciled`) therefore trusts a
     terminal `F` as the verdict of the LATEST attempt. ASSUMPTION to confirm with the backend: "a new
     attempt moves the session off a previous `F`, and `getResult` reflects the latest attempt". If the
     backend can keep returning an older attempt's `F`, the SDK could release the gate (and allow a
     resubmit) while a newer attempt is still live.
4. [P0] COF 历史卡交易风控覆盖 + paymentMethodId 交易级校验(零验证前提)。
5. [P0] 目标 SAQ 档位向收单行/QSA 确认。
6. [P1] 钱包 token 提交字段格式(复用 cardEncryptedData 还是单列)。
7. [P1] customerAccessSecret 的 TTL / 撤销 / 单次语义。
8. [P1] 最终 API URL / 鉴权头 / 字段映射(web 的 line1→address 之类是否沿用)。
9. [P2] 目标市场地区性合规(数据驻留等)。

---

## 9. Localization (i18n), Example app, and test structure

> This section is written in English per `AGENTS.md`. Full design:
> `docs/superpowers/specs/2026-10-27-ios-i18n-demo-e2e-design.md`.

### 9.1 Localization subsystem

The localization code lives in `Sources/SunbayCheckout/Core/Localization/`, with string resources in
`Sources/SunbayCheckout/Resources/Localizations/{en,zh-Hans}.lproj/Localizable.strings`. v1 ships
**en-US** and **zh-CN** (Simplified Chinese).

Components:

- `SunbayLocalizedString` — a lookup helper over `Bundle.module`.
- `LocalizationResolver` — the resolution chain, highest priority first: explicit
  `CheckoutConfiguration.locale` → session language (reserved; no v1 data source) → system language →
  `en-US` default.
- `AmountFormatter` — locale-aware currency formatting via `NumberFormatter`, with currency-derived
  fraction digits.
- `CheckoutError.localizedDisplayMessage(using:)` — maps a stable error `code` to
  `sunbay.error.<lowercased-code>`, falling back to the developer-supplied `message` when no localized
  string exists.

**Public BCP-47 codes vs internal `.lproj` names.** The public API uses BCP-47 region form (`en-US`,
`zh-CN`), aligned with hpp/jssdk. Internally these map to Apple `.lproj` directory names
(`en-US → en`, `zh-CN → zh-Hans`). Errors localize **client-side from the code** (with the
developer-message fallback above); amounts format via `Locale`.

### 9.2 Recorded future extensions (not in v1)

- **More languages:** one `.lproj` + one resolver map entry each (e.g. `zh-TW → zh-Hant`).
- **Host-supplied / full custom languages:** a future `SunbayLocalizedString` could consult a
  host-supplied string table before falling back to the SDK's bundled strings, with that first
  (host) tier exposed as public API. v1 does not implement this tier — today `SunbayLocalizedString`
  is a single bundle lookup. This is a reserved extension point.
- **Decision-A PaymentSheet UI driver seam:** for in-sheet-branch e2e coverage.
- **Localized-layout snapshot tests.**

### 9.3 Three-layer example/test structure

- **Example app** (`Example/SunbayCheckoutDemo/`) — a Tuist-generated Xcode app (`Project.swift` +
  `Sources/` checked in; the generated project is git-ignored) with a configuration playground
  (environment, locale, currency/amount, methods, COF, scenario). It is the customer reference surface
  and the UI localization gate. `Example/ApplePayProbe/` remains the standalone PassKit probe.
- **`SunbayCheckoutTestSupport`** (`Sources/SunbayCheckoutTestSupport/`) — a public-API-only library target
  (`ScriptablePaymentService`, `ScriptableCofService`, `DemoSessionFactory`, `DemoRSAKey`) providing
  shared doubles for both the e2e target and the Example app.
- **e2e target** (`Tests/SunbayCheckoutE2ETests/`) — protocol-driven automation with `@testable`
  controller access, no UIKit, runs on the host via `swift test`. Covers the five outcomes,
  idempotency / single-active, query-first-on-failure, COF-disabled, and localization assertions.
