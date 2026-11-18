import SwiftUI
import TrainTrackerCore

struct WindowSeatView: View {
    @Environment(TripLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.journeyReferenceDate) private var referenceDate
    @State private var selected: HudsonLandmark
    @State private var following: Bool
    let tripID: RailIdentifier?

    init(trip: TrainTrip?, selectedStops: [StopTime]? = nil, now: Date = .now) {
        tripID = trip?.id
        let nearby = trip.flatMap { HudsonWindowGuide.nearbyLandmark(on: $0, at: now) }
        _selected = State(initialValue: nearby ?? HudsonWindowGuide.firstLandmark(for: trip, stops: selectedStops))
        _following = State(initialValue: nearby != nil)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { clock in
            let nearby = tripID.flatMap { library.trip(id: $0) }.flatMap {
                HudsonWindowGuide.nearbyLandmark(on: $0, at: referenceDate ?? clock.date)
            }
            GeometryReader { proxy in
                let wide = proxy.size.width >= 600 && !textSize.isAccessibilitySize
                let artHeight = min(max(proxy.size.height * (wide ? 0.52 : 0.46), 200), wide ? 470 : 410)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(wide: wide)
                            .padding(.leading, proxy.safeAreaInsets.leading)
                            .padding(.trailing, proxy.safeAreaInsets.trailing)
                        WindowSeatPanorama(selection: selected, beginBrowsing: { following = false }, select: { selected = $0 })
                            .frame(height: artHeight)
                        if wide {
                            HStack(alignment: .top, spacing: 32) {
                                caption.frame(maxWidth: 430, alignment: .leading)
                                Spacer(minLength: 0)
                                controls(nearby).frame(maxWidth: 215, alignment: .trailing)
                            }
                            .padding(LayoutMetrics.pageInset)
                            .padding(.leading, proxy.safeAreaInsets.leading)
                            .padding(.trailing, proxy.safeAreaInsets.trailing)
                        } else {
                            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space24) {
                                caption
                                controls(nearby)
                            }
                            .padding(LayoutMetrics.pageInset)
                            .padding(.leading, proxy.safeAreaInsets.leading)
                            .padding(.trailing, proxy.safeAreaInsets.trailing)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .ignoresSafeArea(.container, edges: .horizontal)
            }
            .onChange(of: nearby) { _, new in
                if following, let new { selected = new }
            }
        }
        .background(Color.ttBackgroundCanvas.ignoresSafeArea())
    }

    private func header(wide: Bool) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("The Hudson Valley")
                    .font(.system(wide ? .largeTitle : .title, design: .serif, weight: .semibold))
                    .foregroundStyle(Color.ttTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Empire Service · New York to Albany")
                    .font(.subheadline).foregroundStyle(Color.ttTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline)
                    .frame(width: 44, height: 44)
                    .background(Color.ttBackgroundSurface, in: .circle)
                    .overlay { Circle().strokeBorder(Color.ttBorderSubtle, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Window Seat")
        }
        .padding(.horizontal, LayoutMetrics.pageInset)
        .padding(.vertical, TrainTrackerSpacing.space16)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
            Text(selected.name)
                .font(.system(.title, design: .serif, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("windowSeatCaption")
            Text(selected.caption)
                .font(.body).foregroundStyle(Color.ttTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Link(destination: selected.sourceURL) {
                Label("About this landmark", systemImage: "arrow.up.right")
                    .font(.footnote.weight(.medium))
                    .frame(minHeight: 44, alignment: .topLeading)
            }
            .tint(.ttActionTint)
        }
    }

    private func controls(_ nearby: HudsonLandmark?) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
            HStack(spacing: TrainTrackerSpacing.space16) {
                arrow("Previous landmark", symbol: "chevron.left", offset: -1)
                Text("\(index + 1) / \(HudsonLandmark.allCases.count)")
                    .monospacedDigit().font(.subheadline.weight(.medium))
                    .accessibilityLabel("Landmark \(index + 1) of \(HudsonLandmark.allCases.count)")
                arrow("Next landmark", symbol: "chevron.right", offset: 1)
            }
            if tripID != nil {
                if let nearby {
                    Button {
                        following = true
                        selected = nearby
                    } label: {
                        Label(following ? "Following train" : "Follow train", systemImage: "location.fill")
                            .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    }
                    .disabled(following).accessibilityIdentifier("windowSeatFollow")
                } else {
                    Text(following ? "Waiting for the next reported landmark." : "Browse the guide. No recent train report near a landmark.")
                        .font(.footnote).foregroundStyle(Color.ttTextSecondary)
                }
            }
        }
        .foregroundStyle(Color.ttTextPrimary)
    }

    private var index: Int { HudsonLandmark.allCases.firstIndex(of: selected)! }

    private func arrow(_ title: String, symbol: String, offset: Int) -> some View {
        let target = index + offset
        return Button {
            guard HudsonLandmark.allCases.indices.contains(target) else { return }
            following = false
            selected = HudsonLandmark.allCases[target]
        } label: {
            Image(systemName: symbol).font(.subheadline.weight(.bold)).frame(width: 44, height: 44)
                .background(Color.ttBackgroundSurface, in: .circle)
                .overlay { Circle().strokeBorder(Color.ttBorderSubtle, lineWidth: 1) }
        }
        .buttonStyle(.plain).disabled(!HudsonLandmark.allCases.indices.contains(target))
        .opacity(HudsonLandmark.allCases.indices.contains(target) ? 1 : 0.35)
        .accessibilityLabel(title)
    }
}
