import SwiftUI
import UIKit

/// Fails vertical drags before recognition so the surrounding journey can scroll normally.
struct HorizontalRouteScrubGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let changed: (CGPoint, CGPoint) -> Void
    let ended: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.cancelsTouchesInView = false
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed:
            let location = context.converter.location(in: .global)
            let translation = context.converter.translation(in: .global) ?? .zero
            changed(CGPoint(x: location.x - translation.x, y: location.y - translation.y), location)
        case .ended, .cancelled, .failed:
            ended()
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(converter: converter)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let converter: CoordinateSpaceConverter

        init(converter: CoordinateSpaceConverter) {
            self.converter = converter
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let velocity = converter.localVelocity else { return false }
            return abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
