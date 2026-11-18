import SwiftUI

struct JourneyResultsHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let context: JourneyResultsContext
    let resultCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
            Text(context.routeTitle)
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.ttTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space6) {
                    timingLabel
                    resultCountLabel
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: TrainTrackerSpacing.space12) {
                        timingLabel
                        Spacer(minLength: TrainTrackerSpacing.space8)
                        resultCountLabel
                    }

                    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space6) {
                        timingLabel
                        resultCountLabel
                    }
                }
            }
        }
        .frame(maxWidth: LayoutMetrics.contentMaxWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var timingLabel: some View {
        Label(context.timingSummary, systemImage: "calendar")
            .font(.subheadline)
            .foregroundStyle(Color.ttTextSecondary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.85)
    }

    private var resultCountLabel: some View {
        Text(JourneySearchCopy.Results.optionCount(resultCount))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.ttTextOperational)
    }
}

struct JourneyResultsControls: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var sortOrder: JourneyResultSortOrder

    let availableSortOrders: [JourneyResultSortOrder]
    let directOnly: Bool
    let maximumTransfers: Int
    let onDirectOnlyChanged: (Bool) -> Void
    let onMaximumTransfersChanged: (Int) -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                    directControl
                    sortMenu
                    if !directOnly { filtersMenu }
                }
            } else {
                HStack(spacing: TrainTrackerSpacing.space8) {
                    directControl
                    sortMenu
                    if !directOnly { filtersMenu }
                }
            }
        }
        .frame(maxWidth: LayoutMetrics.contentMaxWidth, alignment: .leading)
        .controlSize(.small)
    }

    private var directControl: some View {
        Toggle(
            isOn: Binding(
                get: { directOnly },
                set: { value in onDirectOnlyChanged(value) }
            )
        ) {
            Label(
                JourneySearchCopy.Status.direct,
                systemImage: directOnly ? "checkmark.circle.fill" : "arrow.right"
            )
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(directOnly ? Color.ttActionLive : Color.ttTextPrimary)
        .accessibilityHint(
            directOnly
                ? JourneySearchCopy.Results.directFilterOnHint
                : JourneySearchCopy.Results.directFilterOffHint
        )
    }

    private var filtersMenu: some View {
        Menu {
            Picker(
                JourneySearchCopy.Form.maximumChanges,
                selection: Binding(
                    get: { maximumTransfers },
                    set: { value in onMaximumTransfersChanged(value) }
                )
            ) {
                ForEach(JourneyMaximumChangesMenuModel.supportedValues, id: \.self) { count in
                    Text(JourneySearchCopy.Form.upTo(count)).tag(count)
                }
            }
        } label: {
            Label(JourneySearchCopy.Results.filter, systemImage: "line.3.horizontal.decrease")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(Color.ttTextPrimary)
        .accessibilityLabel(
            "\(JourneySearchCopy.Results.filter), \(JourneySearchCopy.Form.maximumChanges), \(JourneySearchCopy.Form.upTo(maximumTransfers))"
        )
    }

    private var sortMenu: some View {
        Menu {
            Picker(JourneySearchCopy.Results.sortBy, selection: $sortOrder) {
                ForEach(availableSortOrders) { order in
                    Text(order.title).tag(order)
                }
            }
        } label: {
            Label(JourneySearchCopy.Results.sortControl, systemImage: "arrow.up.arrow.down")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(Color.ttTextPrimary)
        .accessibilityLabel("\(JourneySearchCopy.Results.sortBy), \(sortOrder.title)")
    }
}
