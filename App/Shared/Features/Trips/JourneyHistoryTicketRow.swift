import SwiftUI

/// A boarding date on the tear-off stub, with the actual journey and service on the ticket.
struct JourneyHistoryTicketRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var dateWidth: CGFloat = 45
    let ticket: JourneyHistoryTicket
    let featured: Bool

    var body: some View {
        Group {
            if featured {
                JourneyHistoryInkTicket(ticket: ticket)
            } else {
                paperTicket
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ticket.origin) to \(ticket.destination)")
        .accessibilityValue([ticket.fullDate, ticket.timeText, ticket.service, ticket.cityScope, ticket.disruption?.text]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private var paperTicket: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                    Text(ticket.fullDate)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.ttTextSecondary)
                    details
                }
            } else {
                HStack(spacing: TrainTrackerSpacing.space12) {
                    VStack(spacing: TrainTrackerSpacing.space2) {
                        Text(ticket.day)
                            .font(.title.weight(.semibold).monospacedDigit())
                        Text(ticket.weekday)
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                    }
                    .foregroundStyle(Color.ttTextBrand)
                    .frame(width: dateWidth)

                    Rectangle()
                        .fill(Color.clear)
                        .overlay {
                            GeometryReader { proxy in
                                Path { path in
                                    path.move(to: CGPoint(x: 0.5, y: 0))
                                    path.addLine(to: CGPoint(x: 0.5, y: proxy.size.height))
                                }
                                .stroke(Color.ttTextSecondary.opacity(0.48),
                                        style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 4]))
                            }
                        }
                        .frame(width: 1)

                    details
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.ttTextSecondary)
                }
            }
        }
        .padding(LayoutMetrics.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .ticketStubStyle()
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                Text(ticket.origin)
                HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space4) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.ttTextSecondary)
                    Text(ticket.destination)
                }
            }
            .font(.headline)
            .foregroundStyle(Color.ttTextBrand)

            if let scope = ticket.cityScope {
                Text(scope)
                    .font(.caption)
                    .foregroundStyle(Color.ttTextSecondary)
            }
            serviceAndTime
                .font(.subheadline)
                .foregroundStyle(Color.ttTextSecondary)
            if let status = ticket.disruption {
                Text(status.text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(status.kind.color)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var serviceAndTime: some View {
        if let time = ticket.timeText {
            // Keep the station clock, meridiem and zone as a unit when it moves to its own line.
            let clock = Text(verbatim: time.replacingOccurrences(of: " ", with: "\u{00a0}"))
                .monospacedDigit()
            if ticket.service.isEmpty {
                clock
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space4) {
                        Text(ticket.service)
                        Text(verbatim: "·")
                        clock
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                        Text(ticket.service)
                        clock
                    }
                }
            }
        } else if !ticket.service.isEmpty {
            Text(ticket.service)
        }
    }
}
