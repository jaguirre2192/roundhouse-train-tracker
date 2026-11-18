import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum TicketBarcodeScanner {
    static func croppedBarcode(from data: Data, mimeType: String) throws -> Data? {
        for image in try images(from: data, mimeType: mimeType) {
            let request = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: image).perform([request])
            guard let observation = request.results?.max(by: {
                $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
            }), let cropped = crop(image, to: observation.boundingBox) else { continue }
            return png(cropped)
        }
        return nil
    }

    private static func images(from data: Data, mimeType: String) throws -> [CGImage] {
        if mimeType == "application/pdf" {
            guard let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider) else { return [] }
            return scannedPageNumbers(pageCount: document.numberOfPages).compactMap { pageNumber in
                guard let page = document.page(at: pageNumber) else { return nil }
                let box = page.getBoxRect(.mediaBox)
                let scale = min(3, 2200 / max(box.width, box.height))
                let width = max(1, Int(box.width * scale))
                let height = max(1, Int(box.height * scale))
                guard let context = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return nil }
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.scaleBy(x: scale, y: scale)
                context.drawPDFPage(page)
                return context.makeImage()
            }
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        return (0..<CGImageSourceGetCount(source)).compactMap {
            CGImageSourceCreateImageAtIndex(source, $0, nil)
        }
    }

    /// The first pages worth scanning. A document can report zero pages, which must not form `1...0`.
    static func scannedPageNumbers(pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }
        return Array(1...min(pageCount, 6))
    }

    private static func crop(_ image: CGImage, to normalized: CGRect) -> CGImage? {
        let padding: CGFloat = 0.08
        let expanded = normalized.insetBy(dx: -padding, dy: -padding)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let pixels = CGRect(
            x: expanded.minX * width,
            y: (1 - expanded.maxY) * height,
            width: expanded.width * width,
            height: expanded.height * height
        ).integral
        return image.cropping(to: pixels)
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
