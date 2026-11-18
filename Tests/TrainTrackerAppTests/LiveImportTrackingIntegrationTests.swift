import XCTest
@testable import TrainTracker

/// Independent opt-in cases: one unavailable country must not hide the other results.
@MainActor
final class LiveImportTrackingIntegrationTests: XCTestCase {
    func testLiveSlovakiaBratislavaTrnava() async throws {
        try await LiveImportTrackingFlow.run(.init(
            label: "SK Bratislava–Trnava", origin: .init("Bratislava hlavná stanica", "Bratislava hlavná stanica", "SK"),
            destination: .init("Trnava", "Trnava", "SK", ticketName: "Trnava, Slovakia", nativeID: "sk-zsr_5613676"), startsNextMorning: false
        ), in: self)
    }

    func testLiveSlovakiaBratislavaTrencin() async throws {
        try await LiveImportTrackingFlow.run(.init(
            label: "SK Bratislava–Trenčín", origin: .init("Bratislava hlavná stanica", "Bratislava hlavná stanica", "SK"),
            destination: .init("Trenčín", "Trenčín", "SK", nativeID: "sk-zsr_5613866"), startsNextMorning: false
        ), in: self)
    }

    func testLiveSlovakiaBratislavaZilina() async throws {
        try await LiveImportTrackingFlow.run(.init(
            label: "SK Bratislava–Žilina", origin: .init("Bratislava hlavná stanica", "Bratislava hlavná stanica", "SK"),
            destination: .init("Žilina", "Žilina", "SK", nativeID: "sk-zsr_5617915"), startsNextMorning: false
        ), in: self)
    }

    func testLiveCrossBorderSlovakiaUkraine() async throws {
        try await LiveImportTrackingFlow.run(.init(
            label: "SK–UA Bratislava–Uzhhorod", origin: .init("Bratislava hlavná stanica", "Bratislava hlavná stanica", "SK"),
            destination: .init("Uzhhorod", "Uzhhorod", "UA")
        ), in: self)
    }

    func testLiveSerbiaBeogradPetrovaradin() async throws {
        try await LiveImportTrackingFlow.run(.init(
            label: "RS Beograd–Petrovaradin official", origin: .init("Beograd Centar", "Beograd Centar-PROKOP", "RS"),
            destination: .init("Petrovaradin", "Petrovaradin", "RS"), startsNextMorning: false
        ), in: self)
    }

    func testLiveSerbiaPetrovaradinBeograd() async throws {
        try await LiveImportTrackingFlow.run(.init(
            label: "RS Petrovaradin–Beograd official", origin: .init("Petrovaradin", "Petrovaradin", "RS"),
            destination: .init("Beograd Centar", "Beograd Centar-PROKOP", "RS"), startsNextMorning: false
        ), in: self)
    }

    func testLiveAmtrakTicketImportSaveReloadAndRefresh() async throws {
        try await LiveImportTrackingFlow.run(.init(
            label: "US New York–Washington", origin: .init("New York Penn", "NEW YORK PENN STATION", "US"),
            destination: .init("Washington Union", "Washington Union Station", "US"),
            operatorContains: "Amtrak", startsNextMorning: false
        ), in: self)
    }

    func testLiveFranceParisLyon() async throws {
        try await LiveImportTrackingFlow.run(.init(
            label: "FR Paris–Lyon", origin: .init("Paris Gare de Lyon", "Paris Gare de Lyon", "FR"),
            destination: .init("Lyon Part Dieu", "Lyon Part Dieu", "FR")
        ), in: self)
    }

    func testLiveBelgiumBrusselsGent() async throws {
        try await LiveImportTrackingFlow.run(.init(
            label: "BE Brussels–Gent", origin: .init("Bruxelles Midi", "Bruxelles Midi", "BE"),
            destination: .init("Gent-Sint-Pieters", "Gent-Sint-Pieters", "BE")
        ), in: self)
    }

    func testLiveGermanyBerlinHamburg() async throws {
        try await LiveImportTrackingFlow.run(.init(
            label: "DE Berlin–Hamburg", origin: .init("Berlin Hbf", "Berlin Hbf", "DE"),
            destination: .init("Hamburg Hbf", "Hamburg Hbf", "DE")
        ), in: self)
    }

    func testLiveAustriaViennaSalzburg() async throws {
        try await LiveImportTrackingFlow.run(.init(
            label: "AT Vienna–Salzburg", origin: .init("Wien Hbf", "Wien Hbf", "AT"),
            destination: .init("Salzburg Hbf", "Salzburg Hauptbahnhof", "AT")
        ), in: self)
    }

    func testLiveSwitzerlandZurichBern() async throws {
        try await LiveImportTrackingFlow.run(.init(
            label: "CH Zurich–Bern", origin: .init("Zürich HB", "Zürich HB", "CH"),
            destination: .init("Bern", "Bern", "CH")
        ), in: self)
    }

    func testLiveNetherlandsAmsterdamRotterdam() async throws {
        try await LiveImportTrackingFlow.run(.init(
            label: "NL Amsterdam–Rotterdam", origin: .init("Amsterdam Centraal", "Amsterdam-Centraal", "NL"),
            destination: .init("Rotterdam Centraal", "Rotterdam Centraal", "NL")
        ), in: self)
    }

    func testLiveSpainMadridBarcelonaRenfe() async throws {
        try await LiveImportTrackingFlow.run(.init(
            label: "ES Madrid–Barcelona RENFE",
            origin: .init("Madrid-Puerta de Atocha-Almudena Grandes", "Madrid-Puerta de Atocha-Almudena Grandes", "ES",
                          nativeID: "es-RENFE-Larga-Distancia-y-AVE_60000"),
            destination: .init("Barcelona Sants", "Barcelona (Sants)", "ES", ticketName: "Barcelona Sants",
                               nativeID: "es-Ouigo_007171801"),
            operatorContains: "RENFE", startsNextMorning: false
        ), in: self)
    }

    func testLivePortugalLisbonPorto() async throws {
        try await LiveImportTrackingFlow.run(.init(
            label: "PT Lisbon–Porto", origin: .init("Lisboa Oriente", "Lisboa Oriente", "PT"),
            destination: .init("Porto Campanha", "Porto Campanha", "PT")
        ), in: self)
    }

    func testLiveAustraliaNewcastleMaitland() async throws {
        try await LiveImportTrackingFlow.run(.init(
            label: "AU Newcastle–Maitland", origin: .init("Newcastle Interchange", "Newcastle Interchange", "AU"),
            destination: .init("Maitland Station", "Maitland Station", "AU"), startsNextMorning: false
        ), in: self)
    }

    func testLiveCrossBorderFranceBelgium() async throws {
        try await LiveImportTrackingFlow.run(.init(
            label: "FR–BE Paris–Brussels", origin: .init("Paris Gare du Nord", "Paris Gare du Nord", "FR",
                nativeID: "fr-horaires-sncf_FR::LMU:ab071640-cb0a-11e8-8bfa-f784c1c7c611:"),
            destination: .init("Bruxelles Midi", "Bruxelles Midi", "BE")
        ), in: self)
    }

    func testLiveCrossBorderBelgiumNetherlands() async throws {
        try await LiveImportTrackingFlow.run(.init(
            label: "BE–NL Brussels–Amsterdam", origin: .init("Bruxelles Midi", "Bruxelles Midi", "BE"),
            destination: .init("Amsterdam Centraal", "Amsterdam-Centraal", "NL")
        ), in: self)
    }
}
