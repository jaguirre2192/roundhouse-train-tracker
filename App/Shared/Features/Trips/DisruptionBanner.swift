import SwiftUI
import TrainTrackerCore

struct DisruptionBanner: View {
    let alert: RailAlert

    var body: some View {
        TrainTrackerNotice(alert.cause ?? "Service update", message: alert.message)
    }
}
