import SwiftUI
import XCTest
@testable import TrainTracker

/// Writes the coverage row and notice to PNG at phone and tablet widths, in light and dark and at
/// the default and largest text sizes, so wrapping and alignment can be inspected side by side.
/// Skipped unless `COVERAGE_RENDER_DIR` is set (pass `TEST_RUNNER_COVERAGE_RENDER_DIR` to xcodebuild).
@MainActor
final class JourneyCoverageRenderTests: XCTestCase {
    func testRenderCoverageDisclosureSheets() throws {
        guard let directory = ProcessInfo.processInfo.environment["COVERAGE_RENDER_DIR"] else {
            throw XCTSkip("Set COVERAGE_RENDER_DIR to render the coverage sheets.")
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for (name, width) in [("phone", 402.0), ("tablet", 760.0)] {
            for scheme in [ColorScheme.light, .dark] {
                for (sizeName, size) in [("default", DynamicTypeSize.large), ("largest", .accessibility5)] {
                    let renderer = ImageRenderer(content: Sheet()
                        .frame(width: width)
                        .environment(\.colorScheme, scheme)
                        .environment(\.dynamicTypeSize, size))
                    renderer.scale = 2
                    let image = try XCTUnwrap(renderer.uiImage)
                    let file = folder.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light")-\(sizeName).png")
                    try XCTUnwrap(image.pngData()).write(to: file)
                }
            }
        }
    }

    private struct Sheet: View {
        typealias State = JourneyCoverage.FeatureState

        private var coverages: [JourneyCoverage] {
            let all = JourneyCoverage.Feature.allCases
            return [
                JourneyCoverage(features: Dictionary(uniqueKeysWithValues: all.map {
                    ($0, State(support: .connected, availability: .observed))
                })),
                JourneyCoverage(features: [
                    .delays: State(support: .connected), .cancellations: State(support: .connected),
                    .position: State(support: .notProvided),
                ]),
                JourneyCoverage(
                    features: [.position: State(support: .connected, availability: .observed)],
                    scopeName: "PID regional rail", limitationCodes: ["regionalScope"]
                ),
                JourneyCoverage(features: Dictionary(uniqueKeysWithValues: all.map {
                    ($0, State(support: .notProvided))
                })),
                .unconfirmed,
                .unavailable,
            ]
        }

        var body: some View {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space16) {
                TrainTrackerNotice(
                    JourneySearchCopy.Coverage.varies,
                    message: JourneySearchCopy.Coverage.variesDetail(gaps: 1, total: 2),
                    systemImage: "info.circle", tone: .informational
                )
                TrainTrackerNotice(
                    JourneySearchCopy.Coverage.unavailableNow,
                    message: JourneySearchCopy.Coverage.unavailableDetail(trains: 2),
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath", tone: .warning
                ) {
                    Button(JourneySearchCopy.Coverage.checkAgain) {}
                }
                ForEach(Array(coverages.enumerated()), id: \.offset) { _, coverage in
                    JourneyCoverageRow(disclosure: JourneyCoverageDisclosure(coverage: coverage))
                        .padding(LayoutMetrics.cardInset)
                        .trainTrackerSurface(radius: TrainTrackerRadius.group)
                }
            }
            .padding(LayoutMetrics.pageInset)
            .background(Color.ttBackgroundCanvas)
        }
    }
}
