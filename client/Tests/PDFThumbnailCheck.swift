// Compile with Models.swift and PDFKitView.swift, using the same Swift 6
// flags as PDFInitialLayoutCheck.swift.
import AppKit
import PDFKit

@main
@MainActor
struct PDFThumbnailCheck {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paperchat-thumbnails-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func writePDF(_ name: String, red: CGFloat) -> URL {
            let url = directory.appendingPathComponent(name)
            var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
            let context = CGContext(url as CFURL, mediaBox: &bounds, nil)!
            for _ in 0..<3 {
                context.beginPDFPage(nil)
                context.setFillColor(red: red, green: 0.2, blue: 0.8, alpha: 1)
                context.fill(bounds)
                context.endPDFPage()
            }
            context.closePDF()
            return url
        }

        let first = PDFThumbnailRenderer(url: writePDF("first.pdf", red: 0))
        let second = PDFThumbnailRenderer(url: writePDF("second.pdf", red: 1))
        let count = await first.pageCount()
        precondition(count == 3)
        let data = await first.thumbnailData(pageIndex: 1)
        let repeated = await first.thumbnailData(pageIndex: 1)
        let other = await second.thumbnailData(pageIndex: 1)
        precondition(data != nil && repeated == data, "Repeated thumbnail request failed")
        precondition(data != other, "Thumbnail cache leaked across documents")
        let image = NSImage(data: data!)!
        precondition(image.size.width > 0 && image.size.height > 0)
        let invalid = await first.thumbnailData(pageIndex: 3)
        precondition(invalid == nil, "Out-of-range page produced a thumbnail")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await first.thumbnailData(pageIndex: 0)
        }
        let cancelledResult = await cancelled.value
        precondition(cancelledResult == nil, "Cancelled thumbnail request was rendered")
        print("PASS: background PDF thumbnails, repeated requests, document isolation, invalid page, cancellation")
    }
}
