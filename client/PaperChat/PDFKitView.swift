import PDFKit
import SwiftUI

struct PDFViewportRange: Equatable {
    var lowerBound: CGFloat
    var upperBound: CGFloat

    static let full = PDFViewportRange(lowerBound: 0, upperBound: 1)
}

#if os(macOS)
struct PDFKitView: NSViewRepresentable {
    let url: URL
    @Binding var pageIndex: Int
    @Binding var zoomScale: Double
    @Binding var scrollOffset: Double
    @Binding var viewportRange: PDFViewportRange
    @Binding var selectedText: String?
    @Binding var selectionSnapshot: PDFSelectionSnapshot?
    let highlightTarget: PDFHighlightTarget?
    let viewportTarget: PDFViewportTarget?
    let documentStructure: DocumentStructure?
    let isImmersive: Bool
    let isInspectorPresented: Bool
    let bottomOverlayInset: CGFloat
    let thumbnailInteractionToken: UUID
    let onCompactPresentationChange: (Bool) -> Void

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
    @Binding var viewportRange: PDFViewportRange
    @Binding var selectedText: String?
    @Binding var selectionSnapshot: PDFSelectionSnapshot?
    let highlightTarget: PDFHighlightTarget?
    let viewportTarget: PDFViewportTarget?
    let documentStructure: DocumentStructure?
    let isImmersive: Bool
    let isInspectorPresented: Bool
    let bottomOverlayInset: CGFloat
    let thumbnailInteractionToken: UUID
    let onCompactPresentationChange: (Bool) -> Void

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
        coordinator.lastInspectorPresented = isInspectorPresented
        coordinator.lastThumbnailInteractionToken = thumbnailInteractionToken
        #if os(macOS)
        (view as? PaperPDFView)?.onLayout = { [weak coordinator] in
            coordinator?.updateScaleAfterLayout()
        }
        #endif
        loadDocument(in: view, coordinator: coordinator)
    }

    func update(_ view: PDFView, coordinator: Coordinator) {
        let immersiveChanged = coordinator.lastImmersive != isImmersive
        let inspectorChanged = coordinator.lastInspectorPresented != isInspectorPresented
        coordinator.lastImmersive = isImmersive
        coordinator.lastInspectorPresented = isInspectorPresented
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
        coordinator.applyStructureLinks(documentStructure)
        coordinator.updateContentInsets(bottomOverlayInset: bottomOverlayInset)
        coordinator.handleThumbnailInteraction(thumbnailInteractionToken)
        if immersiveChanged || inspectorChanged {
            coordinator.restoreViewportAfterLayout(scrollOffset)
        }
    }

    private func loadDocument(in view: PDFView, coordinator: Coordinator) {
        coordinator.isRestoring = true
        #if os(macOS)
        coordinator.pendingInitialViewport = (pageIndex, zoomScale, scrollOffset)
        coordinator.lastScaleViewportSize = nil
        view.document = PDFDocument(url: url)
        view.needsLayout = true
        #else
        view.document = PDFDocument(url: url)
        view.layoutIfNeeded()
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
            coordinator.applyStructureLinks(documentStructure)
        }
        #endif
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
        var lastInspectorPresented: Bool?
        var lastBottomOverlayInset: CGFloat = -1
        var lastThumbnailInteractionToken: UUID?
        var appliedStructure: DocumentStructure?
        var structureLinkAnnotations: [(PDFPage, PDFAnnotation)] = []
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
        #if os(macOS)
        var pendingInitialViewport: (pageIndex: Int, zoomScale: Double, scrollOffset: Double)?
        var lastScaleViewportSize: CGSize?
        private var isUpdatingScaleAfterLayout = false

        func updateScaleAfterLayout() {
            guard !isUpdatingScaleAfterLayout, let view, view.window != nil,
                  let document = view.document, document.pageCount > 0,
                  let clipView = view.documentView?.enclosingScrollView?.contentView else { return }
            let size = clipView.bounds.size
            guard size.width > 0, size.height > 0,
                  pendingInitialViewport != nil || lastScaleViewportSize != size else { return }
            let fitScale = view.scaleFactorForSizeToFit
            guard fitScale.isFinite, fitScale > 0 else { return }

            isUpdatingScaleAfterLayout = true
            isRestoring = true
            lastScaleViewportSize = size
            parent.setScaleRange(in: view, fitScale: fitScale)
            if let initial = pendingInitialViewport {
                view.scaleFactor = initial.zoomScale > 0 ? initial.zoomScale : fitScale
                if let page = document.page(at: initial.pageIndex) {
                    view.go(to: page)
                }
                lastPageIndex = initial.pageIndex
                restoreScrollOffset(initial.scrollOffset)
                pendingInitialViewport = nil
            }
            lastScale = view.scaleFactor
            isRestoring = false
            isUpdatingScaleAfterLayout = false

            // Publish bindings outside AppKit/SwiftUI's layout pass. A newly
            // loaded document must never persist its provisional scale.
            DispatchQueue.main.async { [weak self, weak document] in
                guard let self, let document, self.view?.document === document,
                      self.pendingInitialViewport == nil else { return }
                self.syncState()
                self.applyHighlight(self.parent.highlightTarget)
                self.applyViewportTarget(self.parent.viewportTarget)
                self.applyStructureLinks(self.parent.documentStructure)
                self.updateContentInsets(bottomOverlayInset: self.parent.bottomOverlayInset)
            }
        }
        #endif
        #if !os(macOS)
        private var scrollObservation: NSKeyValueObservation?
        private var lastObservedVerticalOffset: CGFloat?
        private var accumulatedVerticalDelta: CGFloat = 0
        private var lastVerticalDirection: CGFloat = 0
        private var suppressCompactPresentationUntil = Date.distantPast
        #endif

        init(_ parent: PDFKitView) {
            self.parent = parent
        }

        func observe(_ view: PDFView) {
            self.view = view
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

        func updateContentInsets(bottomOverlayInset: CGFloat) {
            #if os(macOS)
            guard let scrollView = view?.documentView?.enclosingScrollView else { return }
            guard abs(lastBottomOverlayInset - bottomOverlayInset) > 0.5 else { return }
            lastBottomOverlayInset = bottomOverlayInset
            var insets = scrollView.contentInsets
            insets.right = 0
            insets.bottom = bottomOverlayInset
            scrollView.contentInsets = insets
            #else
            guard let scrollView = view?.descendantScrollView else { return }
            guard abs(lastBottomOverlayInset - bottomOverlayInset) > 0.5 else { return }
            lastBottomOverlayInset = bottomOverlayInset
            var contentInset = scrollView.contentInset
            contentInset.right = 0
            contentInset.bottom = bottomOverlayInset
            scrollView.contentInset = contentInset
            var horizontalIndicatorInset = scrollView.horizontalScrollIndicatorInsets
            horizontalIndicatorInset.right = 0
            scrollView.horizontalScrollIndicatorInsets = horizontalIndicatorInset
            var verticalIndicatorInset = scrollView.verticalScrollIndicatorInsets
            verticalIndicatorInset.bottom = bottomOverlayInset
            scrollView.verticalScrollIndicatorInsets = verticalIndicatorInset
            #endif
        }

        func handleThumbnailInteraction(_ token: UUID) {
            guard lastThumbnailInteractionToken != token else { return }
            lastThumbnailInteractionToken = token
            #if !os(macOS)
            suppressCompactPresentationUntil = Date.now.addingTimeInterval(1)
            resetAccumulatedScrollIntent()
            guard let scrollView = view?.descendantScrollView else { return }
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
            #endif
        }

        func restoreViewportAfterLayout(_ fallbackVerticalOffset: Double) {
            guard let view else { return }
            let offset = CGPoint(x: currentViewportOffset().x, y: fallbackVerticalOffset)
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
                  let document = view.document else { return }
            let viewportCenter = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            guard let page = view.page(for: viewportCenter, nearest: true) ?? view.currentPage else {
                return
            }
            let pageIndex = document.index(for: page)
            let scale = view.scaleFactor
            let offset = currentScrollOffset()
            lastPageIndex = pageIndex
            lastScale = scale
            if parent.pageIndex != pageIndex { parent.pageIndex = pageIndex }
            if abs(parent.zoomScale - scale) > 0.005 { parent.zoomScale = scale }
            if abs(parent.scrollOffset - offset) > 0.5 { parent.scrollOffset = offset }
            syncViewportRange()
        }

        private func syncViewportRange() {
            #if !os(macOS)
            guard let scrollView = view?.descendantScrollView else { return }
            let contentHeight = scrollView.contentSize.height
            guard contentHeight > 0 else { return }
            let visibleStart = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            let visibleEnd = visibleStart + scrollView.bounds.height
            let range = PDFViewportRange(
                lowerBound: min(max(visibleStart / contentHeight, 0), 1),
                upperBound: min(max(visibleEnd / contentHeight, 0), 1)
            )
            if abs(parent.viewportRange.lowerBound - range.lowerBound) > 0.0001
                || abs(parent.viewportRange.upperBound - range.upperBound) > 0.0001 {
                parent.viewportRange = range
            }
            #endif
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

        func applyStructureLinks(_ structure: DocumentStructure?) {
            guard appliedStructure != structure, let document = view?.document else { return }
            structureLinkAnnotations.forEach { page, annotation in
                page.removeAnnotation(annotation)
            }
            structureLinkAnnotations.removeAll()
            appliedStructure = structure
            guard let structure, structure.isReady else { return }

            var targets: [String: DocumentAnchor] = [:]
            structure.references.forEach { targets[$0.id] = $0.anchor }

            for link in structure.links {
                guard let target = targets[link.targetID],
                      let targetPage = document.page(at: target.pageIndex) else { continue }
                let destinationBounds = targetPage.bounds(for: .cropBox)
                let destinationRect = target.rects.first.map {
                    CGRect(
                        x: destinationBounds.minX + CGFloat($0.x) * destinationBounds.width,
                        y: destinationBounds.minY + CGFloat($0.y) * destinationBounds.height,
                        width: CGFloat($0.width) * destinationBounds.width,
                        height: CGFloat($0.height) * destinationBounds.height
                    )
                }
                let destination = PDFDestination(
                    page: targetPage,
                    at: CGPoint(
                        x: destinationRect?.minX ?? destinationBounds.minX,
                        y: destinationRect?.maxY ?? destinationBounds.maxY
                    )
                )
                for source in link.anchor.rects {
                    guard let sourcePage = document.page(at: source.pageIndex) else { continue }
                    let pageBounds = sourcePage.bounds(for: .cropBox)
                    let sourceBounds = CGRect(
                        x: pageBounds.minX + CGFloat(source.x) * pageBounds.width,
                        y: pageBounds.minY + CGFloat(source.y) * pageBounds.height,
                        width: CGFloat(source.width) * pageBounds.width,
                        height: CGFloat(source.height) * pageBounds.height
                    )
                    guard sourceBounds.width > 0, sourceBounds.height > 0 else { continue }
                    let horizontalPadding = max(0, (12 - sourceBounds.width) / 2)
                    let verticalPadding = max(0, (12 - sourceBounds.height) / 2)
                    let bounds = sourceBounds
                        .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
                        .intersection(pageBounds)
                    let annotation = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
                    let border = PDFBorder()
                    border.lineWidth = 0
                    annotation.border = border
                    annotation.action = PDFActionGoTo(destination: destination)
                    sourcePage.addAnnotation(annotation)
                    structureLinkAnnotations.append((sourcePage, annotation))
                }
            }
        }

        #if os(macOS)
        private func observeScrolling() {
            guard let contentView = view?.documentView?.enclosingScrollView?.contentView else {
                DispatchQueue.main.async { [weak self] in self?.observeScrolling() }
                return
            }
            contentView.postsBoundsChangedNotifications = true
            updateContentInsets(bottomOverlayInset: parent.bottomOverlayInset)
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
                [weak self, weak scrollView] _, _ in
                Task { @MainActor in
                    guard let scrollView else { return }
                    self?.handleObservedScroll(in: scrollView)
                    self?.syncState()
                }
            }
            lastObservedVerticalOffset = scrollView.contentOffset.y
            updateContentInsets(bottomOverlayInset: parent.bottomOverlayInset)
        }

        private func handleObservedScroll(in scrollView: UIScrollView) {
            let verticalOffset = scrollView.contentOffset.y
            guard let previousOffset = lastObservedVerticalOffset else {
                lastObservedVerticalOffset = verticalOffset
                return
            }
            lastObservedVerticalOffset = verticalOffset

            guard !isRestoring, scrollView.isDragging || scrollView.isDecelerating else {
                resetAccumulatedScrollIntent()
                return
            }
            guard Date.now >= suppressCompactPresentationUntil else {
                resetAccumulatedScrollIntent()
                return
            }

            let topOffset = -scrollView.adjustedContentInset.top
            if verticalOffset <= topOffset + 2 {
                requestCompactPresentation(false)
                resetAccumulatedScrollIntent()
                return
            }

            let delta = verticalOffset - previousOffset
            guard abs(delta) > 0.25 else { return }
            let direction: CGFloat = delta > 0 ? 1 : -1
            if direction != lastVerticalDirection {
                accumulatedVerticalDelta = 0
                lastVerticalDirection = direction
            }
            accumulatedVerticalDelta += delta

            if accumulatedVerticalDelta >= 28 {
                requestCompactPresentation(true)
                resetAccumulatedScrollIntent()
            } else if accumulatedVerticalDelta <= -92 {
                requestCompactPresentation(false)
                resetAccumulatedScrollIntent()
            }
        }

        private func requestCompactPresentation(_ isCompact: Bool) {
            parent.onCompactPresentationChange(isCompact)
        }

        private func resetAccumulatedScrollIntent() {
            accumulatedVerticalDelta = 0
            lastVerticalDirection = 0
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

struct PDFThumbnailStrip: View {
    let url: URL
    @Binding var pageIndex: Int
    let isCompact: Bool
    let viewportRange: PDFViewportRange
    let onInteractionBegan: () -> Void
    let onSelectPage: (Int) -> Void
    let onTapPage: () -> Void
    @State private var document: PDFDocument?

    var body: some View {
        Group {
            if isCompact {
                PDFPagePositionTrack(
                    pageIndex: pageIndex,
                    pageCount: document?.pageCount ?? 0,
                    viewportRange: viewportRange,
                    onInteractionBegan: onInteractionBegan,
                    onSelectPage: onSelectPage,
                    onTapPage: onTapPage
                )
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Show page thumbnails")
                .accessibilityValue(pagePositionAccessibilityValue)
            } else {
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
                            .frame(
                                minWidth: max(geometry.size.width - 20, 0),
                                alignment: .center
                            )
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                        }
                        .scrollIndicators(.hidden)
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
            }
        }
        .frame(height: isCompact ? 26 : 92)
        .background(.bar)
        .animation(.smooth(duration: 0.24), value: isCompact)
        .task(id: url) {
            document = PDFDocument(url: url)
        }
    }

    private var pagePositionAccessibilityValue: String {
        guard let pageCount = document?.pageCount, pageCount > 0 else { return "" }
        return "Page \(min(pageIndex + 1, pageCount)) of \(pageCount)"
    }
}

private struct PDFPagePositionTrack: View {
    let pageIndex: Int
    let pageCount: Int
    let viewportRange: PDFViewportRange
    let onInteractionBegan: () -> Void
    let onSelectPage: (Int) -> Void
    let onTapPage: () -> Void
    @State private var isInteracting = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 0)
            let lowerBound = min(max(viewportRange.lowerBound, 0), 1)
            let upperBound = min(max(viewportRange.upperBound, lowerBound), 1)
            let exactIndicatorWidth = width * (upperBound - lowerBound)
            let indicatorWidth = min(width, max(6, exactIndicatorWidth))
            let indicatorOffset = min(
                max(width * lowerBound, 0),
                max(width - indicatorWidth, 0)
            )

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(height: 2)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: indicatorWidth, height: 4)
                    .offset(x: indicatorOffset)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isInteracting {
                            isInteracting = true
                            onInteractionBegan()
                        }
                        selectPage(at: value.location.x, trackWidth: width)
                    }
                    .onEnded { value in
                        selectPage(at: value.location.x, trackWidth: width)
                        let isTap = hypot(value.translation.width, value.translation.height) < 8
                        isInteracting = false
                        if isTap {
                            onTapPage()
                        }
                    }
            )
        }
    }

    private func selectPage(at x: CGFloat, trackWidth: CGFloat) {
        guard pageCount > 0, trackWidth > 0 else { return }
        let progress = min(max(x / trackWidth, 0), 1)
        let page = pageCount == 1
            ? 0
            : Int((progress * CGFloat(pageCount - 1)).rounded())
        guard page != pageIndex else { return }
        onSelectPage(page)
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
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

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
