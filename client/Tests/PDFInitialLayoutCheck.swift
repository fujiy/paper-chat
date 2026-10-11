// Run from the repository root:
// xcrun swiftc -target "$(uname -m)-apple-macos15.0" -swift-version 6 \
//   -module-cache-path /tmp/paperchat-swift-cache \
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
        var offsetUpdates = 0
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
        for index in 0..<12 { document.insert(PDFPage(image: image)!, at: index) }
        precondition(document.write(to: url))

        for savedScale in [0.0, 1.75] {
            let state = State()
            state.scale = savedScale
            let root = PDFKitView(
                url: url,
                pageIndex: Binding(get: { state.page }, set: { state.page = $0 }),
                bookmarkPageIndex: .constant(0),
                zoomScale: Binding(get: { state.scale }, set: { state.scale = $0 }),
                scrollOffset: Binding(get: { state.offset }, set: {
                    state.offset = $0
                    state.offsetUpdates += 1
                }),
                pagePosition: .constant(0),
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
            pdf.scaleFactor = previousScale
            settle(window)
            let clip = pdf.documentView!.enclosingScrollView!.contentView
            state.offsetUpdates = 0
            for index in 1...100 {
                clip.scroll(to: NSPoint(x: 0, y: CGFloat(index * 4)))
                NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
            }
            precondition(state.offsetUpdates == 0, "Scroll callback published synchronously")
            settle(window)
            precondition(state.offsetUpdates > 0 && state.offsetUpdates <= 2,
                         "A scroll burst was not coalesced: \(state.offsetUpdates) updates")
            precondition(abs(state.offset - clip.bounds.origin.y) <= 0.5,
                         "The final scroll position was lost")
            let updates = state.offsetUpdates
            settle(window)
            precondition(state.offsetUpdates == updates, "Idle geometry republished unchanged state")
            state.offsetUpdates = 0
            let started = Date()
            for index in 1...60 {
                clip.scroll(to: NSPoint(x: 0, y: CGFloat(400 + index * 4)))
                NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            let duration = Date().timeIntervalSince(started)
            settle(window)
            precondition(state.offsetUpdates <= Int(ceil(duration / 0.05)) + 1,
                         "Continuous scrolling exceeded the state update budget")
            precondition(abs(state.offset - clip.bounds.origin.y) <= 0.5,
                         "Continuous scrolling lost the trailing position")
            print("60 scroll events in \(String(format: "%.2f", duration))s: \(state.offsetUpdates) position updates")
            window.close()
        }
        print("PDF initial layout checks passed (new document, saved zoom, resize, maximum zoom, scroll burst, final position)")
    }
}
