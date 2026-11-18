import PDFKit
import SwiftUI

struct TicketAttachmentPreview: View {
    let data: Data
    let mimeType: String

    var body: some View {
        if mimeType == "application/pdf" {
            PDFPreview(data: data)
                .frame(minHeight: 420)
        } else if let image = platformImage(data: data) {
            image
                .resizable()
                .scaledToFit()
                .accessibilityLabel("Original train ticket")
        } else {
            ContentUnavailableView("Preview unavailable", systemImage: "doc")
        }
    }

    private func platformImage(data: Data) -> Image? {
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
    }
}

private struct PDFPreview: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView { configuredPDFView() }
    func updateUIView(_ view: PDFView, context: Context) { view.document = PDFDocument(data: data) }
    private func configuredPDFView() -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }
}
