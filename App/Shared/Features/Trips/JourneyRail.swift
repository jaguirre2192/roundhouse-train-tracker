import SwiftUI
import TrainTrackerCore

/// One tracked train on the My Trips rail.
struct JourneyRailItem: Identifiable, Equatable {
    let id: RailIdentifier
    /// Station codes, such as "NYP → WAS".
    let route: String
    /// How it is running while underway; before that, when it leaves ("in 12 min" in the last
    /// half hour).
    let detail: String
    let tint: Color
    /// The same tint where the chip is ink.
    var tintOnInk: Color = .ttRouteOnInk
    /// How current its times are; a live train carries the live dot.
    var trust: JourneyTrust = .saved
    /// The ring: the share of the journey done while underway, or the last half hour before
    /// departure running down. Nil leaves the ring empty.
    let progress: Double?
    /// Changes only when the train's status does, never with the clock.
    let statusKey: String
}

/// Chooses which tracked train My Trips focuses on. The rail adapts to how many trains there
/// are: none for a single train, equal-width chips for a few, a scrolling row beyond that and at
/// accessibility text sizes.
struct JourneyRail: View {
    let items: [JourneyRailItem]
    let selection: RailIdentifier?
    let select: (RailIdentifier) -> Void
    /// The most chips that share the width equally; beyond it the rail scrolls. Lower where the
    /// rail shares its row with other controls.
    var maxEqualWidthItems = 3
    /// The fewest trains that show a rail. Over the map a single train still gets its chip.
    var minimumItems = 2
    /// Over the map each chip floats on its own: the selected one is ink, the rest are glass.
    var isOverMap = false
    /// The chips' corner radius, when the surface they sit on sets it. Nil keeps the control radius.
    var chipCornerRadius: CGFloat? = nil
    /// Press and hold: a preview of the train and what can be done with it.
    var preview: ((RailIdentifier) -> AnyView)?
    var menu: ((RailIdentifier) -> AnyView)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace

    var body: some View {
        if items.count >= minimumItems {
            glassContainer {
                if items.count <= maxEqualWidthItems, !dynamicTypeSize.isAccessibilitySize {
                    HStack(spacing: TrainTrackerSpacing.space8) { chips(fillWidth: items.count > 1) }
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: TrainTrackerSpacing.space8) { chips(fillWidth: false) }
                    }
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                }
            }
            .preferredSensoryFeedback(.selection, trigger: selection)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tracked trains")
        }
    }

    /// From iOS 26 the chips share one glass container, so the selected chip's glass flows into
    /// its neighbour when the selection moves.
    @ViewBuilder
    private func glassContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: TrainTrackerSpacing.space8) { content() }
        } else {
            content()
        }
    }

    private func chips(fillWidth: Bool) -> some View {
        ForEach(items) { item in
            JourneyRailChip(
                item: item, isSelected: item.id == selection, fillsWidth: fillWidth,
                isOverMap: isOverMap, cornerRadius: chipCornerRadius ?? TrainTrackerRadius.control,
                namespace: selectionNamespace
            ) {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.34)) { select(item.id) }
            }
            .contextMenu {
                if let menu { menu(item.id) }
            } preview: {
                if let preview { preview(item.id) }
            }
        }
    }
}

private struct JourneyRailChip: View {
    let item: JourneyRailItem
    let isSelected: Bool
    let fillsWidth: Bool
    var isOverMap = false
    var cornerRadius = TrainTrackerRadius.control
    let namespace: Namespace.ID
    let action: () -> Void

    /// The selected chip over the map is ink, like the ticket it stands for.
    private var isInk: Bool { isOverMap && isSelected }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Counts status changes seen while another train is in focus; each one pulses the chip.
    @State private var pulses = 0

    var body: some View {
        Button(action: action) {
            HStack(spacing: TrainTrackerSpacing.space6) {
                JourneyRailGlyph(
                    progress: item.progress, tint: isInk ? item.tintOnInk : item.tint,
                    isLive: item.trust == .live, isInk: isInk
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.route)
                        .font(.caption)
                        .foregroundStyle(isInk ? Color.ttTextOnBrand.opacity(0.72) : Color.ttTextSecondary)
                    Text(item.detail)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isInk ? Color.ttTextOnBrand : Color.ttTextPrimary)
                        .monospacedDigit()
                        .minimumScaleFactor(0.8)
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .snappy, value: item.detail)
                }
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                if fillsWidth { Spacer(minLength: 0) }
            }
            // A pill's round end needs a little more room than a card's corner, but not so much
            // that a departure time is cut short.
            .padding(.leading, isOverMap ? 10 : TrainTrackerSpacing.space8)
            .padding(.trailing, isOverMap ? 14 : TrainTrackerSpacing.space12)
            .padding(.vertical, TrainTrackerSpacing.space8)
            .frame(minHeight: 44)
            .modifier(JourneyRailChipSurface(isSelected: isSelected, isOverMap: isOverMap, cornerRadius: cornerRadius, namespace: namespace))
        }
        .buttonStyle(.plain)
        .phaseAnimator([false, true], trigger: pulses) { content, lifted in
            content.scaleEffect(lifted ? 1.06 : 1)
        } animation: { lifted in
            lifted ? .snappy(duration: 0.18) : .spring(duration: 0.5, bounce: 0.45)
        }
        .preferredSensoryFeedback(.impact(weight: .light), trigger: pulses)
        .onChange(of: item.statusKey) {
            if !isSelected, !reduceMotion { pulses += 1 }
        }
        .accessibilityLabel("\(item.route), \(item.detail), \(item.trust.title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Shows this train first. Press and hold for more.")
    }
}

/// The selected chip is glass from iOS 26, sharing one identity so it flows between chips; before
/// that it is the elevated surface sliding under a matched geometry.
private struct JourneyRailChipSurface: ViewModifier {
    let isSelected: Bool
    var isOverMap = false
    var cornerRadius = TrainTrackerRadius.control
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        if isOverMap {
            overMap(content)
        } else if reduceTransparency || contrast == .increased {
            content
                .background(Color.ttBackgroundElevated, in: shape)
                .overlay { shape.strokeBorder(isSelected ? Color.ttActionTint : Color.ttTextSecondary) }
                .contentShape(shape)
        } else if #available(iOS 26.0, *) {
            if isSelected {
                content
                    .glassEffect(.regular.interactive(), in: shape)
                    .glassEffectID("selection", in: namespace)
                    .contentShape(shape)
            } else {
                resting(content)
            }
        } else {
            content
                .background {
                    if isSelected {
                        shape
                            .fill(Color.ttBackgroundElevated)
                            .shadow(color: Color.ttBackgroundBrand.opacity(0.14), radius: 8, y: 3)
                            .matchedGeometryEffect(id: "selection", in: namespace)
                    }
                }
                .background(Color.ttBackgroundElevated.opacity(0.36), in: shape)
                .overlay { shape.strokeBorder(Color.ttTextPrimary.opacity(isSelected ? 0 : 0.08)) }
                .contentShape(shape)
        }
    }

    /// Floating over the map: ink for the train in focus, glass for the rest. Both hold their
    /// own on any map tile.
    @ViewBuilder
    private func overMap(_ content: Content) -> some View {
        if isSelected {
            content
                .background(Color.ttBackgroundBrand, in: shape)
                // At night ink sinks into a dark map, so the pill in focus is ringed in route teal.
                .overlay {
                    shape.strokeBorder(
                        colorScheme == .dark ? Color.ttRouteOnInk : Color.ttTextOnBrand.opacity(0.14),
                        lineWidth: colorScheme == .dark ? 1.5 : 1
                    )
                }
                .shadow(color: Color.ttBackgroundBrand.opacity(0.28), radius: 8, y: 3)
                .contentShape(shape)
        } else if reduceTransparency || contrast == .increased {
            content
                .background(Color.ttBackgroundElevated, in: shape)
                .overlay { shape.strokeBorder(Color.ttBorderSubtle) }
                .contentShape(shape)
        } else if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: shape)
                .contentShape(shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(Color.ttTextPrimary.opacity(0.08)) }
                .contentShape(shape)
        }
    }

    private func resting(_ content: Content) -> some View {
        content
            .background(Color.ttBackgroundElevated.opacity(0.36), in: shape)
            .overlay { shape.strokeBorder(Color.ttTextPrimary.opacity(0.08)) }
            .contentShape(shape)
    }
}

/// A ring that fills with the journey: the last half hour running down before departure, then
/// the share of the journey done.
private struct JourneyRailGlyph: View {
    let progress: Double?
    let tint: Color
    var isLive = false
    var isInk = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(isInk ? Color.ttTextOnBrand.opacity(0.24) : Color.ttRoutePassed, lineWidth: 3.5)
            // The live dot: the same blue point the ticket shows beside "Live".
            if isLive {
                Circle()
                    .fill(isInk ? Color.ttActionLiveOnInk : Color.ttActionLive)
                    .frame(width: 6, height: 6)
            }
            Circle()
                .trim(from: 0, to: progress.map { max(0.04, min($0, 1)) } ?? 0)
                .stroke(tint, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .smooth(duration: 0.8), value: progress)
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}
