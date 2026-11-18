import SwiftUI

struct TrainTicketRow<Ticket: TicketSummaryDisplaying>: View {
    let ticket: Ticket

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: ticket.hasArtifact ? "qrcode" : "envelope.badge")
                .font(.title3)
                .foregroundStyle(Color.ttBackgroundBrand)
                .frame(width: 34, height: 34)
                .background(
                    Color.ttBackgroundBrandSubtle,
                    in: RoundedRectangle(cornerRadius: TrainTrackerRadius.icon, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(ticket.displayTitle)
                    .font(.headline)
                    .foregroundStyle(Color.ttTextPrimary)
                    .lineLimit(2)
                Text(ticket.route ?? ticket.subject)
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.ttTextSecondary.opacity(0.72))
        }
        .padding(16)
        .railTicketStyle()
        .railUpdateSheen(updateKey: ticket.receivedAtSortKey)
        .contentShape(Rectangle())
    }
}
