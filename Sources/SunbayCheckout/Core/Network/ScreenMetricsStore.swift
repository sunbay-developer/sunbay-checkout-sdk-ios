import Foundation

/// Thread-safe holder of the screen metrics snapshot used for `userDeviceInfo` (no UIKit).
///
/// The UI layer records the metrics on the main actor when a sheet is presented; the submit path
/// (which runs off the main thread) only reads the stored snapshot.
final class ScreenMetricsStore: @unchecked Sendable {
    typealias Metrics = (width: Int, height: Int, scale: Double)

    private let lock = NSLock()
    private var metrics: Metrics?

    init() {}

    /// Stores the latest screen size (points) and scale.
    func record(width: Int, height: Int, scale: Double) {
        lock.lock()
        metrics = (width, height, scale)
        lock.unlock()
    }

    /// The latest recorded metrics, or `nil` when none were recorded.
    var current: Metrics? {
        lock.lock()
        defer { lock.unlock() }
        return metrics
    }
}
