import SwiftUI

/// The illustration stays continuous as the window moves. Dragging, tapping a point and the
/// page arrows all select the same landmark; only a rider gesture gives up following the train.
struct WindowSeatPanorama: View {
    let selection: HudsonLandmark
    let beginBrowsing: () -> Void
    let select: (HudsonLandmark) -> Void
    @GestureState private var translation: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let printWidth = max(size.width, size.height * 3)
            let travel = max(0, printWidth - size.width)
            let rest = WindowSeatFraming.offset(for: selection, printWidth: printWidth, windowWidth: size.width)
            let offset = min(max(rest - translation, 0), travel)
            ZStack(alignment: .topLeading) {
                Image("HudsonWindowSeat")
                    .resizable().scaledToFill()
                    .frame(width: printWidth, height: size.height)
                    .clipped()
                    .accessibilityHidden(true)
                ForEach(HudsonLandmark.allCases) { point in
                    marker(point)
                        .position(x: min(max(point.printFraction * printWidth, 22), printWidth - 22),
                                  y: size.height * 0.78)
                }
            }
            .frame(width: printWidth, height: size.height)
            .offset(x: -offset)
            .frame(width: size.width, height: size.height, alignment: .leading)
            .clipped()
            .contentShape(.rect)
            .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: selection)
            .simultaneousGesture(DragGesture(minimumDistance: 12).updating($translation) { value, state, _ in
                if travel > 0, abs(value.translation.width) > abs(value.translation.height) { state = value.translation.width }
            }.onEnded { value in
                let dx = value.translation.width
                guard travel > 0, abs(dx) > 20, abs(dx) > abs(value.translation.height) else { return }
                let projected = dx + (value.predictedEndTranslation.width - dx) * 0.32
                beginBrowsing()
                select(WindowSeatFraming.landmark(at: rest - projected, printWidth: printWidth, windowWidth: size.width))
            })
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("windowSeatPrint")
    }

    private func marker(_ point: HudsonLandmark) -> some View {
        Button {
            beginBrowsing()
            select(point)
        } label: {
            ZStack {
                Circle().fill(Color.ttTextOnBrand).frame(width: 28, height: 28)
                Circle().strokeBorder(Color.ttBackgroundBrand, lineWidth: 1.5).frame(width: 26, height: 26)
                Circle().fill(Color.ttBackgroundBrand).frame(width: point == selection ? 18 : 7)
                if point == selection {
                    Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(Color.ttTextOnBrand)
                }
            }
            .shadow(color: .black.opacity(0.21), radius: 3, y: 1)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(point.name)
        .accessibilityAddTraits(point == selection ? [.isSelected] : [])
        .accessibilityIdentifier("landmark-\(point.rawValue)")
    }
}

enum WindowSeatFraming {
    static func offset(for point: HudsonLandmark, printWidth: CGFloat, windowWidth: CGFloat) -> CGFloat {
        min(max(point.printFraction * printWidth - windowWidth / 2, 0), max(0, printWidth - windowWidth))
    }

    /// The first and last scenes can sit against a page edge before their marker reaches the center.
    static func landmark(at proposed: CGFloat, printWidth: CGFloat, windowWidth: CGFloat) -> HudsonLandmark {
        if proposed <= 0 { return .manhattan }
        if proposed >= printWidth - windowWidth { return .albany }
        return HudsonLandmark.allCases.min {
            abs(offset(for: $0, printWidth: printWidth, windowWidth: windowWidth) - proposed)
                < abs(offset(for: $1, printWidth: printWidth, windowWidth: windowWidth) - proposed)
        } ?? .manhattan
    }
}
