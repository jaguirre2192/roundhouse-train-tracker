import SwiftUI
import UIKit
import XCTest
@testable import TrainTracker

/// Guards the light-mode contrast defect found in the 2026-08-24 UI/UX audit: small teal
/// operational text measured 2.97:1 on the brand-subtle recommended result card.
final class TrainTrackerColorContrastTests: XCTestCase {
    private static let textThreshold = 4.5

    /// The non-ink surfaces that render small operational or cancellation text.
    private static let operationalSurfaces: [(name: String, color: Color)] = [
        ("canvas", .ttBackgroundCanvas),
        ("surface", .ttBackgroundSurface),
        ("elevated", .ttBackgroundElevated),
        ("whitePage", .ttBackgroundWhitePage),
        ("groupOnWhite", .ttBackgroundGroupOnWhite),
        ("brandSubtle", .ttBackgroundBrandSubtle)
    ]

    func testOperationalTextClearsWCAGOnEveryLightSurface() {
        assertOperationalTextClearsTextThreshold(in: .light)
    }

    func testOperationalTextClearsWCAGOnEveryDarkSurface() {
        assertOperationalTextClearsTextThreshold(in: .dark)
    }

    func testCancellationTextStaysLegibleOnLiftedAppSurfaces() {
        // Canceled journey stubs and search/review labels use this text tint. Lifting the dark
        // page must keep those labels readable, including on the recommended result surface.
        for style in [UIUserInterfaceStyle.light, .dark] {
            for surface in Self.operationalSurfaces {
                let ratio = Self.contrastRatio(.ttStatusCancelled, surface.color, style: style)
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    Self.textThreshold,
                    "Cancellation text on \(surface.name) measured \(ratio) in \(style == .light ? "light" : "dark") mode"
                )
            }
        }
    }

    func testRecommendedResultCardIsTheTightestOperationalTextPairing() {
        // The recommended card is the surface the audit flagged, so keep it explicitly covered.
        for style in [UIUserInterfaceStyle.light, .dark] {
            let ratio = Self.contrastRatio(
                .ttTextOperational,
                .ttBackgroundBrandSubtle,
                style: style
            )
            XCTAssertGreaterThanOrEqual(
                ratio,
                Self.textThreshold,
                "Operational text on the recommended result card measured \(ratio) in \(style == .light ? "light" : "dark") mode"
            )
        }
    }

    func testRouteTealKeepsItsDecorativeValueAndIsDistinctFromTheTextRole() {
        // The fix must not repaint bridges, strokes, station/trip icons, markers, or map geometry.
        XCTAssertEqual(Self.hex(.ttRouteActive, style: .light), 0x4C_95_A3)
        XCTAssertEqual(Self.hex(.ttRouteActive, style: .dark), 0x5D_A5_B2)

        for style in [UIUserInterfaceStyle.light, .dark] {
            XCTAssertNotEqual(
                Self.hex(.ttTextOperational, style: style),
                Self.hex(.ttRouteActive, style: style)
            )
        }
    }

    func testReadinessStateLabelsClearWCAGOnTheBrandSubtleReadinessRow() {
        let cases: [TrainTrackerNotificationAccess] = [.checking, .notRequested, .enabled, .disabled]

        for access in cases {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let ratio = Self.contrastRatio(
                    access.textTint,
                    .ttBackgroundBrandSubtle,
                    style: style
                )
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    Self.textThreshold,
                    "Readiness label for \(access) measured \(ratio) in \(style == .light ? "light" : "dark") mode"
                )
            }
        }
    }

    private func assertOperationalTextClearsTextThreshold(
        in style: UIUserInterfaceStyle,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for surface in Self.operationalSurfaces {
            let ratio = Self.contrastRatio(.ttTextOperational, surface.color, style: style)
            XCTAssertGreaterThanOrEqual(
                ratio,
                Self.textThreshold,
                "Operational text on \(surface.name) measured \(ratio)",
                file: file,
                line: line
            )
        }
    }

    private static func contrastRatio(
        _ foreground: Color,
        _ background: Color,
        style: UIUserInterfaceStyle
    ) -> Double {
        let first = relativeLuminance(of: foreground, style: style)
        let second = relativeLuminance(of: background, style: style)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private static func relativeLuminance(of color: Color, style: UIUserInterfaceStyle) -> Double {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        resolved(color, style: style).getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private static func resolved(_ color: Color, style: UIUserInterfaceStyle) -> UIColor {
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    private static func hex(_ color: Color, style: UIUserInterfaceStyle) -> Int {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        resolved(color, style: style).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let channel = { (value: CGFloat) in Int((value * 255).rounded()) }
        return channel(red) << 16 | channel(green) << 8 | channel(blue)
    }
}
