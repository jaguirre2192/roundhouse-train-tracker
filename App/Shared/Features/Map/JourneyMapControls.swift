import SwiftUI
import TrainTrackerCore

private enum MapControl {
    static let height: CGFloat = 44
}

/// Operational map controls use a stable ink surface, so terrain and appearance cannot
/// wash out the refresh label. Timing freshness and position quality remain distinct facts.
struct JourneyMapControls: View {
    let trust: JourneyTrust?
    let freshness: TripFreshness
    let referenceDate: Date
    let position: VehiclePosition?
    let positionStatus: TrainPositionStatus
    let isRefreshing: Bool
    let refresh: (() -> Void)?
    let framingSymbol: String
    let framingLabel: String
    let reframe: () -> Void
    var leadingInset: CGFloat = 0

    @ViewBuilder
    var body: some View {
        if TrainTrackerDevice.isDuo, #available(iOS 27.1, *) {
            DuoPlacement(controls: self)
        } else {
            floatingControls.padding(.leading, leadingInset)
        }
    }

    @ViewBuilder
    private var floatingControls: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { controls }
        } else {
            controls
        }
    }

    private var controls: some View {
        HStack(alignment: .top, spacing: TrainTrackerSpacing.space8) {
            timingStatus
            Spacer(minLength: TrainTrackerSpacing.space8)
            Button(action: reframe) {
                Image(systemName: framingSymbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ttTextOnBrand)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: MapControl.height, height: MapControl.height)
            }
            .buttonStyle(MapStatusButtonStyle())
            .accessibilityLabel(framingLabel)
        }
        .padding(.horizontal, TrainTrackerSpacing.space16)
        .padding(.vertical, TrainTrackerSpacing.space8)
    }

    @ViewBuilder
    private var timingStatus: some View {
        if let trust {
            Button { refresh?() } label: {
                HStack(spacing: TrainTrackerSpacing.space8) {
                    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                        JourneyTrustMark(
                            trust: trust, freshness: freshness, referenceDate: referenceDate,
                            style: .word, onInk: true, foreground: .ttTextOnBrand
                        )
                        if positionStatus == .unavailable || positionStatus == .stale {
                            Text(positionStatus.title)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.ttTextOnBrand)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if isRefreshing {
                        ProgressView().tint(Color.ttTextOnBrand).accessibilityHidden(true)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.ttTextOnBrand)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, TrainTrackerSpacing.space12)
                .padding(.vertical, TrainTrackerSpacing.space8)
                .frame(minHeight: MapControl.height)
            }
            .buttonStyle(MapStatusButtonStyle())
            .disabled(refresh == nil || isRefreshing)
            .accessibilityHint("Refreshes the journey times and position")
            .accessibilityIdentifier("journeyTrustMark")
        } else {
            PositionStatusBadge(position: position, now: referenceDate)
                .accessibilityIdentifier("journeyPositionStatus")
        }
    }

    /// The actual system bar owns placement and overflow on Duo. Its lower toolbar becomes
    /// a second vertical cluster below the app's navigation actions when bars are vertical.
    @available(iOS 27.1, *)
    private struct DuoPlacement: View {
        let controls: JourneyMapControls
        @Environment(\.toolbarVerticalEdge) private var verticalEdge
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    if verticalEdge != nil {
                        status(in: geometry)
                        .toolbar {
                            ToolbarItem(placement: .bottomBar) {
                                cameraButton
                            }
                            .axisBehavior(.verticalPreferred)
                            .sharedBackgroundVisibility(.hidden)
                        }
                    } else {
                        status(in: geometry)
                        VStack {
                            Spacer(minLength: 0)
                            HStack {
                                Spacer(minLength: 0)
                                cameraButton
                            }
                        }
                        .padding(JourneyPanelGeometry.margin)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
            // The map reaches the top on Duo's vertical bars. Foreground controls still
            // clear the actual window corner and share the journey panel's leading gutter.
            .ignoresSafeArea(.container, edges: verticalEdge != nil ? .top : [])
        }

        private func status(in geometry: GeometryProxy) -> some View {
            let space = JourneyPanelGeometry(geometry)
            let margin = JourneyPanelGeometry.margin
            // A position-only badge describes the map. The station sign occupies the
            // entire leading panel, so keep this badge in the map's unobscured pane.
            let paneInset = controls.trust == nil ? controls.leadingInset : 0
            let available = max(0, geometry.size.width - paneInset - 2 * margin)
            let width = space.floatsBeside ? min(space.panelWidth, available) : available
            // A capsule already rounds away from the display corner. Using the full
            // rectangular corner inset would push its second line behind the panel.
            let top = margin + TrainTrackerSpacing.space8
            return controls.timingStatus
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: width, alignment: .leading)
                .padding(.leading, paneInset + margin)
                .padding(.trailing, margin)
                .padding(.top, top)
        }

        @ViewBuilder
        private var cameraButton: some View {
            let button = Button(action: controls.reframe) {
                Image(systemName: controls.framingSymbol)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 52, height: 52)
                    .contentShape(.circle)
            }
            .font(.title3)
            .foregroundStyle(Color.ttActionTint)
            .buttonStyle(.plain)
            .accessibilityLabel(controls.framingLabel)
            if reduceTransparency || contrast == .increased {
                button.background(Color.ttBackgroundElevated, in: Circle())
            } else {
                button.glassEffect(.regular.interactive(), in: Circle())
            }
        }
    }

}

private struct MapStatusButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .background(Color.ttBackgroundBrand, in: Capsule())
            .overlay { Capsule().fill(Color.ttTextOnBrand.opacity(configuration.isPressed ? 0.10 : 0)).allowsHitTesting(false) }
        if !reduceTransparency, contrast != .increased, #available(iOS 26.0, *) {
            label
                .glassEffect(.regular.tint(Color.ttBackgroundBrand.opacity(0.85)).interactive(), in: Capsule())
                .contentShape(Capsule())
        } else {
            label.contentShape(Capsule())
        }
    }
}
