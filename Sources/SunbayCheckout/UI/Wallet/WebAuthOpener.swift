#if canImport(UIKit)
    import AuthenticationServices
    import Foundation
    import UIKit

    /// `WebAuthOpening`（Task 8 协议缝）的真实实现：用系统
    /// `ASWebAuthenticationSession` 打开第三方 APM 跳转页（如支付宝 web），带 returnUrl
    /// 回跳（product-spec §4.5）。
    ///
    /// ## 职责与边界
    /// - 只负责「用系统安全浏览器打开一个跳转 URL，并在回跳到约定 scheme 时结束会话」。
    ///   终态由 Core 继续轮询 / 回跳确认（授权/打开成功 ≠ 交易成功，§3.2）。
    /// - **不接触任何卡数据**：跳转打开的是第三方 APM 支付网页，属标准做法（§4.5 边界澄清）。
    /// - 仅 iOS 可用：整体以 `#if canImport(UIKit)` 限定，`import AuthenticationServices`
    ///   置于其内；macOS 宿主下不编译（Core 保持 UIKit/AuthenticationServices 无关）。
    ///
    /// ## 回跳 scheme（callback scheme）
    /// `ASWebAuthenticationSession` 以「callback URL scheme」识别回跳：后端下发的 returnUrl
    /// 形如 `<scheme>://...`，系统在用户被重定向回该 scheme 时关闭浏览器并回调。本类以注入的
    /// `callbackURLScheme`（host App 在 `Info.plist` 注册的自定义 scheme）构造会话；为空时
    /// 退化为「仅打开、由外部轮询确认」（iOS 17+ 可用 `.callback(.customScheme:)`，这里取
    /// 跨版本最稳妥的 `callbackURLScheme:` 形式）。
    ///
    /// ## async 语义
    /// 实现 `func open(_ url: URL) async`：启动会话并 `await` 到用户完成或取消（回跳 /
    /// 关闭浏览器）即返回——与 Task 8 协议签名**完全一致**（无返回值、无 throws）。会话结果
    /// （回跳 URL / 取消 / 错误）不作为交易结论，交由 Core 轮询；故这里只 await 其结束，不透出。
    struct WebAuthOpener: WebAuthOpening {
        /// host App 注册的回跳自定义 scheme（如 `"sunbaycheckout"`）；为空则不绑定回跳。
        let callbackURLScheme: String?

        /// 创建一个 Web 认证打开器。
        ///
        /// - Parameter callbackURLScheme: 回跳自定义 scheme；缺省 nil（仅打开，外部确认终态）。
        init(callbackURLScheme: String? = nil) {
            self.callbackURLScheme = callbackURLScheme
        }

        /// 打开第三方 APM 跳转页并等待用户完成 / 取消（见类型说明）。
        ///
        /// - Parameter url: 后端在 `redirect` 动作中下发的跳转地址。
        func open(_ url: URL) async {
            let scheme = callbackURLScheme
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // ASWebAuthenticationSession 必须在主线程创建 / 启动（UI 相关）。
                Task { @MainActor in
                    let anchorProvider = PresentationAnchorProvider()
                    let session = ASWebAuthenticationSession(
                        url: url,
                        callbackURLScheme: scheme
                    ) { _, _ in
                        // 回跳 URL / 取消 / 错误都不作为交易结论；仅标记「会话结束」。
                        // 终态由 Core 轮询 / 回跳确认（§3.2 / §4.5）。不记录任何内容（§5）。
                        continuation.resume()
                    }
                    session.presentationContextProvider = anchorProvider
                    session.prefersEphemeralWebBrowserSession = false
                    // 持有 anchorProvider 直至会话结束，避免提前释放。
                    anchorProvider.retainSession = session
                    if !session.start() {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// 为 `ASWebAuthenticationSession` 提供展示锚点（当前 key window）。
    ///
    /// 系统要求实现 `ASWebAuthenticationPresentationContextProviding` 返回一个 window。
    /// 取当前前台 `UIWindowScene` 的 key window;取不到时回退到一个空 `ASPresentationAnchor`。
    @MainActor
    private final class PresentationAnchorProvider: NSObject,
        ASWebAuthenticationPresentationContextProviding
    {
        /// 持有 session 至回调触发，防止其被提前释放。
        var retainSession: ASWebAuthenticationSession?

        func presentationAnchor(
            for session: ASWebAuthenticationSession
        ) -> ASPresentationAnchor {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            if let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first {
                return window
            }
            return ASPresentationAnchor()
        }
    }
#endif
