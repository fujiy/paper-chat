import PDFKit
import SwiftUI

#if os(macOS)
struct PDFKitView: NSViewRepresentable {
    let url: URL
    @Binding var pageIndex: Int
    @Binding var selectedText: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PDFView {
        configuredPDFView(context: context)
    }

    func updateNSView(_ view: PDFView, context: Context) {
        update(view)
    }

    private func configuredPDFView(context: Context) -> PDFView {
        let view = PDFView()
        configure(view, coordinator: context.coordinator)
        return view
    }

    private func update(_ view: PDFView) {
        updateDocument(view)
    }
}
#else
struct PDFKitView: UIViewRepresentable {
    let url: URL
    @Binding var pageIndex: Int
    @Binding var selectedText: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        configure(view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        updateDocument(view)
    }
}
#endif

extension PDFKitView {
    func configure(_ view: PDFView, coordinator: Coordinator) {
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.document = PDFDocument(url: url)
        coordinator.observe(view)
        if let page = view.document?.page(at: pageIndex) { view.go(to: page) }
    }

    func updateDocument(_ view: PDFView) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
        if let current = view.currentPage,
           view.document?.index(for: current) != pageIndex,
           let target = view.document?.page(at: pageIndex) {
            view.go(to: target)
        }
    }

    @MainActor
    final class Coordinator: NSObject, @unchecked Sendable {
        var parent: PDFKitView
        private weak var view: PDFView?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        init(_ parent: PDFKitView) { self.parent = parent }

        func observe(_ view: PDFView) {
            self.view = view
            observers.append(NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.syncPage() }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: .PDFViewSelectionChanged, object: view, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.syncSelection() }
            })
        }

        private func syncPage() {
            guard let view, let page = view.currentPage, let document = view.document else { return }
            parent.pageIndex = document.index(for: page)
        }

        private func syncSelection() {
            parent.selectedText = view?.currentSelection?.string
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
