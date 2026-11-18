import Testing
@testable import TrainTrackerCore

@Test func namespacedIdentifierExposesComponents() {
    let identifier = RailIdentifier(region: "us", source: "amtraker", nativeID: "171:2026-07-20")

    #expect(identifier.isNamespaced)
    #expect(identifier.region == "us")
    #expect(identifier.source == "amtraker")
    #expect(identifier.nativeID == "171:2026-07-20")
}

@Test func malformedIdentifierIsNotNamespaced() {
    let identifier = RailIdentifier(rawValue: "171")

    #expect(!identifier.isNamespaced)
    #expect(identifier.nativeID == nil)
}
