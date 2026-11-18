import Foundation

struct AmtrakerStationDTO: Decodable, Sendable {
    let name: String
    let code: String
    let tz: String?
    let lat: Double?
    let lon: Double?
    let city: String?
    let state: String?
    let trains: [String]?
}

struct AmtrakerStopDTO: Decodable, Sendable {
    let name: String
    let code: String
    let tz: String?
    let schArr: String?
    let schDep: String?
    let arr: String?
    let dep: String?
    let status: String?
    let platform: String?
}

struct AmtrakerAlertDTO: Decodable, Sendable {
    let message: String
}

struct AmtrakerTrainDTO: Decodable, Sendable {
    let trainID: String
    let trainNum: String
    let routeName: String
    let provider: String?
    let lat: Double?
    let lon: Double?
    let heading: String?
    let updatedAt: String?
    let lastValTS: String?
    let destName: String?
    let trainState: String?
    let stations: [AmtrakerStopDTO]
    let alerts: [AmtrakerAlertDTO]?
}

struct AmtrakerStaleDTO: Decodable, Sendable {
    let avgLastUpdate: Double?
    let activeTrains: Int?
    let stale: Bool
}

typealias AmtrakerStationResponse = [String: AmtrakerStationDTO]
typealias AmtrakerTrainResponse = [String: [AmtrakerTrainDTO]]
