enum TransitousRailModes {
    static let mainline = [
        "HIGHSPEED_RAIL",
        "LONG_DISTANCE",
        "NIGHT_RAIL",
        "REGIONAL_RAIL",
    ]

    static let parameter = mainline.joined(separator: ",")

    static func isMainline(_ value: String) -> Bool {
        mainline.contains(value.uppercased())
    }
}
