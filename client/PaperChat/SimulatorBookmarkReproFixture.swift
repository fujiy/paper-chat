#if DEBUG && os(iOS) && targetEnvironment(simulator)
import PDFKit
import UIKit

extension AppModel {
    func loadSimulatorBookmarkReproFixture() {
        let paperID = "simulator-bookmark-position-fixture"
        let pdfURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperChatBookmarkPositionFixture.pdf")

        do {
            try makeFixturePDF().write(to: pdfURL, options: .atomic)
        } catch {
            errorMessage = "Could not create the local bookmark fixture: \(error.localizedDescription)"
            return
        }

        guard let document = PDFDocument(url: pdfURL),
              let selection = document.findString(
                "ANCHOR CONTROL ON PAGE 9",
                withOptions: []
              ).first,
              let page = document.page(at: 8) else {
            errorMessage = "Could not prepare the local bookmark fixture."
            return
        }

        let pageBounds = page.bounds(for: .cropBox)
        let selectionBounds = selection.bounds(for: page)
        let rect = BookmarkSelectionRect(
            pageIndex: 8,
            x: Double((selectionBounds.minX - pageBounds.minX) / pageBounds.width),
            y: Double((selectionBounds.minY - pageBounds.minY) / pageBounds.height),
            width: Double(selectionBounds.width / pageBounds.width),
            height: Double(selectionBounds.height / pageBounds.height)
        )
        let timestamp = ISO8601DateFormatter().string(from: .now)
        let paper = Paper(
            id: paperID,
            title: "Bookmark Position Fixture (12 Pages)",
            authors: [],
            year: "2026",
            identifiers: nil,
            readingState: nil,
            lastOpenedAt: nil,
            starred: false
        )
        let session = PaperSession(paper: paper)
        session.pdfURL = pdfURL
        session.pageIndex = 0
        // Keep the PDF tall enough to scroll. Both bookmark examples use
        // page-relative locations so they work at this simulator's scale.
        session.zoomScale = 0.8
        session.scrollOffset = 0
        session.sidebarMode = .bookmarks
        session.isChatPresented = true
        session.bookmarks = [
            PaperBookmark(
                id: "fixture-offset-bookmark",
                paperID: paperID,
                kind: .page,
                pageIndex: 8,
                pagePosition: 0.55,
                selectedText: nil,
                selectionRects: [],
                note: "Saved at 0.55x scale in a smaller reference viewport.",
                createdAt: timestamp,
                updatedAt: timestamp
            ),
            PaperBookmark(
                id: "fixture-selection-control",
                paperID: paperID,
                kind: .selection,
                pageIndex: 8,
                pagePosition: 0.55,
                selectedText: "ANCHOR CONTROL ON PAGE 9",
                selectionRects: [rect],
                note: nil,
                createdAt: timestamp,
                updatedAt: timestamp
            ),
        ]
        let outlineNode = DocumentOutlineNode(
            id: "fixture-page-9-anchor",
            parentID: nil,
            title: "Page 9 anchor control",
            level: 0,
            anchor: DocumentAnchor(pageIndex: 8, rects: [rect])
        )
        session.mineruDocument = MinerUDocument(outline: [outlineNode], figures: [])
        session.documentStructure = DocumentStructure(
            attachmentKey: "simulator-bookmark-position-fixture",
            status: "ready",
            error: nil,
            parser: "local-fixture",
            parserVersion: "1",
            citationConsolidation: nil,
            updatedAt: timestamp,
            outline: [outlineNode],
            figures: [],
            formulas: [],
            references: [],
            links: []
        )

        openSessions = [session]
        navigationHistory = []
        route = .paper(paperID)
        isSimulatorBookmarkReproMode = true
    }

    private func makeFixturePDF() -> Data {
        let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        return renderer.pdfData { context in
            for pageNumber in 1...12 {
                context.beginPage()

                let headerAttributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 28),
                    .foregroundColor: UIColor.black,
                ]
                (String(format: "PAGE %02d / 12", pageNumber) as NSString)
                    .draw(at: CGPoint(x: 56, y: 48), withAttributes: headerAttributes)
                ("BOOKMARK POSITION FIXTURE" as NSString).draw(
                    at: CGPoint(x: 56, y: 92),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 15, weight: .medium),
                        .foregroundColor: UIColor.darkGray,
                    ]
                )

                if pageNumber == 9 {
                    ("ANCHOR CONTROL ON PAGE 9" as NSString).draw(
                        at: CGPoint(x: 56, y: 148),
                        withAttributes: [
                            .font: UIFont.boldSystemFont(ofSize: 18),
                            .foregroundColor: UIColor.systemBlue,
                        ]
                    )
                }

                for row in 1...16 {
                    let line = String(format: "PAGE %02d  ·  LANDMARK %02d", pageNumber, row)
                    (line as NSString).draw(
                        at: CGPoint(x: 56, y: 208 + CGFloat(row - 1) * 32),
                        withAttributes: [
                            .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                            .foregroundColor: UIColor.darkGray,
                        ]
                    )
                }
            }
        }
    }
}
#endif
