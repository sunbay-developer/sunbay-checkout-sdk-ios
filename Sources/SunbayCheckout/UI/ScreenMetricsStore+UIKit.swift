#if canImport(UIKit)
    import UIKit

    extension ScreenMetricsStore {
        /// Snapshots the given screen (default: the main screen) on the main actor.
        ///
        /// Submit runs off the main thread, so the UI shell records the metrics up front and the
        /// device-info collector reads the stored snapshot.
        @MainActor
        func recordMainScreen(_ screen: UIScreen = UIScreen.main) {
            let bounds = screen.bounds
            record(width: Int(bounds.width), height: Int(bounds.height), scale: Double(screen.scale))
        }
    }
#endif
