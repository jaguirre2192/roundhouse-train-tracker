import SwiftUI
import TrainTrackerCore

struct DepartureSearchRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let departure: StopTimeSummary
    var timePresentation = StationBoardTimePresentation(timeZone: .autoupdatingCurrent)
    let isAdding: Bool
    let isTracked: Bool
    let addAction: () -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
                    departureSummary
                    HStack {
                        departureTimeLabel
                        Spacer(minLength: TrainTrackerSpacing.space12)
                        trackButton
                    }
                }
            } else {
                HStack(spacing: TrainTrackerSpacing.space12) {
                    departureSummary
                    Spacer(minLength: TrainTrackerSpacing.space12)
                    // No extra spacing: the Track button's 44 pt hit area already separates it.
                    VStack(alignment: .trailing, spacing: 0) {
                        departureTimeLabel
                        trackButton
                    }
                }
            }
        }
        .padding(.vertical, TrainTrackerSpacing.space4)
        .accessibilityElement(children: .contain)
    }

    private var departureSummary: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
            Text(departure.product)
                .font(.headline)
                .foregroundStyle(Color.ttTextPrimary)
            Text(departure.headsign)
                .font(.subheadline)
                .foregroundStyle(Color.ttTextSecondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: TrainTrackerSpacing.space4) {
                statusLabel
                if !status.isCancelled, let platform = departure.stopTime.displayPlatform {
                    Text("·").accessibilityHidden(true)
                    Text("\(platformNoun) \(platform)")
                }
                if !status.isCancelled, departure.stopTime.didPlatformChange {
                    Text("Changed")
                        .foregroundStyle(Color.ttStatusDelayed)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.ttTextSecondary)
        }
    }

    /// Amtrak stations sign tracks even when the board's feed doesn't label the assignment.
    private var platformNoun: String {
        TrainTrip.isAmtrakOperated(id: departure.tripID, source: "", operatorName: departure.product)
            ? "Track" : departure.stopTime.platformNoun
    }

    private var status: DepartureBoardStatus { DepartureBoardStatus(stopTime: departure.stopTime) }

    /// Cancellation and lateness lead the detail line so a rider scanning the board sees
    /// them before the platform; timetable-only rows say so rather than implying live data.
    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .cancelled:
            Label(RunningStatusWords.canceled, systemImage: "xmark.circle.fill")
                .foregroundStyle(Color.ttStatusCancelled)
                .fontWeight(.semibold)
        case let .delayed(minutes, _):
            Text("+\(minutes) min")
                .foregroundStyle(Color.ttStatusDelayed)
                .fontWeight(.semibold)
        case .onTime:
            Text("On time")
        case .timetableOnly:
            Text("Timetable")
        }
    }

    /// The departure time, with the timetable time struck through beneath it when the
    /// estimate runs five or more minutes late (the same rule as the trip timeline). The
    /// station's zone is stated once in the board footnote, not on every row.
    private var departureTimeLabel: some View {
        VStack(alignment: .trailing, spacing: TrainTrackerSpacing.space2) {
            Text(timePresentation.time(departureTime))
                .font(.headline.monospacedDigit())
                .foregroundStyle(status.isCancelled ? Color.ttTextSecondary : Color.ttTextPrimary)
                .strikethrough(status.isCancelled)
            if case let .delayed(_, scheduled) = status {
                Text(timePresentation.time(scheduled))
                    .font(.caption.monospacedDigit())
                    .strikethrough()
                    .foregroundStyle(Color.ttTextSecondary)
                    .accessibilityLabel("Timetable \(timePresentation.time(scheduled))")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var trackButton: some View {
        Button(action: addAction) {
            if isAdding {
                ProgressView().controlSize(.small)
            } else if isTracked {
                Label("Tracked", systemImage: "checkmark")
            } else {
                Text("Track")
            }
        }
        .buttonStyle(.bordered)
        .tint(Color.ttActionTint)
        .controlSize(.small)
        .disabled(isAdding || isTracked)
        // The small bezel keeps the row light; the margin around it still answers taps so
        // the target meets 44 × 44 pt.
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(.rect)
        .onTapGesture {
            guard !isAdding, !isTracked else { return }
            addAction()
        }
    }

    private var departureTime: Date {
        departure.stopTime.expectedDeparture
            ?? departure.stopTime.scheduledDeparture
            ?? departure.stopTime.expectedArrival
            ?? departure.stopTime.scheduledArrival
            ?? .now
    }
}

/// What a station board row says about a departure's running state.
enum DepartureBoardStatus: Equatable {
    case cancelled
    /// Five or more minutes late, with the timetable time it replaces.
    case delayed(minutes: Int, scheduled: Date)
    /// A live estimate within five minutes of the timetable.
    case onTime
    /// No live estimate: the time shown is the timetable's.
    case timetableOnly

    static let delayThresholdMinutes = 5

    init(stopTime: StopTime) {
        if stopTime.isCancelled {
            self = .cancelled
            return
        }
        guard stopTime.expectedDeparture ?? stopTime.expectedArrival != nil else {
            self = .timetableOnly
            return
        }
        if let scheduled = stopTime.scheduledDeparture ?? stopTime.scheduledArrival,
           let delay = stopTime.delayMinutes, delay >= Self.delayThresholdMinutes {
            self = .delayed(minutes: delay, scheduled: scheduled)
        } else {
            self = .onTime
        }
    }

    var isCancelled: Bool { self == .cancelled }
}
