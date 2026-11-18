import SwiftUI

/// The primary entry into train discovery, ahead of the ticket import choices.
struct AddJourneySearchAction: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: TrainTrackerSpacing.space12) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "magnifyingglass")
                        .font(.title3.weight(.semibold))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                    Text("Search for a Train")
                        .font(.headline)
                    Text("Choose a route or browse station departures.")
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "arrow.right")
                        .font(.body.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
            .multilineTextAlignment(.leading)
            .foregroundStyle(Color.ttTextOnBrand)
            .padding(.vertical, TrainTrackerSpacing.space8)
            .trainTrackerFullWidthAction()
        }
        .trainTrackerPrimaryAction()
        .controlSize(.large)
        .buttonBorderShape(.roundedRectangle(radius: TrainTrackerRadius.control))
        .accessibilityLabel("Search for a Train")
        .accessibilityHint("Opens route and station search")
        .accessibilityIdentifier("addJourneySearch")
    }
}
