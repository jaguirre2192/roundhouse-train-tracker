import Foundation
import PDFKit
import UIKit

/// The locally extracted result of one ticket payload.
struct ParsedTicketImport: Sendable, Hashable {
    let suggestion: TicketRouteSuggestion
    let details: TicketTextDetails
}

/// Host-side, best-effort parsing of a staged share payload. Conservative by design: when
/// extraction is uncertain, this returns fields the person can still correct in the review
/// screen rather than guessing.
enum ShareImportParser {
    private static let maxParsedCharacters = TicketTextDetails.maxCharacters
    /// Scanned PDFs are recognized one rendered page at a time, within a small page budget.
    static let maxScannedPDFPages = 3

    static func parse(
        manifest: ShareManifest,
        payload: Data,
        imageTextRecognizer: any ImageTextRecognizing = VisionImageTextRecognizer()
    ) async -> TicketRouteSuggestion {
        await parseWithDetails(manifest: manifest, payload: payload, imageTextRecognizer: imageTextRecognizer).suggestion
    }

    static func parseWithDetails(
        manifest: ShareManifest,
        payload: Data,
        imageTextRecognizer: any ImageTextRecognizing = VisionImageTextRecognizer()
    ) async -> ParsedTicketImport {
        let text = await extractText(manifest: manifest, payload: payload, imageTextRecognizer: imageTextRecognizer)
        let match = text.flatMap {
            TicketRouteTextHeuristics.match(title: $0, supportingText: [])
        }
        let details = text.map { TicketTextDetails.extract(from: $0, origin: match?.originGuess) } ?? TicketTextDetails()
        let needsJourneyChoice = text.map(TicketRouteTextParser.requiresMultipleJourneyReview) ?? false
        // Dates alone do not make unrelated text a journey; only rail evidence keeps them.
        let departure = match == nil || needsJourneyChoice ? nil : details.departure
        let instant = match == nil || needsJourneyChoice ? nil : details.departureInstant
        let trainNumber = !needsJourneyChoice && details.acceptsTrainNumber(match?.trainNumberGuess)
            ? (match?.trainMatchingIdentifier ?? match?.trainNumberGuess) : nil
        let suggestion = TicketRouteSuggestion(
            id: manifest.id,
            sourceDescription: sourceDescription(for: manifest.kind),
            subtitle: text.map { String($0.prefix(140)) },
            originGuess: match?.originGuess,
            destinationGuess: match?.destinationGuess,
            trainNumberGuess: trainNumber,
            departureDate: instant,
            confidence: match?.confidence,
            evidence: match?.evidence ?? [],
            requiresDepartureTime: departure.map { !$0.hasTime } ?? false,
            departureTimeZoneIdentifier: instant == nil ? nil : details.timeZoneIdentifier,
            departureWallClock: instant == nil ? departure : nil,
            routeReviewReason: needsJourneyChoice ? .multipleJourneys
                : (match?.hasConflictingTrainProducts == true ? .ambiguousTrain : nil)
        )
        return ParsedTicketImport(suggestion: suggestion, details: match == nil ? TicketTextDetails() : details)
    }

    static func extractText(
        manifest: ShareManifest,
        payload: Data,
        imageTextRecognizer: any ImageTextRecognizing
    ) async -> String? {
        switch manifest.kind {
        case .text:
            return String(data: payload, encoding: .utf8).map { String($0.prefix(maxParsedCharacters)) }
        case .url:
            return String(data: payload, encoding: .utf8).map { String($0.prefix(maxParsedCharacters)) }
        case .pdf:
            return await pdfText(payload, imageTextRecognizer: imageTextRecognizer)
        case .image:
            // Best-effort and conservative: OCR failures or a timeout just mean no text-based
            // guess, never an error surfaced to the person reviewing the share.
            guard let recognized = try? await imageTextRecognizer.recognizeText(in: payload) else { return nil }
            return recognized
        case .emailMessage:
            guard let raw = String(data: payload, encoding: .utf8) else { return nil }
            return parseRFC822(raw)
        }
    }

    /// Page text keeps its line boundaries, because route and label parsing depend on them.
    /// Pages without a text layer are rendered and recognized on device, within a page budget.
    private static func pdfText(_ payload: Data, imageTextRecognizer: any ImageTextRecognizing) async -> String? {
        guard let document = PDFDocument(data: payload) else { return nil }
        var pages: [String] = []
        var scannedPages = 0
        var characterCount = 0
        for index in 0..<document.pageCount {
            guard characterCount < maxParsedCharacters, !Task.isCancelled,
                  let page = document.page(at: index) else { break }
            var pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if pageText.isEmpty, scannedPages < maxScannedPDFPages,
               let image = renderedPageImage(page) {
                scannedPages += 1
                pageText = (try? await imageTextRecognizer.recognizeText(in: image)) ?? ""
            }
            guard !pageText.isEmpty else { continue }
            let normalized = pageText.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            pages.append(normalized)
            characterCount += normalized.count
        }
        let combined = pages.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? nil : String(combined.prefix(maxParsedCharacters))
    }

    private static func renderedPageImage(_ page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(3, 2_000 / max(bounds.width, bounds.height))
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox).pngData()
    }

    /// Minimal RFC822 handling: pull the Subject header and the text up to the first blank line
    /// that separates headers from body, rather than a full MIME parse.
    private static func parseRFC822(_ raw: String) -> String {
        var subject = ""
        var lines = raw.components(separatedBy: .newlines)
        for line in lines where line.lowercased().hasPrefix("subject:") {
            subject = String(line.dropFirst("subject:".count)).trimmingCharacters(in: .whitespaces)
            break
        }
        if let blankLineIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            lines = Array(lines[(blankLineIndex + 1)...])
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = ([subject, body].filter { !$0.isEmpty }).joined(separator: "\n")
        return String(combined.prefix(maxParsedCharacters))
    }

    static func sourceDescription(for kind: ShareManifest.Kind) -> String {
        switch kind {
        case .text: "Shared text"
        case .url: "Shared link"
        case .pdf: "Shared PDF"
        case .image: "Shared image"
        case .emailMessage: "Shared email"
        }
    }
}
