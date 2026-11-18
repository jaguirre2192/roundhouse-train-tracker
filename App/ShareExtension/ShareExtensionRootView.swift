import SwiftUI

struct ShareExtensionRootView: View {
    let state: ShareExtensionViewModel.State
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch state {
            case .working:
                ProgressView("Sending to Roundhouse…")
            case .success:
                Label("Saved to Roundhouse", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                Text("Open Roundhouse to review it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case let .rejected(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
            case let .failed(message):
                Label(message, systemImage: "wifi.exclamationmark")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
