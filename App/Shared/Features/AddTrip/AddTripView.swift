import SwiftUI

struct AddTripView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            StationSearchView(onTripAdded: { dismiss() })
            .navigationTitle("Track a Train")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .tint(Color.ttActionTint)
        .background(Color.ttBackgroundCanvas)
        .presentationDetents([.large])
    }
}
