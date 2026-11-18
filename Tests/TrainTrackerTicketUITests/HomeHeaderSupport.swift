import UIKit
import XCTest

extension XCUIApplication {
    /// On iPad the initial destination can be the saved journey overview. Select its
    /// passenger leg through the same control a traveler sees before following the train.
    @MainActor
    func openSeededTrainDetailIfNeeded() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let details = buttons["Train Details and Stops"].firstMatch
        if details.waitForExistence(timeout: 3), details.isHittable { details.tap() }
    }

    /// A split view can retain another column's scroll view outside the visible detail.
    /// Use the candidate with the most content actually inside the window.
    @MainActor
    func visibleJourneyPanel(identifiers: [String]) -> XCUIElement {
        let panels = scrollViews.matching(NSPredicate(format: "identifier IN %@", identifiers))
        let window = windows.firstMatch.frame
        func area(_ element: XCUIElement) -> CGFloat {
            let visible = element.frame.intersection(window)
            return visible.isNull ? 0 : visible.width * visible.height
        }
        return panels.allElementsBoundByIndex.max { lhs, rhs in
            let leftArea = area(lhs), rightArea = area(rhs)
            return leftArea == rightArea ? lhs.frame.maxX < rhs.frame.maxX : leftArea < rightArea
        } ?? panels.firstMatch
    }

    /// A selected train can be in the tablet detail, a floating panel or a compact drawer.
    /// Drag through the visible part of its own column instead of scrolling the sidebar.
    @MainActor
    func revealTrainAction(_ identifier: String) -> XCUIElement {
        let action = buttons[identifier].firstMatch
        let window = windows.firstMatch
        let panel = visibleJourneyPanel(identifiers: ["journeyDrawerScroll", "journeySidePanel"])
        guard panel.waitForExistence(timeout: 4) else { return action }
        if UIDevice.current.userInterfaceIdiom == .pad {
            // The iPad split-view AX tree can report an invalid hit point (-1,-1) for this
            // visible grabber. Tap the actual rendered control inside its detail column.
            let grabber = buttons["journeyDrawerGrabber"].firstMatch
            for _ in 0..<2 where grabber.exists && grabber.value as? String != "Full height" {
                guard tapVisibleJourneyAction(grabber) else { break }
            }
        } else {
            if action.exists, action.isHittable, window.frame.contains(CGPoint(x: action.frame.midX, y: action.frame.midY)) {
                return action
            }
            expandJourneyPanel()
        }
        for _ in 0..<15 {
            let visible = panel.frame.intersection(window.frame).insetBy(dx: 12, dy: 16)
            if action.exists, visible.contains(CGPoint(x: action.frame.midX, y: action.frame.midY)),
               UIDevice.current.userInterfaceIdiom == .pad || action.isHittable { break }
            guard !visible.isEmpty else { break }
            let scrollUp = !action.exists || action.frame.midY > visible.midY
            let x = visible.minX + visible.width * (UIDevice.current.userInterfaceIdiom == .pad ? 0.75 : 0.5) - window.frame.minX
            let startY = visible.minY + visible.height * (scrollUp ? 0.77 : 0.30) - window.frame.minY
            let endY = visible.minY + visible.height * (scrollUp ? 0.36 : 0.71) - window.frame.minY
            let origin = window.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(.init(dx: x, dy: startY)).press(forDuration: 0.10,
                thenDragTo: origin.withOffset(.init(dx: x, dy: endY)))
        }
        return action
    }

    @MainActor
    func tapVisibleJourneyAction(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        if UIDevice.current.userInterfaceIdiom == .pad {
            let window = windows.firstMatch, rect = element.frame
            let point = CGPoint(x: rect.midX, y: rect.midY)
            guard !rect.isEmpty, window.frame.contains(point) else { return false }
            window.coordinate(withNormalizedOffset: .zero).withOffset(.init(
                dx: point.x - window.frame.minX, dy: point.y - window.frame.minY)).tap()
            return true
        }
        guard element.isHittable else { return false }
        element.tap()
        return true
    }

    /// Map refresh is part of the status cluster; the plain scrolling fallback uses its bar.
    @MainActor
    var journeyRefresh: XCUIElement {
        buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "journeyTrustMark", "Refresh journey")).firstMatch
    }

    /// A My Trips header action. With one train or none the actions are buttons; with several
    /// trains they share the More menu, which this opens first.
    @MainActor
    func homeAction(_ identifier: String, timeout: TimeInterval = 5) -> XCUIElement {
        let direct = buttons[identifier]
        if direct.waitForExistence(timeout: timeout) { return direct }
        let more = buttons["moreFromTrips"]
        if more.exists { more.tap() }
        return buttons[identifier]
    }

    /// Whether My Trips is on screen, however many trains its header is carrying.
    @MainActor
    var isShowingHome: Bool {
        buttons["addJourneyFromTrips"].exists || buttons["moreFromTrips"].exists
    }

    /// The train My Trips leads with: its ticket in the panel over the map on iPhone, its
    /// highlighted card in the list elsewhere.
    @MainActor
    func leadingTrain(_ tripID: String, timeout: TimeInterval = 10) -> XCUIElement {
        let ticket = descendants(matching: .any).matching(identifier: "journeyTicket-\(tripID)").firstMatch
        return ticket.waitForExistence(timeout: timeout) ? ticket : buttons["highlightedTrain-\(tripID)"]
    }

    /// On iPhone the journey and the lists under it rest in a panel over the map. Pulls it to
    /// full height so its content scrolls; does nothing where there is no panel.
    @MainActor
    func expandJourneyPanel() {
        let details = buttons["journeyExpandDetails"]
        if details.exists {
            if details.value as? String != "Expanded" { details.tap() }
            return
        }
        let grabber = descendants(matching: .any).matching(identifier: "journeyDrawerGrabber").firstMatch
        guard grabber.exists, grabber.value as? String != "Full height" else { return }
        grabber.tap()
    }

    /// A train's ticket on its own screen: the line ticket over the map on iPhone, the photo
    /// ticket in the scrolling detail elsewhere.
    @MainActor
    func journeyTicket(timeout: TimeInterval = 10) -> XCUIElement {
        let hero = otherElements["liveTripTicketHero"]
        if hero.waitForExistence(timeout: timeout) { return hero }
        return descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'journeyTicket-'")).firstMatch
    }

    /// Brings an element in the journey panel (or, with no panel, the page) into reach.
    @MainActor
    func scrollJourneyContent(to element: XCUIElement, maxSwipes: Int = 18) {
        expandJourneyPanel()
        let panel = visibleJourneyPanel(identifiers: ["journeyDrawerScroll", "journeySidePanel"])
        let viewport = panel.exists ? panel : self
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable {
                let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
                if viewport.frame.intersection(windows.firstMatch.frame).contains(center) { return }
            }
            viewport.swipeUp(velocity: .slow)
        }
    }

    /// Scrolls the journey panel (or the page) to its end.
    @MainActor
    func scrollJourneyContentToEnd(swipes: Int = 14) {
        expandJourneyPanel()
        let panel = visibleJourneyPanel(identifiers: ["journeyDrawerScroll", "journeySidePanel"])
        let viewport = panel.exists ? panel : self
        for _ in 0..<swipes { viewport.swipeUp() }
    }
}
