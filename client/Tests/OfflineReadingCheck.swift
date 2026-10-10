// Compile with Models, APIClient, KeychainStore, OfflineStore, PDFCache,
// MinerUCache and AppModel. See docs/chatkit-prototype.md for the full command.
import AppKit
import Foundation
import PDFKit

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var connected = false
        private var responses: [String: Data] = [:]
        private var requests: [String] = []
        private var patches: [Data] = []
        private var delay: TimeInterval = 0
        func setPatchDelay(_ value: TimeInterval) { lock.lock(); defer { lock.unlock() }; delay = value }
        var patchDelay: TimeInterval { lock.lock(); defer { lock.unlock() }; return delay }
        func configure(connected: Bool, responses: [String: Data] = [:]) {
            lock.lock(); defer { lock.unlock() }
            self.connected = connected; self.responses = responses
        }
        func respond(_ request: URLRequest) -> (Data?, Int) {
            lock.lock(); defer { lock.unlock() }
            let path = request.url!.path
            requests.append(path)
            guard connected else { return (nil, 0) }
            if request.httpMethod == "PATCH" {
                patches.append(request.httpBody ?? Data())
                return (Data("{\"updated_at\":\"2026-10-10\"}".utf8), 200)
            }
            return (responses[path] ?? Data("[]".utf8), 200)
        }
        var patchCount: Int { lock.lock(); defer { lock.unlock() }; return patches.count }
        var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (data, status) = Self.state.respond(request)
        if request.httpMethod == "PATCH" { Thread.sleep(forTimeInterval: Self.state.patchDelay) }
        guard let data else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main @MainActor struct OfflineReadingCheck {
    static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "offline-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = URL(string: "http://offline-check.invalid/")!
        let store = OfflineStore(serverURL: server, directory: directory)
        let other = OfflineStore(serverURL: URL(string: "http://other-server.invalid/")!, directory: directory)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let api = APIClient(baseURL: server, tokens: AuthTokens(
            accessToken: "test", refreshToken: "test", expiresIn: 3600, sessionId: "test"
        ), session: URLSession(configuration: config))
        let reading = ReadingState(paperID: "p1", deviceID: "test", pageIndex: 2,
            scrollOffset: 0.4, zoomScale: 1.5, displayMode: "singlePageContinuous",
            activeThreadID: nil, updatedAt: "2026-10-10")
        let paper = Paper(id: "p1", title: "Cached paper", authors: [], year: "2026",
            identifiers: [PaperIdentifier(kind: "zotero", libraryType: "user", libraryID: "1", value: "ABCDEFGH")],
            readingState: reading, lastOpenedAt: nil, starred: false)
        let library = LibraryPaper(itemKey: "item", attachmentKey: "ABCDEFGH", title: paper.title, creators: [], year: "2026")
        var snapshot = OfflineWorkspace()
        snapshot.recent = [paper]; snapshot.library = [library]; snapshot.papers = [paper.id: paper]
        snapshot.openPaperIDs = [paper.id]; snapshot.activePaperID = paper.id
        try await store.saveWorkspace(snapshot)
        let wrongServer = try await other.loadWorkspace()
        precondition(wrongServer == nil, "Server namespaces leaked")
        let pdfData = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: pdfData)!
        let context = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
        for page in 1...3 {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSString(string: "Cached paper · Offline verification · Page \(page)").draw(
                at: NSPoint(x: 40, y: 730), withAttributes: [.font: NSFont.systemFont(ofSize: 18)]
            )
            NSString(string: "This PDF was saved locally. It can be read without the home server.").draw(
                at: NSPoint(x: 40, y: 680), withAttributes: [.font: NSFont.systemFont(ofSize: 12)]
            )
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        let url = try await PDFCache.shared.store(pdfData as Data, paperID: paper.id, etag: "one",
                                                root: store.root.appending(path: "papers"))
        precondition(PDFDocument(url: url) != nil)
        let model = AppModel(client: api, offlineStore: store, monitorNetwork: false)
        await model.restoreLocalWorkspace()
        precondition(model.recentPapers == [paper] && model.libraryPapers == [library])
        precondition(model.route == .paper(paper.id) && model.activeSession?.pageIndex == 2)
        precondition(model.activeSession?.pdfURL == url && model.activeSession?.zoomScale == 1.5)
        await model.refreshLibrary()
        precondition(model.isOffline && model.errorMessage == nil && model.recentPapers == [paper])
        let beforeOpen = StubProtocol.state.requestCount
        await model.open(libraryPaper: library)
        precondition(StubProtocol.state.requestCount == beforeOpen, "Cached paper opening required network")
        let session = model.activeSession!
        session.pdfSearchQuery = "Cached paper"
        await model.searchPDF("Cached paper", in: session)
        precondition(session.pdfSearchResults.count == 3, "PDF text search depended on the server")
        model.pdfViewStateChanged(in: session, pageIndex: 0, zoomScale: 2, scrollOffset: 0.7)
        await model.flushLocalWorkspace()
        let saved = try await store.loadWorkspace()!
        precondition(saved.pendingReadingStates[paper.id]?.scrollOffset == 0.7)
        let restarted = AppModel(client: api, offlineStore: store, monitorNetwork: false)
        await restarted.restoreLocalWorkspace()
        precondition(restarted.activeSession?.scrollOffset == 0.7 && restarted.activeSession?.zoomScale == 2)
        restarted.isOffline = true
        let uncached = Paper(id: "missing", title: "Not downloaded", authors: [], year: nil,
                             identifiers: nil, readingState: nil, lastOpenedAt: nil, starred: false)
        await restarted.open(paper: uncached)
        precondition(restarted.errorMessage?.contains("has not been saved") == true)
        precondition(restarted.activeSession?.id == paper.id)
        restarted.searchQuery = "cached"
        await restarted.search("cached")
        precondition(restarted.searchPapers.count == 1 && !restarted.hasMoreSearchResults)
        StubProtocol.state.configure(connected: true, responses: [
            "/api/papers/recent": try JSONEncoder.paperChat.encode([paper]),
            "/api/library/papers": try JSONEncoder.paperChat.encode(LibraryPaperResponse(papers: [library])),
            "/api/papers/p1": try JSONEncoder.paperChat.encode(paper),
            "/api/papers/p1/bookmarks": try JSONEncoder.paperChat.encode(BookmarkOverview(bookmarks: [], suggestions: []))
        ])
        await restarted.refreshLibrary()
        await restarted.flushLocalWorkspace()
        let synced = try await store.loadWorkspace()!
        precondition(!restarted.isOffline && StubProtocol.state.patchCount == 1)
        precondition(synced.pendingReadingStates.isEmpty, "Acknowledged reading state was not cleared")
        precondition(restarted.activeSession?.scrollOffset == 0.7, "Refresh moved the local reading viewport")
        StubProtocol.state.setPatchDelay(0.15)
        let oldPatchCount = StubProtocol.state.patchCount
        restarted.pdfViewStateChanged(in: restarted.activeSession!, pageIndex: 1, zoomScale: 2, scrollOffset: 0.8)
        let refresh = Task { await restarted.refreshLibrary() }
        for _ in 0..<100 {
            if StubProtocol.state.patchCount > oldPatchCount { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(StubProtocol.state.patchCount > oldPatchCount, "Delayed position save did not start")
        restarted.pdfViewStateChanged(in: restarted.activeSession!, pageIndex: 1, zoomScale: 2, scrollOffset: 0.9)
        await refresh.value
        await restarted.flushLocalWorkspace()
        let raced = try await store.loadWorkspace()!
        precondition(raced.pendingReadingStates.isEmpty && raced.papers[paper.id]?.readingState?.scrollOffset == 0.9,
                     "An older acknowledgement discarded a newer position")
        precondition(StubProtocol.state.patchCount >= oldPatchCount + 2)
        StubProtocol.state.setPatchDelay(0)
        // Test a cached paper that was not among the restored open tabs.
        let closedStore = OfflineStore(serverURL: server, directory: directory.appending(path: "closed"))
        var closed = snapshot; closed.openPaperIDs = []; closed.activePaperID = nil
        try await closedStore.saveWorkspace(closed)
        _ = try await PDFCache.shared.store(pdfData as Data, paperID: paper.id, etag: nil,
                                            root: closedStore.root.appending(path: "papers"))
        let closedModel = AppModel(client: api, offlineStore: closedStore, monitorNetwork: false)
        await closedModel.restoreLocalWorkspace()
        closedModel.isOffline = true
        let requestsBeforeColdOpen = StubProtocol.state.requestCount
        await closedModel.open(libraryPaper: library)
        precondition(closedModel.activeSession?.pdfURL != nil && StubProtocol.state.requestCount == requestsBeforeColdOpen,
                     "Opening a closed cached paper required metadata or thread requests")
        // Older queued snapshots must never overwrite newer local edits.
        var stale = saved; stale.revision = 0
        try await store.saveWorkspace(stale)
        let latest = try await store.loadWorkspace()!
        precondition(latest.pendingReadingStates.isEmpty)
        let read1 = #"{"type":"threads.get_by_id","params":{"thread_id":"proof-thread"},"metadata":{"paperchat":{"paper_id":"p1","current_page_index":1}}}"#
        let read2 = #"{"params":{"thread_id":"proof-thread"},"type":"threads.get_by_id","metadata":{"paperchat":{"paper_id":"p1","current_page_index":9}}}"#
        precondition(ChatKitOfflineCache.key(body: read1) == ChatKitOfflineCache.key(body: read2))
        precondition(ChatKitOfflineCache.key(body: #"{"type":"threads.create","params":{}}"#) == nil)
        let fixture = try Data(contentsOf: URL(fileURLWithPath: "client/Tests/Fixtures/OfflineChatThread.json"))
        let locked = try JSONSerialization.jsonObject(with: ChatKitOfflineCache.readOnly(fixture)) as! [String: Any]
        precondition((locked["status"] as? [String: Any])?["type"] as? String == "locked")
        if CommandLine.arguments.count == 2 {
            var exported = latest
            exported.papers[paper.id]?.readingState?.pageIndex = 2
            exported.papers[paper.id]?.readingState?.scrollOffset = 0
            exported.papers[paper.id]?.readingState?.zoomScale = 0
            exported.papers[paper.id]?.readingState?.activeThreadID = "proof-thread"
            exported.openPaperIDs = [paper.id]; exported.activePaperID = paper.id
            exported.revision += 1
            try await store.saveWorkspace(exported)
            let thread = ChatThread(id: "proof-thread", paperID: paper.id, title: "Offline proof",
                backendType: "synthetic", backendThreadID: nil, backendStatus: "ready", model: nil,
                effort: nil, isPrimary: 1, lastUsedAt: "2026-10-10")
            try await store.save([thread], key: "threads/" + paper.id)
            try await store.save(thread, key: "thread/proof-thread")
            try await store.save(fixture, key: ChatKitOfflineCache.key(body: read1)!)
            for params: [String: Any] in [["limit": 20, "order": "desc"], ["limit": 10, "order": "desc"], ["order": "desc"], [:]] {
                let body = try JSONSerialization.data(withJSONObject: ["type": "threads.list", "params": params,
                    "metadata": ["paperchat": ["paper_id": paper.id]]])
                let threadJSON = try JSONSerialization.jsonObject(with: fixture)
                let response = try JSONSerialization.data(withJSONObject: ["data": [threadJSON], "has_more": false])
                try await store.save(response, key: ChatKitOfflineCache.key(body: String(decoding: body, as: UTF8.self))!)
            }
            let export = URL(fileURLWithPath: CommandLine.arguments[1])
            try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
            let destination = export.appending(path: store.root.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: store.root, to: destination)
        }
        print("PASS: offline cold restore, cached PDF without network, missing PDF, local search, durable reading position, reconnect synchronization, server isolation, stale write protection")
    }
}
