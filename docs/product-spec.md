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
    public enum Environment { case test, production }
    public let environment: Environment
    /// Apple Pay merchant id, host-provided. When nil, the id delivered by the
    /// session is used (two merchant-id models, same code path; host config wins).
    public let applePayMerchantId: String?
    public let appearance: Appearance?       // theme / color scheme
    public let locale: String?
}

public final class SunbayCheckout {
    public init(configuration: CheckoutConfiguration)
}
```

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
    /// Query status independent of the UI (crash/kill recovery).
    public func retrievePayment() async throws -> PaymentSnapshot
}
```

- **COF 自动纳入**:传 `customerAccessSecret` 且 session `cofEnabled=true` → 页内自动显示已绑卡列表
  (选卡即付,零验证)+ 新卡可勾选保存。宿主零额外代码。COF 可用性裁决权在后端(`cofEnabled` 下发),
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
UI → Controller.confirmNewCard(cardInput, save?, consent?)
Controller → CardEncryptor.encrypt(card, rsaPublicKey)   # 明文仅此刻在内存
          → 立即清空表单与中间变量
Controller → 生成 attemptId(幂等键),单活跃锁
Controller → PaymentService.submit({ cardEncryptedData, sessionId, attemptId,
                                     savePaymentMethod?, consent? })
          ├─ 成功响应 → map 四态(按 action 分发,见 §4.5)
          └─ 网络失败/超时 → 不重发, getResult(sessionId) 对账
Controller → 结果去重(sessionId+attemptId/txnId,终态只回调一次)
PaymentSheet → return Outcome
```

**存卡无独立接口**:仅作为新卡支付的布尔选项 `savePaymentMethod=true` + `consent{version,
futureUsage:'ON_SESSION'}`,支付成功后由后端保存(Phase 1 无 SetupIntent 式独立绑卡)。

### 3.2 Apple Pay(L1 页内 或 L3 独立按钮)

```
Controller → PaymentService.loadSession → 钱包参数 + merchantId(host 配置 > session 下发)
Controller → WalletAuthorizer.canMakePayments()   # 设备能力检测
UI → 仅 available 时显示 Apple Pay 按钮
User → 点击 → PassKit PKPaymentAuthorizationController(系统 sheet)
系统 → 授权 → PKPayment.token(加密钱包 token)
Controller → 生成 attemptId
Controller → PaymentService.submit({ walletToken, sessionId, attemptId })  # 字段待后端确认
          └─ 失败/超时 → getResult 对账
Controller → 四态去重 → Outcome
```

钱包授权成功 ≠ 交易成功;只有后端确认的终态才算。

### 3.3 COF 历史卡快捷支付(首期,零验证)

```
Host → PaymentSheet.present(sessionId, customerAccessSecret)
Controller → CredentialStore.hold(customerAccessSecret)   # 仅内存
Controller → PaymentService.loadSession → Session{ cofEnabled=true }
Controller → CofService.listPaymentMethods(customerAccessSecret)  # 直连 PSP, Bearer
          ← [ SavedCard{ id(已绑定本 session), brand, last4, exp } ]   # 脱敏
UI → 渲染已绑卡列表(选卡即付,无 CVC / 无 3DS)
User → 选卡 → Controller.confirmSavedCard(paymentMethodId)
Controller → 生成 attemptId
Controller → PaymentService.submit({ paymentMethodId, sessionId, attemptId })
          ├─ 后端风控放行 → 四态
          └─ 后端风控要求 step-up → TxnStatus='R' → ActionHandler(首期无 step-up UI → pending)
Controller → 终态 → 清 CredentialStore → Outcome
```

- 列卡返回的 `paymentMethodId` 在后端已凭 `customerAccessSecret` 绑定本 session + Customer,
  选卡 → submit **不需额外绑定参数**。
- `paymentMethodId` 是**临时、交易级**引用(绑 session/customer/固定金额),非长期可复用扣款凭证。

**三条路径共性**:单活跃会话、一次点击一个 attemptId、提交失败先查询不盲目重发、终态去重只回调一次、
终态即清凭证。

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
| 终态即清凭证 | 终态/UI 关闭/session 过期 → 清 CredentialStore |

载体:`actor CheckoutController`,Swift actor 天然串行化,无需手写锁。

### 4.3 App 生命周期(纯 Native 特有)

| 事件 | 行为 |
|---|---|
| 进后台 | 停止 UI 轮询;不丢失 attemptId |
| 回前台 | 若 submitting/pending → 先 getResult 对账再决定 UI |
| App 被杀→重启 | UI 会话丢失;宿主用 retrievePayment(sessionId) 恢复。**不持久化任何敏感数据**;仅非敏感 sessionId 由宿主自存 |
| 轮询 | 有上限 + 退避;达上限 → unknown |

### 4.4 轮询默认参数(可配置,后端 ready 后微调)

初始 1s → 退避至最大 5s;总上限 ~90s 或 N 次;达上限 → unknown(非失败);进后台暂停,回前台先对账。

### 4.5 ActionHandler:`requiresAction`(R) 按类型分发

| action.type | 行为 | 首版 |
|---|---|---|
| `redirect`(第三方 APM 跳转,如支付宝 web;**非 3DS 专属**,场景少) | 用系统 `ASWebAuthenticationSession`(带 returnUrl 回跳)打开支付页 → pending → 轮询/回跳确认终态 | **实现** |
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
│   │   ├── PaymentSheet/               # L1 [首版]
│   │   ├── Wallet/                     # L3 ApplePayButton [首版]
│   │   ├── CardField/                  # 卡输入控件 + 安全规格
│   │   └── Embedded/                   # L2 [预留,首版空占位]
│   ├── Core/
│   │   ├── CheckoutController.swift    # actor 编排 + 状态机
│   │   ├── PaymentService.swift        # protocol (mock/real)
│   │   ├── CofService.swift            # 列卡(直连 PSP)
│   │   ├── CardEncryptor.swift         # RSA 本地加密(明文边界)
│   │   ├── WalletAuthorizer.swift      # PassKit
│   │   ├── ActionHandler.swift         # redirect/qrCode 分发
│   │   ├── CredentialStore.swift       # 内存持有 secret,终态即清
│   │   ├── Localization/               # i18n subsystem [见 §9]
│   │   └── Models/
│   └── Resources/Localizations/        # {en,zh-Hans}.lproj/Localizable.strings
├── Sources/SunbayCheckoutMocks/       # public-API-only shared doubles (e2e + Example) [见 §9]
├── Tests/
│   ├── SunbayCheckoutTests/           # XCTest:状态机/加密/幂等/恢复
│   └── SunbayCheckoutE2ETests/        # protocol-driven e2e (host, swift test) [见 §9]
└── Example/
    ├── SunbayCheckoutDemo/            # Tuist-generated App (Project.swift + Sources/ checked in)
    └── ApplePayProbe/                 # Apple Pay 真机探针
```

---

## 7. 后端契约对齐基线(内联;源自现有 web 行为,SDK 正式契约待后端确认)

> 这是 mock 建模依据。真实接口 ready 后只替换 `PaymentService`/`CofService` 适配器实现,不动 Core/UI。
> 现有 web 的具体路径(如 `/checkout/web/...`)仅作参考,Native 的最终 URL/鉴权/错误码由后端评审确定。

### 7.1 加载会话

现有 web 行为:`POST /checkout/web/session/{sessionId}` → Session。关键字段(内联自 web 类型):

```
Session {
  sessionId, sessionType, currency, totalAmount,
  productList: [{ amount, name, num }],
  taxAmount, productAmount, surchargeAmount?, tipAmount?,
  description, expiresAt (ISO 8601),
  collectBillingAddress, collectShippingAddress,
  paymentMethods: [{ method, type, name, logoUrl, ewalletParam? }],
  merchantName, merchantLogoUrl, merchantReturnUrl?,
  rsaPublicKey?,        // Base64 RSA public key, used to encrypt card data
  cofEnabled            // COF 新增:mode∈{EMBED,SDK} 且有有效 Grant 时 true
}
PaymentMethod.method 例:'VISA' | 'AMEX' | 'MASTERCARD' | 'GOOGLE_PAY' | 'APPLE_PAY'
PaymentMethod.type   例:'CARD' | 'E_WALLET' | 'APM'
```

- 金额使用最小货币单位(整数),避免浮点舍入。

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

### 7.3 提交支付

现有 web 行为:`POST /checkout/web/payment/submit`。请求(内联自 web `SubmitPaymentReq` + COF 扩展):

```jsonc
{
  "sessionId": "...", "sessionType": "...",
  "paymentMethod": "...",               // 'VISA' / 'APPLE_PAY' / ...
  "customerEmail": "...?", "customerName": "...?",
  "payerBillingInfo": { ... }?,         // AddressInfo
  "payerShippingAddress": { ... }?,
  "userDeviceInfo": { ... }?,
  "cardEncryptedData": "...?",          // 卡密文(§7.2);钱包 tokenizationData 现状也复用此字段

  // ---- COF 扩展(见 §7.6) ----
  "paymentMethodId": "...?",            // 用历史卡(与 savePaymentMethod 互斥)
  "savePaymentMethod": true?,           // 用新卡时请求保存
  "consent": { "version": "...", "futureUsage": "ON_SESSION" }?  // save 时必填
}
AddressInfo { country, state?, city, line1, line2?, postalCode, district?,
              firstName?, lastName?, recipientName?, phone? }
```

> 注:web 侧提交时把地址 `line1/line2` 转成 `address/address2`。Native 的字段映射以后端最终契约为准。
> 钱包 token 提交字段(复用 cardEncryptedData 还是单列)待后端确认(P1)。

### 7.4 查询结果

现有 web 行为:`POST /checkout/web/payment/result/{sessionId}` → PaymentResult:

```jsonc
{
  "txnId": "...", "txnStatus": "I|S|F|R",
  "sessionId": "...", "totalAmount": 0, "currency": "...",
  "failureReason": "...?", "resultUrl": "...?",
  "action": {                           // txnStatus='R' 时携带
    "type": "redirect|qrCode|showContent",
    "redirectUrl": "...?",
    "qrData": { "qrCode": "...", "qrUrl": "..." }?,
    "content": { ... }?
  }?
}
```

**四态映射**:`S → succeeded` / `F → failed` / `I → pending` / `R → requiresAction`
(ActionHandler 按 `action.type` 分发,见 §4.5)。

### 7.5 列卡(COF)

现有设计(web 尚为新增接口,路径占位):`GET .../customer/payment-methods`,
`Authorization: Bearer <customerAccessSecret>`,`X-Checkout-Session: <sessionId>`。直连 PSP,商户后端
不经手卡数据。返回:

```jsonc
[ { "id": "pm_123", "type": "card", "brand": "visa",
    "last4": "4242", "expMonth": 12, "expYear": 2029, "allowRedisplay": true } ]
```

- `id`(= paymentMethodId)是**对外引用/临时 token,非真 token**,且已绑定本 session + Customer。
- 作用域**从凭证推导**,不接受客户端 customerId 参数。未授权返回 **403**,不得用空列表掩盖。

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
- **`SunbayCheckoutMocks`** (`Sources/SunbayCheckoutMocks/`) — a public-API-only library target
  (`ScriptablePaymentService`, `ScriptableCofService`, `DemoSessionFactory`, `DemoRSAKey`) providing
  shared doubles for both the e2e target and the Example app.
- **e2e target** (`Tests/SunbayCheckoutE2ETests/`) — protocol-driven automation with `@testable`
  controller access, no UIKit, runs on the host via `swift test`. Covers the five outcomes,
  idempotency / single-active, query-first-on-failure, COF-disabled, and localization assertions.
