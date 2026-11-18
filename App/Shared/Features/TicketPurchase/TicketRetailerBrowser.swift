import SafariServices
import SwiftUI

struct TicketRetailerBrowser: UIViewControllerRepresentable {
    let url: URL
    let onInitialLoadFailed: () -> Void
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFailure: onInitialLoadFailed, onDone: onDone) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.delegate = context.coordinator
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onFailure: () -> Void
        let onDone: () -> Void
        init(onFailure: @escaping () -> Void, onDone: @escaping () -> Void) {
            self.onFailure = onFailure
            self.onDone = onDone
        }
        func safariViewController(_ controller: SFSafariViewController, didCompleteInitialLoad didLoadSuccessfully: Bool) {
            if !didLoadSuccessfully { onFailure() }
        }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onDone() }
    }
}
