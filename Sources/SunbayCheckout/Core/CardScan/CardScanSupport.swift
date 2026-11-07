import Foundation

/// Pure decision logic for whether the "Scan card" affordance should be offered.
///
/// UI-agnostic (no UIKit / AVFoundation): the UI layer gathers the raw facts and this function turns
/// them into a yes/no, so the rule is unit-testable on the host.
enum CardScanSupport {
    /// The camera permission state, mirrored from `AVAuthorizationStatus` without importing it.
    enum CameraAccess: Sendable, Equatable {
        case notDetermined
        case authorized
        case denied
        case restricted
    }

    /// Whether the scan button should be shown.
    ///
    /// - Parameters:
    ///   - hostAllows: `false` when the host forced scanning off via `Appearance.cardScanning`.
    ///   - hasUsageDescription: Whether the host app's Info.plist declares `NSCameraUsageDescription`.
    ///     Without it the system terminates the app on camera access, so we must not offer the feature.
    ///   - hasCamera: Whether a capture device exists (false on the simulator).
    ///   - access: Current camera permission. `notDetermined` is allowed (the system prompts on use).
    static func isAvailable(
        hostAllows: Bool,
        hasUsageDescription: Bool,
        hasCamera: Bool,
        access: CameraAccess
    ) -> Bool {
        guard hostAllows, hasUsageDescription, hasCamera else { return false }
        switch access {
        case .notDetermined, .authorized: return true
        case .denied, .restricted: return false
        }
    }
}
