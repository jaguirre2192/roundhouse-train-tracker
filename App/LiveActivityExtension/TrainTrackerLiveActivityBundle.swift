import SwiftUI
import WidgetKit

@main
struct TrainTrackerLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        TrainJourneyLiveActivity()
        NextTrainWidget()
        NextTrainControl()
    }
}
