import Foundation
import TrainTrackerCore

/// Print the rider's two endpoints and the focused call, with a disclosure wherever calls
/// are folded away. Open stretches are anchored to calls so a timetable refresh can add,
/// remove, or retime intermediate stops without closing the stretch the rider is reading.
struct JourneyRouteOutline {
    struct Span: Hashable {
        let fromID: StopTime.ID
        let toID: StopTime.ID
    }

    struct Gap: Identifiable {
        let from: StopTime
        let to: StopTime
        let count: Int

        var id: Span { Span(fromID: from.id, toID: to.id) }
    }

    enum Expansion: Equatable {
        case spans(Set<Span>)
        case all

        static let compact = Self.spans([])

        func opening(_ gap: Gap, remainingGaps: Int) -> Self {
            guard remainingGaps > 1, case .spans(var spans) = self else { return .all }
            spans.insert(gap.id)
            return .spans(spans)
        }
    }

    enum Row: Identifiable {
        case stop(StopTime)
        case gap(Gap)

        enum ID: Hashable {
            case stop(StopTime.ID)
            case gap(Span)
        }

        var id: ID {
            switch self {
            case .stop(let stop): .stop(stop.id)
            case .gap(let gap): .gap(gap.id)
            }
        }
    }

    let rows: [Row]
    let gapCount: Int
    let canCollapse: Bool

    var visibleStops: [StopTime] {
        rows.compactMap {
            guard case .stop(let stop) = $0 else { return nil }
            return stop
        }
    }

    init(stops: [StopTime], focusID: StopTime.ID?, expansion: Expansion = .compact,
         pinned: Set<StopTime.ID> = []) {
        guard stops.count > 3 else {
            rows = stops.map(Row.stop)
            gapCount = 0
            canCollapse = false
            return
        }

        var indices: IndexSet = [0, stops.count - 1]
        for (index, stop) in stops.enumerated() where pinned.contains(stop.id) { indices.insert(index) }
        if let focusID, let index = stops.firstIndex(where: { $0.id == focusID }) {
            indices.insert(index)
        }
        let anchorCount = indices.count
        switch expansion {
        case .all:
            indices.insert(integersIn: stops.indices)
        case .spans(let spans):
            for span in spans {
                guard let start = stops.firstIndex(where: { $0.id == span.fromID }),
                      let end = stops.firstIndex(where: { $0.id == span.toID }),
                      start < end else { continue }
                indices.insert(integersIn: start...end)
            }
        }

        var rows: [Row] = []
        var count = 0
        var previous = 0
        for index in indices {
            if index > previous + 1 {
                let gap = Gap(from: stops[previous], to: stops[index], count: index - previous - 1)
                rows.append(.gap(gap))
                count += 1
            }
            rows.append(.stop(stops[index]))
            previous = index
        }
        self.rows = rows
        gapCount = count
        canCollapse = indices.count > anchorCount
    }
}
