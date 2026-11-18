import TrainTrackerCore

enum JourneyImportedTrainPreference {
    static func isAvailable(_ trainNumber: String?) -> Bool {
        trainNumber.map { !normalized($0).isEmpty } ?? false
    }

    static func matches(_ option: JourneyOption, trainNumber: String?) -> Bool {
        guard let trainNumber else { return false }
        let target = normalized(trainNumber)
        guard !target.isEmpty else { return false }
        return option.segments.contains { segment in
            guard case let .rail(rail) = segment,
                  let number = rail.trainNumber else { return false }
            let providerNumber = normalized(number)
            guard numbersMatch(providerNumber, target) else { return false }
            var providerProducts = TicketTrainNumberParser.productFamilies(in: rail.product)
            if let numberedProduct = productAndNumber(providerNumber)?.product {
                providerProducts.insert(numberedProduct)
            }
            // A bare number can omit the product; contradictory explicit provider
            // products cannot safely establish the identity of one train.
            guard providerProducts.count <= 1 else { return false }
            if let importedProduct = productAndNumber(target)?.product {
                guard providerProducts.isEmpty || providerProducts == [importedProduct] else { return false }
            }
            return true
        }
    }

    static func ranked(_ options: [JourneyOption], trainNumber: String?) -> [JourneyOption] {
        guard isAvailable(trainNumber) else { return options }
        return options.filter { matches($0, trainNumber: trainNumber) }
            + options.filter { !matches($0, trainNumber: trainNumber) }
    }

    private static func normalized(_ value: String) -> String {
        String(value.uppercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Tickets often print the product separately while providers include it in trainNumber.
    /// Only known products can be omitted; two explicit, different products stay distinct.
    private static func numbersMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard let left = productAndNumber(lhs), let right = productAndNumber(rhs),
              left.number == right.number else { return false }
        return left.product == nil || right.product == nil || left.product == right.product
    }

    private static func productAndNumber(_ value: String) -> (product: String?, number: String)? {
        guard !value.isEmpty else { return nil }
        if value.allSatisfy(\.isNumber) { return (nil, value) }
        for product in ["RJX", "ICE", "TGV", "AVE", "RJ", "IC", "IR", "EC"] where value.hasPrefix(product) {
            let number = String(value.dropFirst(product.count))
            if !number.isEmpty, number.allSatisfy(\.isNumber) { return (product, number) }
        }
        return nil
    }
}
