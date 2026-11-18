import SwiftUI
import TrainTrackerCore

/// Credit and link for Amtraker, the third-party source of Amtrak times, tracks and GPS. Its
/// ODC-By data license requires a prominent attribution that links to amtraker.com, so this sits
/// beside the live data itself rather than only in Settings.
struct AmtrakerAttributionLink: View {
    static let url = URL(string: "https://amtraker.com")!

    var body: some View {
        Link(destination: Self.url) {
            Label {
                Text("Amtrak data from Amtraker")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "arrow.up.right.square")
            }
            .font(.caption.weight(.semibold))
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityHint("Opens amtraker.com, the source of Amtrak times, tracks and train positions")
        .accessibilityIdentifier("amtrakerAttribution")
    }

    /// Amtraker supplies data for Amtrak trains regardless of how the trip was saved.
    static func applies(to trip: TrainTrip) -> Bool {
        AmtrakPositionMatcher.isAmtrak(trip)
    }
}
