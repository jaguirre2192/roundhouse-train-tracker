import SwiftUI

/// Train Tracker on the wrist: how long until the rider's train leaves or reaches their stop,
/// and the switch for the phone's "Wake Me Before My Stop" alert. Everything shown is what
/// the iPhone app last sent; the watch never checks a train itself.
@main
struct TrainTrackerWatchApp: App {
    @State private var store = WatchStore.launch()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            WatchRootView()
                .environment(store)
                .watchPreviewTextSize()
            #else
            WatchRootView()
                .environment(store)
            #endif
        }
    }
}
