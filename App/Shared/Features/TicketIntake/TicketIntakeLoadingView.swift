import SwiftUI

struct TicketIntakeLoadingView: View {
    let title: String

    var body: some View {
        VStack(spacing: TrainTrackerSpacing.space16) {
            ProgressView(title).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ttBackgroundCanvas)
    }
}
