import SwiftUI

struct AnnualRailPrintView: View {
    let edition: AnnualRailPrint
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var shareItem: TravelLogShareItem?
    @State private var exportFailed = false

    var body: some View {
        GeometryReader { proxy in
            let gutter = LayoutMetrics.pageInset
            let width = max(1, min(proxy.size.width - 2 * gutter, LayoutMetrics.desktopDetailMaxWidth))
            let midX = proxy.frame(in: .global).midX
            let columns = JourneySpreadColumns(
                content: (midX - width / 2)...(midX + width / 2),
                division: JourneySpreadColumns.division(in: proxy, windowMidX: JourneySpreadColumns.innerLandscapeWindowMidX),
                minimum: 295, rightToLeft: layoutDirection == .rightToLeft)
            let upper = JourneyPanelGeometry(proxy).upperFoldBoundary
            if let upper, upper > 190, proxy.size.height - upper > 140 {
                VStack(spacing: 0) {
                    proof
                        .frame(maxWidth: max(100, (upper - 2 * gutter) * Self.aspect))
                        .frame(maxWidth: .infinity)
                        .frame(height: upper)
                    ScrollView { register.padding(gutter) }
                }
            } else if let columns, !typeSize.isAccessibilitySize, proxy.size.width > proxy.size.height || proxy.size.width >= 740 {
                HStack(alignment: .top, spacing: columns.gap) {
                    proof
                        .frame(maxWidth: max(1, (proxy.size.height - 2 * gutter) * Self.aspect))
                        .frame(width: columns.first, alignment: .center)
                        .padding(.vertical, gutter)
                    ScrollView {
                        register.padding(.vertical, gutter)
                    }
                    .frame(width: columns.second)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("annualPrintSpread")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
                        proof
                        register
                    }
                    .frame(maxWidth: 420)
                    .padding(gutter)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Railway Print")
        .navigationBarTitleDisplayMode(.inline)
        .trainTrackerPageBackground()
        .sheet(item: $shareItem) { TravelLogShareSheet(item: $0) }
        .alert("Couldn’t Prepare Your Print", isPresented: $exportFailed) {
            Button("Try Again") { share() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private static var aspect: CGFloat { AnnualRailPrintArtwork.size.width / AnnualRailPrintArtwork.size.height }

    private var proof: some View {
        Color.clear
            .aspectRatio(Self.aspect, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    AnnualRailPrintArtwork(edition: edition)
                        .scaleEffect(proxy.size.width / AnnualRailPrintArtwork.size.width, anchor: .topLeading)
                }
            }
            .overlay { Rectangle().strokeBorder(Color.ttBackgroundBrand.opacity(0.16), lineWidth: 1) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Railway print for \(String(edition.year)), \(edition.rideCountLabel)")
            .accessibilityIdentifier("annualPrintProof")
    }

    private var register: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
            Button(action: share) {
                Label("Share Print", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .trainTrackerPrimaryAction()
            .controlSize(.large)
            .accessibilityIdentifier("shareAnnualPrint")

            LazyVStack(alignment: .leading, spacing: 0) {
                Text("Rides in this print")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.ttTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, TrainTrackerSpacing.space8)
                ForEach(edition.entries.reversed()) { entry in
                    Divider()
                    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                        Text("\(entry.originName) → \(entry.destinationName)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.ttTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(entry.logDayLabel) · \(entry.product)")
                            .font(.footnote)
                            .foregroundStyle(Color.ttTextSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .padding(.vertical, TrainTrackerSpacing.space12)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func share() {
        if let item = TravelLogShareItem(edition: edition) { shareItem = item }
        else { exportFailed = true }
    }
}
