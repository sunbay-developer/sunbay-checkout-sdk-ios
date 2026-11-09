import Foundation

/// Host-level card-on-file (saved card) options.
///
/// Card-on-file is effective only when ALL of the following hold: the checkout session allows it
/// (the backend's `supportStoreCard`; absent means allowed), `isEnabled` is `true`, and the host
/// supplied a `customerAccessSecret`. The session switch always wins: the host can turn COF off
/// but can never turn on COF that the session turned off.
///
/// When COF is not effective the SDK shows no saved cards and no "save card" checkbox, makes no
/// saved-card list request, and never sends `storeCard`.
public struct CardOnFileOptions: Sendable, Equatable {
    /// Host switch for card-on-file. Defaults to `true`; set `false` to disable COF entirely.
    public var isEnabled: Bool

    /// Whether the "save this card" checkbox starts ticked. Defaults to `false`.
    ///
    /// This only pre-ticks the checkbox; the card is saved only if the checkbox is still on when the
    /// user submits. Ignored when COF is not effective.
    public var saveByDefault: Bool

    /// Creates card-on-file options.
    ///
    /// - Parameters:
    ///   - isEnabled: Host switch; defaults to `true`.
    ///   - saveByDefault: Initial state of the save checkbox; defaults to `false`.
    public init(isEnabled: Bool = true, saveByDefault: Bool = false) {
        self.isEnabled = isEnabled
        self.saveByDefault = saveByDefault
    }
}
