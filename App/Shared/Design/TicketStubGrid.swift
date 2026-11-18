import SwiftUI

/// One labelled fact on a Line Ticket stub, such as "Track · 2".
struct TicketStubField: Identifiable, Equatable {
    static let unavailableValue = "—"

    let id: String
    let label: String
    let value: String
    var usesNumericDigits = false

    var isAvailable: Bool { value != Self.unavailableValue }
}

enum TicketStubFields {
    /// The live stub always has four slots so its columns stay equal. With a linked ticket that
    /// carries both coach and seat, those replace Arrives and Stops left.
    static func live(
        nextStop: String?,
        platformNoun: String,
        platform: String?,
        coach: String?,
        seat: String?,
        arrivalTime: String?,
        destinationCode: String? = nil,
        stopsLeft: Int?
    ) -> [TicketStubField] {
        var fields = [
            field("next", "Next", nextStop),
            field("platform", platformNoun, platform, numeric: true),
        ]
        if let coach = cleaned(coach), let seat = cleaned(seat) {
            fields += [
                field("coach", "Coach", coach, numeric: true),
                field("seat", "Seat", seat, numeric: true),
            ]
        } else {
            fields += [
                // Naming the destination keeps this slot from reading as the next stop's time;
                // "At WAS" stays one line in the four-column stub where "Arrives WAS" wraps.
                field("arrives", cleaned(destinationCode).map { "At \($0)" } ?? "Arrives", arrivalTime, numeric: true),
                field("stopsLeft", "Stops left", stopsLeft.map(String.init), numeric: true),
            ]
        }
        return fields
    }

    private static func field(_ id: String, _ label: String, _ value: String?, numeric: Bool = false) -> TicketStubField {
        TicketStubField(
            id: id,
            label: label,
            value: cleaned(value) ?? TicketStubField.unavailableValue,
            usesNumericDigits: numeric
        )
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// Equal-width columns of small-caps labels over values. Labels and values sit in separate grid
/// rows, so a label that wraps never pushes its value out of line with its neighbours. At
/// accessibility text sizes the fields wrap to two columns, then one at the largest sizes.
struct TicketStubGrid: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let fields: [TicketStubField]
    var labelColor: Color = .ttTextSecondary
    var valueColor: Color = .ttTextPrimary
    var openPlatform: (() -> Void)? = nil

    var body: some View {
        let columnCount = max(dynamicTypeSize >= .accessibility3 ? 1
            : dynamicTypeSize.isAccessibilitySize ? min(2, fields.count) : fields.count, 1)
        if columnCount > 2 {
            // Equal columns across the stub while the widest field fits an equal share; packed
            // columns when it does not. One row only while every label and value fits on one
            // line; on a narrow width (iPhone Duo's outer display beside its side bar) the stub
            // becomes two rows of two rather than wrapping one label or truncating a time.
            ViewThatFits(in: .horizontal) {
                equalColumns
                grid(columnCount: columnCount, singleLine: true)
                grid(columnCount: 2, singleLine: false)
            }
        } else {
            grid(columnCount: columnCount, singleLine: false)
        }
    }

    private var equalColumns: some View {
        EqualWidthColumns(spacing: TrainTrackerSpacing.space8) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                    label(field).fixedSize(horizontal: true, vertical: false)
                    value(field).fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    @ViewBuilder
    private func grid(columnCount: Int, singleLine: Bool) -> some View {
        let rows = stride(from: 0, to: fields.count, by: columnCount).map {
            Array(fields[$0..<min($0 + columnCount, fields.count)])
        }

        Grid(alignment: .leading, horizontalSpacing: TrainTrackerSpacing.space8, verticalSpacing: TrainTrackerSpacing.space2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow(alignment: .bottom) {
                    ForEach(0..<columnCount, id: \.self) { column in
                        if column < row.count {
                            label(row[column]).fixedSize(horizontal: singleLine, vertical: false)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                        }
                    }
                }
                .padding(.top, rowIndex == 0 ? 0 : TrainTrackerSpacing.space12)

                GridRow(alignment: .top) {
                    ForEach(0..<columnCount, id: \.self) { column in
                        if column < row.count {
                            value(row[column]).fixedSize(horizontal: singleLine, vertical: false)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                        }
                    }
                }
            }
        }
    }

    private func label(_ field: TicketStubField) -> some View {
        Text(field.label)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(labelColor)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            .accessibilityHidden(true)
    }

    @ViewBuilder private func value(_ field: TicketStubField) -> some View {
        if field.id == "platform", let openPlatform {
            Button(action: openPlatform) {
                HStack(spacing: TrainTrackerSpacing.space4) {
                    Text(field.value).font(.callout.weight(.semibold)).monospacedDigit()
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption2)
                }
                .foregroundStyle(valueColor)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Platform View, \(field.label) \(field.value)")
            .accessibilityIdentifier("openPlatformBoard")
        } else {
            passiveValue(field)
        }
    }

    private func passiveValue(_ field: TicketStubField) -> some View {
        Text(field.value)
            .font(.callout.weight(.semibold))
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : .snappy, value: field.value)
            .foregroundStyle(field.isAvailable ? valueColor : labelColor)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .accessibilityLabel(field.label)
            .accessibilityValue(field.isAvailable ? field.value : "Unavailable")
    }
}

/// Lays its subviews out as equal-width, leading-aligned columns. Its ideal width is the width at
/// which every column can show the widest subview, so `ViewThatFits` rejects it when an equal
/// share would be too narrow.
private struct EqualWidthColumns: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let gaps = spacing * CGFloat(max(subviews.count - 1, 0))
        let required = (sizes.map(\.width).max() ?? 0) * CGFloat(subviews.count) + gaps
        let height = sizes.map(\.height).max() ?? 0
        guard let width = proposal.width, width.isFinite else {
            return CGSize(width: required, height: height)
        }
        return CGSize(width: max(width, required), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let gaps = spacing * CGFloat(subviews.count - 1)
        let columnWidth = (bounds.width - gaps) / CGFloat(subviews.count)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(index) * (columnWidth + spacing), y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: columnWidth, height: bounds.height)
            )
        }
    }
}

#Preview("Ticket Stub Grid") {
    TicketStubGrid(fields: TicketStubFields.live(
        nextStop: "WIL", platformNoun: "Track", platform: "2",
        coach: "6", seat: "14A", arrivalTime: "5:44 PM", stopsLeft: 3
    ))
    .padding(LayoutMetrics.cardInset)
    .ticketStubStyle()
    .padding(LayoutMetrics.pageInset)
    .background(Color.ttBackgroundSurface)
}
