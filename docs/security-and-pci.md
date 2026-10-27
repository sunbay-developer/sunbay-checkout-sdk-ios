# Sunbay Checkout iOS SDK — Security & PCI (self-contained)

> Status: discussion draft (feeds a dedicated security review meeting)
> Date: 2026-10-26
> Scope: Native SDK security & PCI compliance — **unified, platform-agnostic**. iOS and Android
> share one set of security & compliance requirements; building iOS first is only a development-focus
> choice, not a narrowing of security scope. Implementation APIs differ per platform; requirements do not.
> Nature: engineering judgment + discussion agenda. **Not a compliance commitment.** PCI level is
> determined by the acquirer / QSA.
> Self-contained: all context is inlined; no cross-repo access required.

---

## 0. 一句话结论

> 从 WebView 托管页改为**纯 Native 收卡**后,明文卡号/CVV 会**短暂进入宿主 App 进程内存**(即便只在
> SDK 内、即便立即加密)。这**不阻断集成**,但会把客户 PCI 评估档位从最轻的 **SAQ A** 上移到更重的档位
> (接近 SAQ A-EP 心智)。SDK 通过"接触面最小化 + 边界内聚 + 证据可留痕"创造较轻评估条件,但**最终档位
> 由收单行 / QSA 裁定,不可由我方承诺**。需会议拍板的是第 6 节决策待办。

---

## 1. 合规态势:改方案前后对比

| 维度 | 原 WebView 托管页(已放弃) | 纯 Native + SDK 内收卡(现方案) |
|---|---|---|
| 明文卡数据在哪 | 只在 Sunbay 托管页,宿主进程碰不到 | 宿主 App 进程内存(卡输入控件 + 加密前瞬时) |
| 加密发生在哪 | 托管页 JS 内 | SDK 内(CardEncryptor) |
| 客户代码能否接触卡数据 | 否 | 否(卡值不出 SDK 公开 API)——但卡数据在客户进程里出现过 |
| 客户 PCI 范围 | 最小(约 SAQ A) | 扩大(比 SAQ A 重,接近 SAQ A-EP 心智) |
| 主要攻击面 | WebView origin / bridge | App 内存、键盘缓存、剪贴板、截屏、日志、崩溃上报 |

放弃 WebView 换来 UI 一致性、键盘体验、维护简单;代价即右列。

---

## 2. 客户 PCI 责任与 SAQ 档位

- "做 PCI"与"做 SAQ"非二选一:SAQ 本身就是 PCI 合规的一种方式。问题实质 = **客户要填哪一档 SAQ**。
- 分水岭:卡数据是否进入客户 App 环境。WebView 方案=否(约 SAQ A);纯 Native=是(比 SAQ A 重,
  接近 SAQ A-EP 心智,移动端具体档由收单行定)。
- 减轻客户负担三点:① 卡数据全程只在 SDK 内,客户代码碰不到;② SDK 落实第 3 节硬约束,替客户承担大部分
  移动端控制项;③ 行业参照(同类原生 SDK 收卡)通常指引 SAQ A-EP 或等价。
- **对客户口径**:用 Native SDK 仍需做 PCI 合规(填 SAQ);因卡数据封装在 SDK 内、客户代码不接触,大概率
  落在"比纯托管页稍重、远比自建收银台轻"的档位;**具体以收单行/QSA 裁定为准**,SDK 提供合规说明材料协助。
- 不对客户承诺具体档位;准备合规说明材料;"向收单行/QSA 确认目标档位"列为 P0。

---

## 3. SDK 侧强制控制项(代码级硬约束)

1. **边界内聚**:明文卡仅存在于卡输入控件 + CardEncryptor 加密前瞬时变量,加密后立即清零;全库仅此处
   接触明文。
2. **键盘/系统缓存防护**:PAN/CVV/有效期关 autocorrection + spellChecking + smart 系列;
   **CVV 不设 textContentType**(不进自动填充);PAN 可用系统扫卡/自动填充(Apple 官方安全通道)。
3. **零持久化**:明文卡、钱包 token、customerAccessSecret、checkoutClientSecret、paymentMethodId 一律不写
   UserDefaults/文件/Keychain/剪贴板;只内存持有,终态即清。
4. **零日志泄漏**:敏感字段绝不进 print/os_log/埋点/崩溃上报;CheckoutError 只带 code/message/traceId。
5. **TLS**:所有后端/PSP 请求强制 HTTPS;SSL pinning 后期可选。
6. **防截屏**(后期可选):**仅银行卡信息输入页**(iOS secure 层技巧 / Android FLAG_SECURE),不做全页
   防截屏(体验权衡,PCI 不强制)。
7. **凭证纪律**:customerAccessSecret 短 TTL(建议 5–10 分钟且不晚于 session)+ 内存 + 终态即撤。

> 以上为 Native **统一安全要求**(iOS/Android 一致),各平台以等价 API 实现。要求相同,实现按平台。

### 3.1 CardField 安全规格(按字段)

| 字段 | 关键配置 | 原因 |
|---|---|---|
| 卡号 PAN | asciiCapableNumberPad;textContentType=.creditCardNumber;autocorrection/spellChecking=.no;smart 系列=.no | 关自动纠错/联想,防 PAN 进键盘自学习词典/QuickType 缓存 |
| CVV/CVC | .no 全套;asciiCapableNumberPad;**textContentType 置空**;可选 isSecureTextEntry | CVV 绝不被系统记忆/自动填充;授权后不得存储 |
| 有效期 | 数字键盘;关纠错 | 防词典缓存 |

---

## 4. 敏感数据资产与接触边界

| 资产 | 位置 | 生命周期 | 控制 |
|---|---|---|---|
| 明文 PAN/有效期/CVV | 卡输入控件 + CardEncryptor 加密前瞬时 | 加密后立即清零 | 边界内聚:仅 CardEncryptor |
| 卡密文 cardEncryptedData | 提交请求体 | 单次 | HTTPS 直传,不落盘不记日志 |
| 钱包 token | PassKit 回调 → 提交 | 单次 | 不解密、不留存、不回传宿主 |
| customerAccessSecret | CredentialStore(内存) | 短 TTL,终态即清 | 绝不进 URL/持久化/日志/崩溃/公开返回 |
| checkoutClientSecret | CredentialStore(内存) | session 内 | 同上 |
| paymentMethodId | 列卡 → 提交 | 交易级、临时 | 绑 session/customer/固定金额,非长期凭证 |

---

## 5. COF 零验证快捷支付:风险与兜底(会议重点)

### 5.1 需求与偏离

客户明确要求:**绑卡 → 选卡 → 直接支付,不输入任何验证(无 CVC、无 3DS)**。偏离 COF 威胁模型铁律四
(用历史卡须交易级二次认证)。

### 5.2 为何可接受——双层临时凭证

| 凭证 | 性质 | 泄漏后最坏情况 |
|---|---|---|
| customerAccessSecret | 短 TTL、内存、终态即撤 | 有效期内可列/用该用户的卡 |
| paymentMethodId | 交易级、临时,绑 session+customer+**固定金额/币种** | **只能完成这一笔已固定金额、固定归属的订单**,不能换金额/订单/用户 |

残余风险从"拿到凭证=任意金额盗刷"收窄为"拿到凭证=本笔固定订单可能被代付/重放",再由幂等键 +
短 TTL + 终态即撤压缩。

### 5.3 不焊死"永不验证"

后端保留控制权:风控放行则选卡即付;判定高风险时返回 `TxnStatus='R'`。首期 SDK 对 `R` 走最小处理
(pending),但协议/代码路径**预留** step-up——后端收紧时无需改客户端即可触发 CVC/3DS。

---

## 6. 决策待办(会议拍板,认领 owner)

| 编号 | 议题 | 建议 | Owner | 优先级 |
|---|---|---|---|---|
| D1 | COF 历史卡交易**风控覆盖**是否就绪 | 零验证前提 | 后端 | P0 |
| D2 | paymentMethodId **交易级作用域校验**(归属+固定金额+幂等) | 残余风险兜底核心 | 后端 | P0 |
| D3 | customerAccessSecret / checkoutClientSecret 的 **TTL/撤销/单次** | 短 TTL + 终态即撤 | 后端 | P0 |
| D4 | Apple Pay **merchant ID 两模式**证书/网关对应 | SDK 两模式同码,来源可配置 | 后端/商务 | P0 |
| D5 | **目标 SAQ 档位**向收单行/QSA 确认 | 不承诺档位;备合规说明材料 | 商务/合规 | P0 |
| D6 | RSA **padding/算法**与后端解密一致 | 写 CardEncryptor 前必须定 | 后端 | P0 |
| D7 | 钱包 token **提交字段格式** | 复用 cardEncryptedData 还是单列 | 后端 | P1 |
| D8 | 后期 step-up(3DS/CVC)**触发策略与时间表** | 协议已预留 | 后端/产品 | P2 |
| D9 | SSL pinning / 越狱检测 / 防截屏 **是否纳入及何时** | 首期可选 | 产品/安全 | P2 |
| D10 | 目标市场**地区性合规**(数据驻留等) | 按市场 | 合规/商务 | P2 |

---

## 7. 残余风险登记

| 风险 | 兜底 | 归属 | 状态 |
|---|---|---|---|
| 明文卡在 App 进程内存(加密前) | 边界内聚 + 立即清零 + 不落盘不记日志;内存 dump 属 OS 级,超 SDK 可控 | SDK + OS | 可控 |
| COF 零验证凭证被重放 | 双层临时凭证 + 幂等 + 终态即撤 + 后端风控 | 后端 + SDK | 待 D1–D3 |
| 风控需 step-up 但首期无 UI | 预留 requires_action 路径 | 后期 | 已预留 |
| 越狱设备 | 首期不做检测(不当安全保证) | 后期可选 | 待 D9 |
| 截屏/录屏泄漏卡输入 | 后期仅卡输入页防截屏 | 后期可选 | 待 D9 |

---

## 8. 判别结论

**可以实施。** 纯 Native 的卡数据接触面是"已知、可控、可留痕"的,不存在"做出来才发现无法合规"的硬
阻断。前提:第 3 节 SDK 硬约束全部落实 + 第 6 节 P0 决策逐条关闭。PCI 档位会上升但不致命,最终以收单行/
QSA 裁定为准。
