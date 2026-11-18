import Foundation

enum TransitousMainlineScope {
    static func acceptsStation(nativeID: String, countryCode: String?) -> Bool {
        let id = nativeID.lowercased()
        let country = countryCode?.uppercased() ?? String(nativeID.prefix(2)).uppercased()
        switch country {
        case "CA":
            return id.hasPrefix("ca-viarail_")
        case "AU":
            return ["regional-trains", "interstate", "nsw-trains", "vline"].contains { id.contains($0) }
        case "FR":
            return !id.contains("ile-de-france-mobilites") && !id.contains("idfm:")
        case "JP":
            return !id.hasPrefix("jp-tokyo-rail_")
        case "NZ":
            return false
        default:
            return true
        }
    }

    static func acceptsDeparture(tripID: String, routeLongName: String?) -> Bool {
        let id = tripID.lowercased()
        if id.contains("_ca-"), !id.contains("_ca-viarail_") { return false }
        if id.contains("_au-"),
           !["regional-trains", "interstate", "nsw-trains", "vline"].contains(where: id.contains) {
            return false
        }
        if id.contains("_jp-tokyo-rail_") || id.contains("_nz-")
            || id.contains("ile-de-france-mobilites") || id.contains("idfm:") { return false }
        if id.contains("_th-"), routeLongName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return false
        }
        return true
    }
}
