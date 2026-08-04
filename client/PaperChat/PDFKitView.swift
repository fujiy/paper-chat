import PDFKit
import SwiftUI

#if os(macOS)
struct PDFKitView: NSViewRepresentable {
    let url: URL
    @Binding var pageIndex: Int
    @Binding var zoomScale: Double
    @Binding var scrollOffset: Double
    @Binding var selectedText: String?
    @Binding var selectionSnapshot: PDFSelectionSnapshot?
    let highlightTarget: PDFHighlightTarget?
    let viewportTarget: PDFViewportTarget?
    let isImmersive: Bool
    let horizontalScrollAllowance: CGFloat
    let onTap: () -> Void

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
    @Binding var selectionSnapshot: PDFSelectionSnapshot?
    let highlightTarget: PDFHighlightTarget?
    let viewportTarget: PDFViewportTarget?
    let isImmersive: Bool
    let horizontalScrollAllowance: CGFloat
    let onTap: () -> Void

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
        coordinator.lastImmersive = isImmersive
        loadDocument(in: view, coordinator: coordinator)
    }

    func update(_ view: PDFView, coordinator: Coordinator) {
        let immersiveChanged = coordinator.lastImmersive != isImmersive
        coordinator.lastImmersive = isImmersive
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
        coordinator.applyViewportTarget(viewportTarget)
        coordinator.updateHorizontalScrollAllowance(horizontalScrollAllowance)
        if immersiveChanged {
            coordinator.restoreViewportAfterLayout(scrollOffset)
        }
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
        var lastViewportToken: UUID?
        var lastImmersive: Bool?
        var lastHorizontalScrollAllowance: CGFloat = -1
        var viewportOffsetBeforeToggle: CGPoint?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
        #if !os(macOS)
        private var scrollObservation: NSKeyValueObservation?
        #endif

        init(_ parent: PDFKitView) {
            self.parent = parent
        }

        func observe(_ view: PDFView) {
            self.view = view
            #if os(macOS)
            let tap = NSClickGestureRecognizer(target: self, action: #selector(handleTap))
            tap.numberOfClicksRequired = 1
            #else
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tap.numberOfTapsRequired = 1
            tap.cancelsTouchesInView = false
            #endif
            tap.delegate = self
            view.addGestureRecognizer(tap)
            observers.append(NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleStateSync() }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: .PDFViewScaleChanged, object: view, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleStateSync() }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: .PDFViewSelectionChanged, object: view, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleSelectionSync() }
            })
            observeScrolling()
        }

        func updateHorizontalScrollAllowance(_ allowance: CGFloat) {
            #if os(macOS)
            guard let scrollView = view?.documentView?.enclosingScrollView else { return }
            guard abs(lastHorizontalScrollAllowance - allowance) > 0.5 else { return }
            lastHorizontalScrollAllowance = allowance
            scrollView.hasHorizontalScroller = true
            scrollView.horizontalScrollElasticity = .automatic
            var insets = scrollView.contentInsets
            insets.right = allowance
            scrollView.contentInsets = insets
            #else
            guard let scrollView = view?.descendantScrollView else { return }
            guard abs(lastHorizontalScrollAllowance - allowance) > 0.5 else { return }
            lastHorizontalScrollAllowance = allowance
            scrollView.alwaysBounceHorizontal = true
            var contentInset = scrollView.contentInset
            contentInset.right = allowance
            scrollView.contentInset = contentInset
            var indicatorInset = scrollView.horizontalScrollIndicatorInsets
            indicatorInset.right = allowance
            scrollView.horizontalScrollIndicatorInsets = indicatorInset
            #endif
        }

        @objc private func handleTap() {
            viewportOffsetBeforeToggle = currentViewportOffset()
            parent.onTap()
        }

        func restoreViewportAfterLayout(_ fallbackVerticalOffset: Double) {
            guard let view else { return }
            let offset = viewportOffsetBeforeToggle
                ?? CGPoint(x: currentViewportOffset().x, y: fallbackVerticalOffset)
            viewportOffsetBeforeToggle = nil
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.isRestoring = true
                #if os(macOS)
                view.layoutSubtreeIfNeeded()
                #else
                view.layoutIfNeeded()
                #endif
                self.restoreViewportOffset(offset)
                self.isRestoring = false
            }
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
            if parent.pageIndex != pageIndex { parent.pageIndex = pageIndex }
            if abs(parent.zoomScale - scale) > 0.005 { parent.zoomScale = scale }
            if abs(parent.scrollOffset - offset) > 0.5 { parent.scrollOffset = offset }
        }

        private func scheduleStateSync() {
            guard !isRestoring else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isRestoring else { return }
                self.syncState()
            }
        }

        private func scheduleSelectionSync() {
            guard !isRestoring else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isRestoring else { return }
                self.syncSelection()
            }
        }

        private func syncSelection() {
            guard let view,
                  let document = view.document,
                  let selection = view.currentSelection,
                  let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                if parent.selectedText != nil { parent.selectedText = nil }
                if parent.selectionSnapshot != nil { parent.selectionSnapshot = nil }
                return
            }
            let rects = selection.pages.compactMap { page -> BookmarkSelectionRect? in
                let pageIndex = document.index(for: page)
                let pageBounds = page.bounds(for: .cropBox)
                let bounds = selection.bounds(for: page).intersection(pageBounds)
                guard pageIndex >= 0, pageBounds.width > 0, pageBounds.height > 0,
                      !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
                return BookmarkSelectionRect(
                    pageIndex: pageIndex,
                    x: Double((bounds.minX - pageBounds.minX) / pageBounds.width),
                    y: Double((bounds.minY - pageBounds.minY) / pageBounds.height),
                    width: Double(bounds.width / pageBounds.width),
                    height: Double(bounds.height / pageBounds.height)
                )
            }
            let snapshot: PDFSelectionSnapshot? = rects.isEmpty
                ? nil
                : PDFSelectionSnapshot(text: text, rects: rects)
            if parent.selectedText != text { parent.selectedText = text }
            if parent.selectionSnapshot != snapshot { parent.selectionSnapshot = snapshot }
        }

        func applyViewportTarget(_ target: PDFViewportTarget?) {
            guard let target, target.token != lastViewportToken else { return }
            lastViewportToken = target.token
            DispatchQueue.main.async { [weak self] in
                guard let self, let view = self.view else { return }
                self.isRestoring = true
                if self.lastPageIndex != target.pageIndex,
                   let page = view.document?.page(at: target.pageIndex) {
                    view.go(to: page)
                    self.lastPageIndex = target.pageIndex
                }
                self.restoreScrollOffset(target.scrollOffset)
                self.isRestoring = false
            }
        }

        func applyHighlight(_ target: PDFHighlightTarget?) {
            guard let target,
                  target.token != lastHighlightToken,
                  let view,
                  let document = view.document else { return }
            let selections: [PDFSelection]
            if !target.rects.isEmpty {
                selections = target.rects.compactMap { anchor in
                    guard let page = document.page(at: anchor.pageIndex) else { return nil }
                    let pageBounds = page.bounds(for: .cropBox)
                    let rect = CGRect(
                        x: pageBounds.minX + CGFloat(anchor.x) * pageBounds.width,
                        y: pageBounds.minY + CGFloat(anchor.y) * pageBounds.height,
                        width: CGFloat(anchor.width) * pageBounds.width,
                        height: CGFloat(anchor.height) * pageBounds.height
                    )
                    return page.selection(for: rect)
                }
            } else if let query = target.query {
                let matches = document.findString(
                    query,
                    withOptions: [.caseInsensitive, .diacriticInsensitive]
                )
                .filter { selection in
                    selection.pages.contains(where: {
                        document.index(for: $0) == target.pageIndex
                    })
                }
                let occurrence = target.occurrenceIndex ?? 0
                selections = matches.indices.contains(occurrence) ? [matches[occurrence]] : []
            } else {
                selections = []
            }
            guard let selection = selections.first else { return }
            lastHighlightToken = target.token
            #if os(macOS)
            selections.forEach { $0.color = NSColor.systemYellow.withAlphaComponent(0.58) }
            #else
            selections.forEach { $0.color = UIColor.systemYellow.withAlphaComponent(0.58) }
            #endif
            view.highlightedSelections = selections
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
            updateHorizontalScrollAllowance(parent.horizontalScrollAllowance)
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleStateSync() }
            })
        }

        private func currentScrollOffset() -> Double {
            Double(view?.documentView?.enclosingScrollView?.contentView.bounds.origin.y ?? 0)
        }

        private func currentViewportOffset() -> CGPoint {
            let origin = view?.documentView?.enclosingScrollView?.contentView.bounds.origin ?? .zero
            return CGPoint(x: origin.x, y: origin.y)
        }

        func restoreScrollOffset(_ offset: Double) {
            guard offset > 0,
                  let contentView = view?.documentView?.enclosingScrollView?.contentView else {
                return
            }
            contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: offset))
            contentView.enclosingScrollView?.reflectScrolledClipView(contentView)
        }

        private func restoreViewportOffset(_ offset: CGPoint) {
            guard let contentView = view?.documentView?.enclosingScrollView?.contentView else {
                return
            }
            contentView.scroll(to: NSPoint(x: offset.x, y: offset.y))
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
                Task { @MainActor in self?.scheduleStateSync() }
            }
            updateHorizontalScrollAllowance(parent.horizontalScrollAllowance)
        }

        private func currentScrollOffset() -> Double {
            Double(view?.descendantScrollView?.contentOffset.y ?? 0)
        }

        private func currentViewportOffset() -> CGPoint {
            view?.descendantScrollView?.contentOffset ?? .zero
        }

        func restoreScrollOffset(_ offset: Double) {
            guard offset > 0, let scrollView = view?.descendantScrollView else { return }
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: offset), animated: false
            )
        }

        private func restoreViewportOffset(_ offset: CGPoint) {
            view?.descendantScrollView?.setContentOffset(offset, animated: false)
        }
        #endif

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

#if os(macOS)
extension PDFKitView.Coordinator: NSGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
    ) -> Bool {
        true
    }
}
#else
extension PDFKitView.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
#endif

struct PDFThumbnailStrip: View {
    let url: URL
    @Binding var pageIndex: Int
    @State private var document: PDFDocument?

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        if let document {
                            ForEach(0..<document.pageCount, id: \.self) { index in
                                Button {
                                    pageIndex = index
                                } label: {
                                    PDFPageThumbnail(
                                        document: document,
                                        pageIndex: index,
                                        isSelected: pageIndex == index
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(index)
                            }
                        }
                    }
                    .frame(minWidth: max(geometry.size.width - 20, 0), alignment: .center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
                .scrollIndicators(.hidden)
                .background(.bar)
                .onAppear {
                    proxy.scrollTo(pageIndex, anchor: .center)
                }
                .onChange(of: pageIndex) { _, page in
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(page, anchor: .center)
                    }
                }
            }
        }
        .frame(height: 92)
        .task(id: url) {
            document = PDFDocument(url: url)
        }
    }
}

private struct PDFPageThumbnail: View {
    let document: PDFDocument
    let pageIndex: Int
    let isSelected: Bool
    @State private var thumbnail: PlatformPDFImage?

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if let thumbnail {
                    #if os(macOS)
                    Image(nsImage: thumbnail)
                        .resizable()
                    #else
                    Image(uiImage: thumbnail)
                        .resizable()
                    #endif
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .scaledToFit()
            .frame(width: 52, height: 64)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: isSelected ? 2 : 0.5
                    )
            }

            Text("\(pageIndex + 1)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        }
        .frame(width: 58)
        .task(id: pageIndex) {
            thumbnail = document.page(at: pageIndex)?.thumbnail(
                of: CGSize(width: 104, height: 128),
                for: .cropBox
            )
        }
        .accessibilityLabel("Page \(pageIndex + 1)")
    }
}

#if os(macOS)
private typealias PlatformPDFImage = NSImage
#else
private typealias PlatformPDFImage = UIImage
#endif

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
