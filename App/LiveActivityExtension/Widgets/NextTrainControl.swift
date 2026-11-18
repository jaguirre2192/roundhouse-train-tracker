import AppIntents
import SwiftUI
import WidgetKit

/// A Control Center, Lock Screen and Action button control that opens the next tracked train,
/// or My Trips with Add Journey when nothing is tracked. The app picks the train when it opens,
/// so the control never shows a stale one.
struct NextTrainControl: ControlWidget {
    static let kind = "com.jorgeaguirre.TrainTracker.NextTrainControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenURLIntent(NextTrainControlLink.url)) {
                Label("Next Train", image: TrainTrackerSymbol.train)
            }
        }
        .displayName("Next Train")
        .description("Opens your next tracked train in Roundhouse.")
    }
}

enum NextTrainControlLink {
    static let url = URL(string: "traintracker://next-train")!
}
