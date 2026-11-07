import SwiftUI
import UIKit

/// A transient, non-blocking payment notice (toast) shown at the top of a screen.
///
/// Used for outcomes that do not navigate anywhere (canceled / failed / pending / unknown), so the
/// message does not sit inline above the Pay button. It auto-hides, can be tapped away, and is
/// announced to VoiceOver.
struct PaymentToast: Equatable, Identifiable {
    enum Style: Equatable {
        /// Neutral information (e.g. the user canceled; nothing was charged).
        case info
        /// The payment is still being confirmed (pending / unknown).
        case waiting
        /// The payment failed.
        case error
    }

    /// Unique per show, so re-showing the same message restarts the auto-hide timer.
    let id = UUID()
    let messageKey: String
    let style: Style

    /// How long the toast stays visible. Waiting states stay longer so they are not missed.
    var duration: TimeInterval {
        switch style {
        case .info: return 2.5
        case .error, .waiting: return 4
        }
    }

    var symbol: String {
        switch style {
        case .info: return "info.circle.fill"
        case .waiting: return "clock.fill"
        case .error: return "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch style {
        case .info: return .secondary
        case .waiting: return .orange
        case .error: return .red
        }
    }
}

/// Overlays a `PaymentToast` at the top of the modified view.
private struct PaymentToastModifier: ViewModifier {
    @Binding var toast: PaymentToast?
    let text: (String) -> String

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let toast {
                HStack(spacing: 8) {
                    Image(systemName: toast.symbol)
                        .foregroundColor(toast.tint)
                        .accessibilityHidden(true)
                    Text(text(toast.messageKey))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(UIColor.secondarySystemGroupedBackground))
                        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { dismiss(toast) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityIdentifier("paymentToast")
                .task(id: toast.id) {
                    UIAccessibility.post(notification: .announcement, argument: text(toast.messageKey))
                    try? await Task.sleep(nanoseconds: UInt64(toast.duration * 1_000_000_000))
                    dismiss(toast)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: toast)
    }

    /// Hides `shown` only if it is still the current toast (a newer one is left alone).
    private func dismiss(_ shown: PaymentToast) {
        if toast?.id == shown.id { toast = nil }
    }
}

extension View {
    /// Shows `toast` (when non-nil) as a top overlay; `text` localizes its message key.
    func paymentToast(_ toast: Binding<PaymentToast?>, text: @escaping (String) -> String) -> some View {
        modifier(PaymentToastModifier(toast: toast, text: text))
    }
}
