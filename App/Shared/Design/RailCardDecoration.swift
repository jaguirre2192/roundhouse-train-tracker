import SwiftUI

extension Color {
    static var railContentSurface: Color {
        .ttBackgroundSurface
    }
}

private struct RailTicketStyle: ViewModifier {
    let emphasized: Bool

    func body(content: Content) -> some View {
        let elevation = TrainTrackerElevation.card

        content
            .background(
                Color.ttBackgroundElevated,
                in: RoundedRectangle(cornerRadius: TrainTrackerRadius.card, style: .continuous)
            )
            .clipShape(
                RoundedRectangle(cornerRadius: TrainTrackerRadius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: TrainTrackerRadius.card, style: .continuous)
                    .stroke(
                        emphasized ? Color.ttRouteActive.opacity(0.28) : Color.ttBorderSubtle,
                        lineWidth: TrainTrackerStroke.subtle
                    )
            }
            .shadow(
                color: Color.black.opacity(elevation.opacity),
                radius: elevation.radius,
                x: elevation.x,
                y: elevation.y
            )
    }
}

extension View {
    func railTicketStyle(emphasized: Bool = false) -> some View {
        modifier(RailTicketStyle(emphasized: emphasized))
    }
}
