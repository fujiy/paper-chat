import PDFKit
import SwiftUI

#if os(macOS)
struct PDFKitView: NSViewRepresentable {
    let url: URL
    @Binding var pageIndex: Int
    @Binding var zoomScale: Double
    @Binding var scrollOffset: Double
    @Binding var selectedText: String?
    let highlightTarget: PDFHighlightTarget?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PDFView {
        let view = PaperPDFView()
        configure(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        update(view, coordinator: context.coordinator)
    }
}
#else
struct PDFKitView: UIViewRepresentable {
    let url: URL
    @Binding var pageIndex: Int
    @Binding var zoomScale: Double
    @Binding var scrollOffset: Double
    @Binding var selectedText: String?
    let highlightTarget: PDFHighlightTarget?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        configure(view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        update(view, coordinator: context.coordinator)
    }
}
#endif

extension PDFKitView {
    func configure(_ view: PDFView, coordinator: Coordinator) {
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.autoScales = false
        coordinator.observe(view)
        loadDocument(in: view, coordinator: coordinator)
    }

    func update(_ view: PDFView, coordinator: Coordinator) {
        if view.document?.documentURL != url {
            loadDocument(in: view, coordinator: coordinator)
            return
        }
        guard !coordinator.isRestoring else { return }
        if coordinator.lastPageIndex != pageIndex,
           let target = view.document?.page(at: pageIndex) {
            coordinator.isRestoring = true
            view.go(to: target)
            coordinator.lastPageIndex = pageIndex
            coordinator.isRestoring = false
        }
        if zoomScale > 0,
           abs(coordinator.lastScale - zoomScale) > 0.005 {
            coordinator.isRestoring = true
            view.scaleFactor = zoomScale
            coordinator.lastScale = view.scaleFactor
            coordinator.isRestoring = false
        }
        coordinator.applyHighlight(highlightTarget)
    }

    private func loadDocument(in view: PDFView, coordinator: Coordinator) {
        coordinator.isRestoring = true
        view.document = PDFDocument(url: url)
        #if os(macOS)
        view.layoutSubtreeIfNeeded()
        #else
        view.layoutIfNeeded()
        #endif
        let fitScale = max(view.scaleFactorForSizeToFit, 0.1)
        setScaleRange(in: view, fitScale: fitScale)
        view.scaleFactor = zoomScale > 0 ? zoomScale : fitScale
        if let page = view.document?.page(at: pageIndex) {
            view.go(to: page)
        }
        coordinator.lastPageIndex = pageIndex
        coordinator.lastScale = view.scaleFactor
        coordinator.restoreScrollOffset(scrollOffset)
        coordinator.isRestoring = false
        DispatchQueue.main.async {
            coordinator.isRestoring = true
            let laidOutFitScale = max(view.scaleFactorForSizeToFit, 0.1)
            setScaleRange(in: view, fitScale: laidOutFitScale)
            if zoomScale <= 0 {
                view.scaleFactor = laidOutFitScale
                coordinator.lastScale = view.scaleFactor
            }
            coordinator.restoreScrollOffset(scrollOffset)
            coordinator.isRestoring = false
            coordinator.syncState()
            coordinator.applyHighlight(highlightTarget)
        }
    }

    private func setScaleRange(in view: PDFView, fitScale: Double) {
        let minimum = fitScale * 0.5
        let maximum = fitScale * 8

        // Expand the existing range first so neither setter can temporarily
        // leave PDFKit with minMagnification greater than maxMagnification.
        view.minScaleFactor = min(view.minScaleFactor, minimum)
        view.maxScaleFactor = max(view.maxScaleFactor, maximum)
        view.minScaleFactor = minimum
        view.maxScaleFactor = maximum
    }

    @MainActor
    final class Coordinator: NSObject, @unchecked Sendable {
        var parent: PDFKitView
        weak var view: PDFView?
        var isRestoring = false
        var lastPageIndex = -1
        var lastScale: Double = -1
        var lastHighlightToken: UUID?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
        #if !os(macOS)
        private var scrollObservation: NSKeyValueObservation?
        #endif

        init(_ parent: PDFKitView) {
            self.parent = parent
        }

        func observe(_ view: PDFView) {
            self.view = view
            observers.append(NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.syncState() }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: .PDFViewScaleChanged, object: view, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.syncState() }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: .PDFViewSelectionChanged, object: view, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.syncSelection() }
            })
            observeScrolling()
        }

        func syncState() {
            guard !isRestoring, let view,
                  let page = view.currentPage,
                  let document = view.document else { return }
            let pageIndex = document.index(for: page)
            let scale = view.scaleFactor
            let offset = currentScrollOffset()
            lastPageIndex = pageIndex
            lastScale = scale
            parent.pageIndex = pageIndex
            parent.zoomScale = scale
            parent.scrollOffset = offset
        }

        private func syncSelection() {
            parent.selectedText = view?.currentSelection?.string
        }

        func applyHighlight(_ target: PDFHighlightTarget?) {
            guard let target,
                  target.token != lastHighlightToken,
                  let view,
                  let document = view.document else { return }
            let matches = document.findString(
                target.query,
                withOptions: [.caseInsensitive, .diacriticInsensitive]
            )
            .filter { selection in
                selection.pages.contains(where: { document.index(for: $0) == target.pageIndex })
            }
            guard matches.indices.contains(target.occurrenceIndex) else { return }
            let selection = matches[target.occurrenceIndex]
            lastHighlightToken = target.token
            #if os(macOS)
            selection.color = NSColor.systemYellow.withAlphaComponent(0.58)
            #else
            selection.color = UIColor.systemYellow.withAlphaComponent(0.58)
            #endif
            view.highlightedSelections = [selection]
            view.go(to: selection)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard self?.lastHighlightToken == target.token else { return }
                self?.view?.highlightedSelections = nil
            }
        }

        #if os(macOS)
        private func observeScrolling() {
            guard let contentView = view?.documentView?.enclosingScrollView?.contentView else {
                DispatchQueue.main.async { [weak self] in self?.observeScrolling() }
                return
            }
            contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.syncState() }
            })
        }

        private func currentScrollOffset() -> Double {
            Double(view?.documentView?.enclosingScrollView?.contentView.bounds.origin.y ?? 0)
        }

        func restoreScrollOffset(_ offset: Double) {
            guard offset > 0,
                  let contentView = view?.documentView?.enclosingScrollView?.contentView else {
                return
            }
            contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: offset))
            contentView.enclosingScrollView?.reflectScrolledClipView(contentView)
        }
        #else
        private func observeScrolling() {
            guard let scrollView = view?.descendantScrollView else {
                DispatchQueue.main.async { [weak self] in self?.observeScrolling() }
                return
            }
            scrollObservation = scrollView.observe(\.contentOffset, options: [.new]) {
                [weak self] _, _ in
                Task { @MainActor in self?.syncState() }
            }
        }

        private func currentScrollOffset() -> Double {
            Double(view?.descendantScrollView?.contentOffset.y ?? 0)
        }

        func restoreScrollOffset(_ offset: Double) {
            guard offset > 0, let scrollView = view?.descendantScrollView else { return }
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: offset), animated: false
            )
        }
        #endif

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

#if os(macOS)
private final class PaperPDFView: PDFView {
    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }
}
#endif

#if !os(macOS)
private extension UIView {
    var descendantScrollView: UIScrollView? {
        if let scrollView = self as? UIScrollView { return scrollView }
        for child in subviews {
            if let scrollView = child.descendantScrollView { return scrollView }
        }
        return nil
    }
}
#endif
