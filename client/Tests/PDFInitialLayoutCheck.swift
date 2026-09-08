// Run from the repository root:
// xcrun swiftc -swift-version 6 -module-cache-path /tmp/paperchat-swift-cache \
//   client/PaperChat/Models.swift client/PaperChat/PDFKitView.swift \
//   client/Tests/PDFInitialLayoutCheck.swift -o /tmp/paperchat-pdf-layout-check
// /tmp/paperchat-pdf-layout-check
import AppKit
import PDFKit
import SwiftUI

@main
@MainActor
struct PDFInitialLayoutCheck {
    final class State {
        var page = 0
        var scale = 0.0
        var offset = 0.0
    }

    static func settle(_ window: NSWindow) {
        for _ in 0..<10 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    static func findPDFView(_ view: NSView) -> PDFView? {
        if let pdf = view as? PDFView { return pdf }
        return view.subviews.lazy.compactMap { findPDFView($0) }.first
    }

    static func main() {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("paperchat-layout-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = PDFDocument()
        let image = NSImage(size: NSSize(width: 612, height: 792))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 612, height: 792).fill()
        image.unlockFocus()
        document.insert(PDFPage(image: image)!, at: 0)
        precondition(document.write(to: url))

        for savedScale in [0.0, 1.75] {
            let state = State()
            state.scale = savedScale
            let root = PDFKitView(
                url: url,
                pageIndex: Binding(get: { state.page }, set: { state.page = $0 }),
                zoomScale: Binding(get: { state.scale }, set: { state.scale = $0 }),
                scrollOffset: Binding(get: { state.offset }, set: { state.offset = $0 }),
                viewportRange: .constant(.full), selectedText: .constant(nil),
                selectionSnapshot: .constant(nil), highlightTarget: nil,
                viewportTarget: nil, documentStructure: nil, isImmersive: false,
                isInspectorPresented: false, bottomOverlayInset: 0,
                thumbnailInteractionToken: UUID(), onCompactPresentationChange: { _ in }
            )
            let host = NSHostingView(rootView: root)
            host.frame = .zero
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            precondition(state.scale == savedScale, "Unattached layout persisted a provisional scale")

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            settle(window)
            let pdf = findPDFView(host)!
            let fit = pdf.scaleFactorForSizeToFit
            precondition(fit > 0.5, "Final viewport did not lay out")
            precondition(abs(pdf.scaleFactor - (savedScale > 0 ? savedScale : fit)) < 0.02,
                         "Initial scale did not use the final viewport or saved zoom")
            precondition(abs(pdf.maxScaleFactor - fit * 8) < 0.02,
                         "Zoom ceiling used the provisional viewport")

            let previousScale = pdf.scaleFactor
            window.setContentSize(NSSize(width: 1200, height: 900))
            settle(window)
            precondition(abs(pdf.maxScaleFactor - pdf.scaleFactorForSizeToFit * 8) < 0.02,
                         "Resizing did not refresh the zoom range")
            precondition(abs(pdf.scaleFactor - previousScale) < 0.02,
                         "Resizing unexpectedly reset the reading zoom")
            pdf.scaleFactor = pdf.maxScaleFactor
            precondition(pdf.scaleFactor > pdf.scaleFactorForSizeToFit * 7.9,
                         "Maximum zoom remains restricted")
            window.close()
        }
        print("PDF initial layout checks passed (new document, saved zoom, resize, maximum zoom)")
    }
}
