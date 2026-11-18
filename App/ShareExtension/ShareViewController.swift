import SwiftUI
import UIKit

final class ShareViewController: UIViewController {
    private let viewModel = ShareExtensionViewModel()

    override func viewDidLoad() {
        super.viewDidLoad()

        let hosting = UIHostingController(
            rootView: ShareExtensionRootView(state: viewModel.state) { [weak self] in
                self?.finish()
            }
        )
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        self.hostingController = hosting

        Task {
            await viewModel.start(context: extensionContext)
            refresh()
            if case .success = viewModel.state {
                try? await Task.sleep(for: .seconds(1))
                finish()
            }
        }
    }

    private var hostingController: UIHostingController<ShareExtensionRootView>?

    private func refresh() {
        hostingController?.rootView = ShareExtensionRootView(state: viewModel.state) { [weak self] in
            self?.finish()
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
