import SwiftUI
import TrainTrackerCore

struct JourneyResultsView: View {
    @State private var detailOptionID: String?
    @State private var sortOrder: JourneyResultSortOrder

    let direction: JourneySearchDirection
    let context: JourneyResultsContext
    let page: JourneySearchPage
    let directOnly: Bool
    let maximumTransfers: Int
    let selectedOutbound: JourneyOption?
    let onDirectOnlyChanged: (Bool) -> Void
    let onMaximumTransfersChanged: (Int) -> Void
    let onSelect: (JourneyOption) -> Void
    let onLoadEarlier: () -> Void
    let onLoadLater: () -> Void

    private let options: [JourneyOption]
    private let preferredTrainNumber: String?

    init(
        direction: JourneySearchDirection,
        context: JourneyResultsContext,
        page: JourneySearchPage,
        options: [JourneyOption],
        preferredTrainNumber: String? = nil,
        directOnly: Bool,
        maximumTransfers: Int,
        selectedOutbound: JourneyOption? = nil,
        onDirectOnlyChanged: @escaping (Bool) -> Void,
        onMaximumTransfersChanged: @escaping (Int) -> Void,
        onSelect: @escaping (JourneyOption) -> Void,
        onLoadEarlier: @escaping () -> Void,
        onLoadLater: @escaping () -> Void
    ) {
        #if DEBUG
        let initialDetailOptionID = ProcessInfo.processInfo.arguments.contains(
            "-JourneyResultsPreviewDetail"
        ) ? options.first?.id : nil
        #else
        let initialDetailOptionID: String? = nil
        #endif
        _detailOptionID = State(initialValue: initialDetailOptionID)
        _sortOrder = State(initialValue: .defaultOrder(preferredTrainNumber: preferredTrainNumber))
        self.direction = direction
        self.context = context
        self.page = page
        self.directOnly = directOnly
        self.maximumTransfers = maximumTransfers
        self.selectedOutbound = selectedOutbound
        self.onDirectOnlyChanged = onDirectOnlyChanged
        self.onMaximumTransfersChanged = onMaximumTransfersChanged
        self.onSelect = onSelect
        self.onLoadEarlier = onLoadEarlier
        self.onLoadLater = onLoadLater
        self.options = options
        self.preferredTrainNumber = preferredTrainNumber
    }

    var body: some View {
        List {
            JourneyResultsHeader(context: context, resultCount: rows.count)
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets(
                    top: TrainTrackerSpacing.space16,
                    leading: LayoutMetrics.pageInset,
                    bottom: TrainTrackerSpacing.space8,
                    trailing: LayoutMetrics.pageInset
                ))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            JourneyResultsControls(
                sortOrder: $sortOrder,
                availableSortOrders: JourneyResultSortOrder.availableOrders(preferredTrainNumber: preferredTrainNumber),
                directOnly: directOnly,
                maximumTransfers: maximumTransfers,
                onDirectOnlyChanged: onDirectOnlyChanged,
                onMaximumTransfersChanged: onMaximumTransfersChanged
            )
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets(
                top: TrainTrackerSpacing.space4,
                leading: LayoutMetrics.pageInset,
                bottom: TrainTrackerSpacing.space12,
                trailing: LayoutMetrics.pageInset
            ))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if JourneyImportedTrainPreference.isAvailable(preferredTrainNumber),
               !rows.isEmpty, rows.allSatisfy({ $0.importedTrainMatchLabel == nil }) {
                Text("No train number matches this import. Check the service before tracking.")
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
                    .frame(maxWidth: LayoutMetrics.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(
                        top: TrainTrackerSpacing.space4,
                        leading: LayoutMetrics.pageInset,
                        bottom: TrainTrackerSpacing.space8,
                        trailing: LayoutMetrics.pageInset
                    ))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            paginationButton(
                title: JourneySearchCopy.Results.earlier,
                systemImage: "arrow.up",
                enabled: page.previousCursor != nil,
                action: onLoadEarlier
            )

            if rows.isEmpty {
                Section {
                    ContentUnavailableView(
                        directOnly
                            ? JourneySearchCopy.Results.noDirectTitle
                            : JourneySearchCopy.Results.noTrainsTitle,
                        image: TrainTrackerSymbol.train,
                        description: Text(
                            directOnly
                                ? JourneySearchCopy.Results.noDirectDescription
                                : JourneySearchCopy.Results.noTrainsDescription
                        )
                    )
                }
                .trainTrackerRowSurface()
            } else {
                Section {
                    ForEach(rows) { row in
                        resultRow(row)
                            .frame(maxWidth: LayoutMetrics.contentMaxWidth)
                            .frame(maxWidth: .infinity)
                            .listRowInsets(EdgeInsets(
                                top: TrainTrackerSpacing.space4,
                                leading: LayoutMetrics.pageInset,
                                bottom: TrainTrackerSpacing.space4,
                                trailing: LayoutMetrics.pageInset
                            ))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
            }

            paginationButton(
                title: JourneySearchCopy.Results.later,
                systemImage: "arrow.down",
                enabled: page.nextCursor != nil,
                action: onLoadLater
            )

            if !page.warnings.isEmpty {
                Section(JourneySearchCopy.Results.serviceNotes) {
                    ForEach(page.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.ttStatusDelayed)
                    }
                }
                .trainTrackerRowSurface()
            }

        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .trainTrackerListCanvas()
        .environment(\.defaultMinListRowHeight, 44)
        .trainTrackerTabBarClearance()
        .safeAreaInset(edge: .top, spacing: 0) {
            if direction == .return, let selectedOutbound {
                JourneySelectedOutboundSummary(option: selectedOutbound)
                    .padding(.horizontal, LayoutMetrics.pageInset)
                    .padding(.vertical, TrainTrackerSpacing.space8)
                    .background(.bar)
            }
        }
        .navigationDestination(item: $detailOptionID) { optionID in
            if let option = rows.first(where: { $0.id == optionID })?.option {
                JourneyOptionDetailView(option: option)
            } else {
                ContentUnavailableView(
                    JourneySearchCopy.Results.journeyUnavailable,
                    image: TrainTrackerSymbol.train
                )
            }
        }
    }

    private func resultRow(_ row: JourneyResultRow) -> some View {
        HStack(alignment: .center, spacing: TrainTrackerSpacing.space8) {
            Button {
                onSelect(row.option)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    JourneyOptionRow(option: row.option, presentation: row.presentation)
                    if let matchLabel = row.importedTrainMatchLabel {
                        Text(matchLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.ttTextSecondary)
                            .padding(.horizontal, TrainTrackerSpacing.space16)
                            .padding(.bottom, TrainTrackerSpacing.space16)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.plain)
            .layoutPriority(1)
            .accessibilityLabel(
                JourneySearchCopy.Accessibility.selectResult(
                    direction: direction.title,
                    optionLabel: row.accessibilityLabel
                ).label
            )
            .accessibilityHint(
                JourneySearchCopy.Accessibility.selectResult(
                    direction: direction.title,
                    optionLabel: row.accessibilityLabel
                ).hint
            )

            Button {
                detailOptionID = row.id
            } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .foregroundStyle(Color.ttActionLive)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .frame(width: 44, height: 44)
            .buttonStyle(.plain)
            .accessibilityLabel(
                JourneySearchCopy.Accessibility.resultDetails(
                    departure: row.presentation.time.departure
                ).label
            )
            .accessibilityHint(
                JourneySearchCopy.Accessibility.resultDetails(
                    departure: row.presentation.time.departure
                ).hint
            )
        }
        .trainTrackerSurface(
            color: row.presentation.recommendationBadge == JourneySearchCopy.Status.fastest
                ? Color.ttBackgroundBrandSubtle
                : Color.ttBackgroundSurface,
            radius: TrainTrackerRadius.group
        )
    }

    private func paginationButton(
        title: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(enabled ? Color.ttActionLive : Color.ttTextSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .listRowInsets(EdgeInsets(
            top: TrainTrackerSpacing.space4,
            leading: LayoutMetrics.pageInset,
            bottom: TrainTrackerSpacing.space4,
            trailing: LayoutMetrics.pageInset
        ))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityLabel(
            JourneySearchCopy.Accessibility.resultPage(
                title: title,
                direction: direction.title
            ).label
        )
        .accessibilityHint(
            JourneySearchCopy.Accessibility.resultPage(
                title: title,
                direction: direction.title
            ).hint
        )
    }

    private var rows: [JourneyResultRow] {
        JourneyResultsPresentation.rows(
            options: options,
            sortOrder: sortOrder,
            preferredTrainNumber: preferredTrainNumber
        )
    }
}

struct JourneyMaximumChangesMenuModel {
    static let supportedValues = [1, 2, 3, 4]
}

struct JourneySelectedOutboundSummary: View {
    private let presentation: JourneyOptionPresentation

    init(option: JourneyOption) {
        presentation = JourneyOptionPresentation(option: option)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
            Text(JourneySearchCopy.Results.selectedOutbound)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.ttTextSecondary)
            HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space8) {
                Text(presentation.time.departure)
                Image(systemName: "arrow.right")
                    .accessibilityHidden(true)
                Text(presentation.time.arrival)
                if let day = presentation.time.arrivalDayContext {
                    Text(day)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.ttStatusDelayed)
                }
                Spacer(minLength: TrainTrackerSpacing.space4)
                Text(presentation.changes)
                    .font(.caption)
                    .foregroundStyle(Color.ttTextSecondary)
            }
            .font(.subheadline.weight(.semibold).monospacedDigit())
            Text("\(presentation.originStation) → \(presentation.destinationStation)")
                .font(.caption)
                .foregroundStyle(Color.ttTextSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: LayoutMetrics.contentMaxWidth, alignment: .leading)
        .padding(.horizontal, TrainTrackerSpacing.space12)
        .padding(.vertical, TrainTrackerSpacing.space8)
        .trainTrackerSurface(radius: TrainTrackerRadius.control)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            JourneySearchCopy.Results.selectedOutboundLabel(presentation.accessibilityLabel)
        )
    }
}

struct JourneyReturnRecoveryView<EditDestination: View>: View {
    let outbound: JourneyOption
    let earliestValidTime: Date?
    let timeZoneIdentifier: String?
    let searchUnavailable: Bool
    @ViewBuilder let editDestination: () -> EditDestination
    let onUseEarliestTime: () -> Void
    let onContinueOneWay: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: LayoutMetrics.sectionSpacing) {
                JourneySelectedOutboundSummary(option: outbound)

                ContentUnavailableView(
                    recoveryTitle,
                    systemImage: searchUnavailable ? "wifi.exclamationmark" : "calendar.badge.exclamationmark",
                    description: Text(recoveryDescription)
                )

                if earliestValidTime != nil {
                    Button(action: onUseEarliestTime) {
                        Text(JourneySearchCopy.Results.earliestValidAction)
                            .trainTrackerFullWidthAction()
                    }
                        .trainTrackerPrimaryAction()
                        .accessibilityLabel(JourneySearchCopy.Accessibility.earliestValidReturn.label)
                        .accessibilityHint(JourneySearchCopy.Accessibility.earliestValidReturn.hint)
                }

                NavigationLink {
                    editDestination()
                } label: {
                    Label(JourneySearchCopy.Results.editReturn, systemImage: "calendar")
                        .trainTrackerFullWidthAction()
                }
                .buttonStyle(.bordered)

                Button(action: onContinueOneWay) {
                    Text(JourneySearchCopy.Results.continueOneWay)
                        .trainTrackerFullWidthAction()
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: LayoutMetrics.contentMaxWidth)
            .padding(LayoutMetrics.pageInset)
        }
        .background(Color.ttBackgroundCanvas)
    }

    private var recoveryTitle: String {
        if searchUnavailable { return JourneySearchCopy.Results.returnUnavailableTitle }
        if earliestValidTime != nil { return JourneySearchCopy.Results.returnTooEarlyTitle }
        return JourneySearchCopy.Results.noReturnTitle
    }

    private var recoveryDescription: String {
        if searchUnavailable {
            return JourneySearchCopy.Results.returnUnavailableDescription
        }
        guard let earliestValidTime else {
            return JourneySearchCopy.Results.noReturnDescription
        }
        var format = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: .trainTrackerTime)
        if let timeZoneIdentifier, let timeZone = TimeZone(identifier: timeZoneIdentifier) {
            format.timeZone = timeZone
        }
        return JourneySearchCopy.Results.returnTooEarlyDescription(
            time: earliestValidTime.formatted(format)
        )
    }
}

private extension JourneySearchDirection {
    var title: String {
        switch self {
        case .outbound: JourneySearchCopy.outbound
        case .return: JourneySearchCopy.returnDirection
        }
    }
}
