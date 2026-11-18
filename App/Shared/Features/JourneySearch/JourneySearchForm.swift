import SwiftUI

enum JourneySearchFormSection: Hashable, CaseIterable {
    case route
    case outbound
    case returnTrip
    case primaryAction
    case advancedOptions
}

enum JourneySearchFormLayout {
    /// The primary Search action sits directly after the outbound and return controls so it stays
    /// inside the first iPhone viewport at the default Dynamic Type size. Advanced options are
    /// secondary and follow it.
    static let sectionOrder: [JourneySearchFormSection] = [
        .route,
        .outbound,
        .returnTrip,
        .primaryAction,
        .advancedOptions
    ]

    static func usesStackedPlaceRows(for dynamicTypeSize: DynamicTypeSize) -> Bool {
        dynamicTypeSize.isAccessibilitySize
    }
}

enum JourneySearchAdvancedOptionsSummary {
    static func text(directOnly: Bool, maximumTransfers: Int) -> String {
        directOnly
            ? "Direct trains only"
            : "\(JourneySearchCopy.Form.upTo(maximumTransfers)) changes"
    }
}

@MainActor
struct JourneySearchForm: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsAdvancedOptions = false
    /// Route dots and the rail's clearance around them grow with Dynamic Type, but stop
    /// short of the icon rail's width so they never crowd the station name.
    @ScaledMetric(relativeTo: .body) private var scaledRouteDotSize: CGFloat = 14
    private var routeDotSize: CGFloat { min(scaledRouteDotSize, LayoutMetrics.iconRailWidth - TrainTrackerSpacing.space4) }
    /// Half the body cap height, so a dot sits on the station name's optical centre line.
    @ScaledMetric(relativeTo: .body) private var nameCapHalfHeight: CGFloat = 6

    let store: JourneySearchStore
    @Binding var presentedPicker: RailPlacePickerRole?
    let recentHistory: RailPlaceRecents?
    var usesTwoColumns = false

    var body: some View {
        if usesTwoColumns {
            columnsSection
            primaryActionSection
            advancedOptionsSection
        } else {
            ForEach(JourneySearchFormLayout.sectionOrder, id: \.self) { section in
                formSection(section)
            }
        }
    }

    private var columnsSection: some View {
        Section {
            HStack(alignment: .top, spacing: LayoutMetrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: LayoutMetrics.rowSpacing) {
                    columnHeading(JourneySearchCopy.Form.route)
                    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                        HStack(spacing: TrainTrackerSpacing.space12) {
                            routePlaces
                            swapButton(compact: true)
                        }
                        recentRouteRow(showsDivider: true)
                    }
                    .padding(LayoutMetrics.cardInset)
                    .trainTrackerSurface()
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("journeySearchRouteColumn")

                VStack(alignment: .leading, spacing: LayoutMetrics.rowSpacing) {
                    columnHeading(JourneySearchCopy.Form.outbound)
                    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
                        outboundControls
                        Divider().overlay(Color.ttBorderSubtle)
                        returnControls
                    }
                    .padding(LayoutMetrics.cardInset)
                    .trainTrackerSurface()
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("journeySearchTimingColumn")
            }
            .accessibilityIdentifier("journeySearchColumns")
        }
        .trainTrackerFormActionRow()
    }

    private func columnHeading(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color.ttTextPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func formSection(_ section: JourneySearchFormSection) -> some View {
        switch section {
        case .route: routeSection
        case .outbound: outboundSection
        case .returnTrip: returnSection
        case .primaryAction: primaryActionSection
        case .advancedOptions: advancedOptionsSection
        }
    }

    private var routeSection: some View {
        Section(JourneySearchCopy.Form.route) {
            if JourneySearchFormLayout.usesStackedPlaceRows(for: dynamicTypeSize) {
                routePlaces
                swapButton(compact: false)
            } else {
                HStack(alignment: .center, spacing: TrainTrackerSpacing.space12) {
                    routePlaces
                    swapButton(compact: true)
                }
            }
            recentRouteRow(showsDivider: false)
        }
        .trainTrackerRowSurface()
    }

    @ViewBuilder
    private func recentRouteRow(showsDivider: Bool) -> some View {
        if let recentHistory, store.phase == .editing, let choices = recentHistory.choices(for: store.form) {
            if showsDivider { Divider() }
            RecentRouteShortcut(suggested: choices.suggested, alternatives: choices.alternatives, history: recentHistory) { route in
                store.setPlaces(origin: route.origin, destination: route.destination)
            }
        }
    }

    /// From and To as a short vertical route: a ring for the origin, a filled ink dot for the
    /// destination, and a rail drawn between the two dots' measured centres so it stays true
    /// when a long station name wraps.
    private var routePlaces: some View {
        VStack(alignment: .leading, spacing: 0) {
            placeButton(
                title: JourneySearchCopy.Form.from,
                placeName: store.form.origin.map(RailPlacePickerPresentation.init)?.title,
                role: .origin
            )
            Divider()
                .overlay(Color.ttBorderSubtle)
                .padding(.leading, LayoutMetrics.iconRailWidth + TrainTrackerSpacing.space12)
            placeButton(
                title: JourneySearchCopy.Form.to,
                placeName: store.form.destination.map(RailPlacePickerPresentation.init)?.title,
                role: .destination
            )
        }
        .overlayPreferenceValue(RouteDotAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if let from = anchors[.origin], let to = anchors[.destination] {
                    let top = proxy[from]
                    let bottom = proxy[to]
                    Capsule()
                        .fill(Color.ttRouteActive)
                        .frame(width: 2, height: max(bottom.y - top.y - routeDotSize - TrainTrackerSpacing.space4, 0))
                        .position(x: top.x, y: (top.y + bottom.y) / 2)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func swapButton(compact: Bool) -> some View {
        Button {
            store.swapPlaces()
        } label: {
            if compact {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.ttTextBrand)
                    .frame(width: 44, height: 44)
                    .background(Color.ttBackgroundBrandSubtle, in: Circle())
            } else {
                Label(JourneySearchCopy.Form.swap, systemImage: "arrow.up.arrow.down")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            }
        }
        .buttonStyle(.plain)
        .disabled(store.form.origin == nil && store.form.destination == nil)
        .accessibilityLabel(JourneySearchCopy.Accessibility.swapPlaces.label)
        .accessibilityHint(JourneySearchCopy.Accessibility.swapPlaces.hint)
    }

    private var outboundSection: some View {
        Section(JourneySearchCopy.Form.outbound) {
            outboundControls
        }
        .trainTrackerRowSurface()
    }

    private var outboundControls: some View {
        Group {
            Picker(JourneySearchCopy.Form.searchBy, selection: outboundArriveBy) {
                Text(JourneySearchCopy.Form.departAt).tag(false)
                Text(JourneySearchCopy.Form.arriveBy).tag(true)
            }
            .pickerStyle(.segmented)

            DatePicker(
                JourneySearchCopy.Form.dateAndTime,
                selection: outboundTime,
                displayedComponents: [.date, .hourAndMinute]
            )
            .environment(\.timeZone, outboundTimeZone)
        }
    }

    private var returnSection: some View {
        Section {
            returnControls
        }
        .trainTrackerRowSurface()
    }

    private var returnControls: some View {
        Group {
            Toggle(JourneySearchCopy.Form.addReturn, isOn: returnEnabled)

            if store.form.returnEnabled {
                Picker(JourneySearchCopy.Form.searchBy, selection: returnArriveBy) {
                    Text(JourneySearchCopy.Form.departAt).tag(false)
                    Text(JourneySearchCopy.Form.arriveBy).tag(true)
                }
                .pickerStyle(.segmented)

                DatePicker(
                    JourneySearchCopy.Form.returnDateAndTime,
                    selection: returnTime,
                    in: store.form.outboundTime...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .environment(\.timeZone, returnTimeZone)
            }
        }
    }

    private var primaryActionSection: some View {
        Section {
            if case .failed(.outboundSearchUnavailable) = store.phase {
                TrainTrackerNotice(
                    JourneySearchCopy.Form.searchFailureMessage(for: store.journeyFailureReason),
                    systemImage: store.journeyFailureReason == .offline
                        ? "wifi.exclamationmark"
                        : "exclamationmark.triangle.fill"
                )
                .padding(.bottom, TrainTrackerSpacing.space12)
            }

            Button {
                recentHistory?.recordSearch(store.form)
                store.searchOutbound()
            } label: {
                HStack(spacing: TrainTrackerSpacing.space8) {
                    if store.phase == .loadingOutbound {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.ttTextOnBrand)
                    }
                    Text(store.phase == .loadingOutbound
                        ? JourneySearchCopy.Form.searchingTrains
                        : JourneySearchCopy.Form.searchTrains)
                }
                .trainTrackerFullWidthAction()
            }
            .trainTrackerPrimaryAction()
            .controlSize(.large)
            .disabled(!store.form.canSearch || store.phase == .loadingOutbound)
        } footer: {
            Text(JourneySearchCopy.Form.qualification)
        }
        .trainTrackerFormActionRow()
    }

    private var advancedOptionsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsAdvancedOptions) {
                Toggle(JourneySearchCopy.Form.directOnly, isOn: directOnly)

                if !store.form.directOnly {
                    Picker(JourneySearchCopy.Form.maximumChanges, selection: maximumTransfers) {
                        ForEach(1...4, id: \.self) { count in
                            Text(JourneySearchCopy.Form.upTo(count)).tag(count)
                        }
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                    Text(JourneySearchCopy.Form.options)
                        .foregroundStyle(Color.ttTextPrimary)
                    Text(JourneySearchAdvancedOptionsSummary.text(
                        directOnly: store.form.directOnly,
                        maximumTransfers: store.form.maximumTransfers
                    ))
                    .font(.caption)
                    .foregroundStyle(Color.ttTextSecondary)
                }
            }
        }
        .trainTrackerRowSurface()
    }

    private var outboundTime: Binding<Date> {
        Binding(
            get: { store.form.outboundTime },
            set: { store.setOutboundTime($0) }
        )
    }

    private var outboundArriveBy: Binding<Bool> {
        Binding(
            get: { store.form.outboundArriveBy },
            set: { store.setOutboundArriveBy($0) }
        )
    }

    private var returnEnabled: Binding<Bool> {
        Binding(
            get: { store.form.returnEnabled },
            set: { store.setReturnEnabled($0) }
        )
    }

    private var returnTime: Binding<Date> {
        Binding(
            get: { store.form.returnTime },
            set: { store.setReturnTime($0) }
        )
    }

    private var returnArriveBy: Binding<Bool> {
        Binding(
            get: { store.form.returnArriveBy },
            set: { store.setReturnArriveBy($0) }
        )
    }

    private var maximumTransfers: Binding<Int> {
        Binding(
            get: { store.form.maximumTransfers },
            set: { store.setMaximumTransfers($0) }
        )
    }

    private var directOnly: Binding<Bool> {
        Binding(
            get: { store.form.directOnly },
            set: { store.setDirectOnly($0) }
        )
    }

    private var outboundTimeZone: TimeZone {
        store.form.outboundTimeZoneIdentifier.flatMap(TimeZone.init(identifier:))
            ?? .autoupdatingCurrent
    }

    private var returnTimeZone: TimeZone {
        store.form.returnTimeZoneIdentifier.flatMap(TimeZone.init(identifier:))
            ?? .autoupdatingCurrent
    }

    private func placeButton(
        title: String,
        placeName: String?,
        role: RailPlacePickerRole
    ) -> some View {
        let nameCapHalfHeight = nameCapHalfHeight
        return Button {
            presentedPicker = role
        } label: {
            // The dot follows the station name's first line, not the label-and-name block, so it
            // stays on the name as the label or a wrapped name changes the block's height.
            HStack(alignment: .routeStationName, spacing: TrainTrackerSpacing.space12) {
                routeDot(for: role)
                    .frame(width: LayoutMetrics.iconRailWidth)
                    .alignmentGuide(.routeStationName) { $0[VerticalAlignment.center] + nameCapHalfHeight }
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.ttTextSecondary)
                    Text(placeName ?? JourneySearchCopy.Form.choose)
                        .font(placeName == nil ? .body : .body.weight(.semibold))
                        .foregroundStyle(placeName == nil ? Color.ttTextSecondary : Color.ttTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .alignmentGuide(.routeStationName) { $0[.firstTextBaseline] }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, TrainTrackerSpacing.space8)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(JourneySearchCopy.Form.placeLabel(title: title, placeName: placeName))
        .accessibilityHint(JourneySearchCopy.Form.placePickerHint)
    }

    /// The origin is a ring and the destination a filled ink dot, as on the tickets.
    private func routeDot(for role: RailPlacePickerRole) -> some View {
        Group {
            if role == .origin {
                Circle()
                    .strokeBorder(Color.ttRouteActive, lineWidth: 3)
                    .frame(width: routeDotSize, height: routeDotSize)
            } else {
                Circle()
                    .fill(Color.ttTextBrand)
                    .frame(width: routeDotSize, height: routeDotSize)
            }
        }
        .anchorPreference(key: RouteDotAnchorKey.self, value: .center) { [role: $0] }
        .accessibilityHidden(true)
    }
}

private extension VerticalAlignment {
    /// The first baseline of a route row's station name.
    enum RouteStationName: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.firstTextBaseline] }
    }

    static let routeStationName = VerticalAlignment(RouteStationName.self)
}

private struct RouteDotAnchorKey: PreferenceKey {
    static let defaultValue: [RailPlacePickerRole: Anchor<CGPoint>] = [:]

    static func reduce(value: inout [RailPlacePickerRole: Anchor<CGPoint>], nextValue: () -> [RailPlacePickerRole: Anchor<CGPoint>]) {
        value.merge(nextValue()) { current, _ in current }
    }
}
