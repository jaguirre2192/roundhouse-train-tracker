import SwiftUI

private struct RailUpdateSheen: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress = -1.4

    let updateKey: String

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.13), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: max(54, proxy.size.width * 0.18))
                        .rotationEffect(.degrees(12))
                        .offset(x: progress * proxy.size.width)
                    }
                    // Only the sheen is clipped to the card. Clipping the card itself would cut
                    // its shadow off at the edges and leave a slab of it inside ticket notches.
                    .clipShape(RoundedRectangle(cornerRadius: TrainTrackerRadius.card, style: .continuous))
                    .allowsHitTesting(false)
                }
            }
            .task(id: updateKey) {
                guard !reduceMotion, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
                progress = -1.4
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(.easeOut(duration: 0.72)) { progress = 1.5 }
            }
    }
}

extension View {
    func railUpdateSheen(updateKey: String) -> some View {
        modifier(RailUpdateSheen(updateKey: updateKey))
    }
}
