import Foundation
import PDFKit
import Network
import SwiftUI
#if !os(macOS)
import UIKit
#endif

@MainActor
final class AppModel: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isOffline = false
    @Published var isBusy = false
    @Published var isSearching = false
    @Published var isLoadingMoreSearchResults = false
    @Published var hasMoreSearchResults = false
    @Published var isSimulatorBookmarkReproMode = false
    @Published var searchResultTotal: Int?
    @Published var searchPaperCount: Int?
    @Published var errorMessage: String?
    @Published var recentPapers: [Paper] = []
    @Published var starredPapers: [Paper] = []
    @Published var libraryPapers: [LibraryPaper] = []
    @Published var chatOverviews: [ChatOverview] = []
    @Published var searchPapers: [LibrarySearchPaper] = []
    @Published var searchQuery = ""
    @Published var searchFocusToken = UUID()
    @Published var route: WorkspaceRoute = .start
    @Published var navigationHistory: [WorkspaceRoute] = []
    @Published var openSessions: [PaperSession] = []
    @Published var managementSessions: [ChatSession] = []
    @Published var models: [ModelOption] = []
    @Published var selectedModelID: String?
    @Published var selectedEffortID: String?

    @Published var serverURLString = UserDefaults.standard.string(forKey: "serverURL")
        ?? "http://localhost:8001/"

    private var client: APIClient
    private var offlineStore: OfflineStore?
    private var workspace = OfflineWorkspace()
    private var workspaceGeneration = UUID()
    private var paperCacheRoot: URL? { offlineStore?.root.appending(path: "papers", directoryHint: .isDirectory) }
    private var persistenceTask: Task<Void, Never>?
    private var sessionRestoreTask: Task<Void, Never>?
    private var paperRefreshTasks: [String: Task<Void, Never>] = [:]
    private var isRefreshingLibrary = false
    private var isSyncingReadingStates = false
    private let networkMonitor = NWPathMonitor()

    init(client: APIClient? = nil, offlineStore: OfflineStore? = nil, monitorNetwork: Bool = true) {
        self.client = client ?? APIClient(baseURL: URL(string: "http://localhost:8001/")!)
        self.offlineStore = offlineStore
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !connected { self.isOffline = true }
                else if self.isOffline, self.isAuthenticated {
                    await self.refreshLibrary()
                }
            }
        }
        if monitorNetwork { networkMonitor.start(queue: DispatchQueue(label: "PaperChat.connectivity")) }
    }

    deinit { networkMonitor.cancel() }
    private var saveTasks: [String: Task<Void, Never>] = [:]
    private var pageViewTasks: [String: Task<Void, Never>] = [:]
    private var pageViewTrackers: [String: PageViewTracker] = [:]
    private var searchGeneration = UUID()
    private let searchPageSize = 40
    private var searchNextOffset = 0

    private struct PageViewTracker {
        var pageIndex: Int
        var checkpoint: Date
        var lastActivity: Date
        var newVisitPending: Bool
    }

    var activeSession: PaperSession? {
        guard case let .paper(id) = route else { return nil }
        return openSessions.first(where: { $0.id == id })
    }

    var selectedModel: ModelOption? {
        models.first(where: { $0.id == selectedModelID })
    }

    var selectedEffort: ReasoningEffortOption? {
        selectedModel?.supportedReasoningEfforts.first(where: {
            $0.reasoningEffort == selectedEffortID
        })
    }

    func restoreSession() async {
        if let sessionRestoreTask { await sessionRestoreTask.value; return }
        let task = Task { await restoreSessionOnce() }
        sessionRestoreTask = task
        await task.value
        sessionRestoreTask = nil
    }

    private func restoreSessionOnce() async {
        let generation = workspaceGeneration
        guard let baseURL = normalizedServerURL() else { return }
        if offlineStore == nil { offlineStore = OfflineStore(serverURL: baseURL) }
        let tokenData = try? KeychainStore.load(account: "tokens")
        let tokens = tokenData.flatMap { try? JSONDecoder.paperChat.decode(AuthTokens.self, from: $0) }
        await client.configure(baseURL: baseURL, tokens: tokens)
        await restoreLocalWorkspace()
        guard !Task.isCancelled, generation == workspaceGeneration else { return }
        guard tokens != nil else {
            // Explicit sign-out removes the workspace. An expired online session
            // must not make already downloaded papers unreadable.
            isAuthenticated = !workspace.papers.isEmpty
            isOffline = isAuthenticated
            return
        }
        isAuthenticated = true
        Task { await refreshLibrary(); await loadModels() }
    }

    func signIn(bootstrapToken: String) async {
        await perform {
            guard let url = normalizedServerURL() else { throw APIError.invalidURL }
            await client.configure(baseURL: url, tokens: nil)
            let tokens = try await client.register(
                bootstrapToken: bootstrapToken,
                deviceID: persistentDeviceID(),
                deviceName: deviceName()
            )
            try KeychainStore.save(JSONEncoder.paperChat.encode(tokens), account: "tokens")
            UserDefaults.standard.set(serverURLString, forKey: "serverURL")
            workspaceGeneration = UUID()
            offlineStore = OfflineStore(serverURL: url)
            workspace = OfflineWorkspace()
            await restoreLocalWorkspace()
            isAuthenticated = true
            isOffline = false
        }
        if isAuthenticated {
            await refreshLibrary()
            await loadModels()
        }
    }

    func signOut() async {
        let store = offlineStore
        let revoke = !isOffline
        workspaceGeneration = UUID()
        sessionRestoreTask?.cancel()
        offlineStore = nil
        isAuthenticated = false
        isRefreshingLibrary = false
        isSyncingReadingStates = false
        paperRefreshTasks.values.forEach { $0.cancel() }
        paperRefreshTasks = [:]
        saveTasks.values.forEach { $0.cancel() }
        saveTasks = [:]
        pageViewTasks.values.forEach { $0.cancel() }
        pageViewTasks = [:]
        pageViewTrackers = [:]
        workspace = OfflineWorkspace()
        recentPapers = []
        starredPapers = []
        libraryPapers = []
        chatOverviews = []
        searchPapers = []
        hasMoreSearchResults = false
        isLoadingMoreSearchResults = false
        searchResultTotal = nil
        searchPaperCount = nil
        searchNextOffset = 0
        openSessions = []
        managementSessions = []
        navigationHistory = []
        route = .start
        await persistenceTask?.value
        try? await store?.clear()
        if revoke { try? await client.revokeCurrentSession() }
        KeychainStore.delete(account: "tokens")
    }

    func restoreLocalWorkspace() async {
        let generation = workspaceGeneration
        guard let offlineStore else { return }
        do {
            guard let saved = try await offlineStore.loadWorkspace(), generation == workspaceGeneration else { return }
            workspace = saved
            recentPapers = saved.recent
            starredPapers = saved.starred
            libraryPapers = saved.library
            chatOverviews = saved.chats
            for id in saved.openPaperIDs {
                guard !openSessions.contains(where: { $0.id == id }) else { continue }
                guard let paper = saved.papers[id],
                      let pdf = await PDFCache.shared.cachedURL(paperID: id, root: paperCacheRoot) else { continue }
                let session = PaperSession(paper: paper)
                session.pdfURL = pdf
                await restorePaperExtras(session)
                openSessions.append(session)
            }
            if let id = saved.activePaperID, openSessions.contains(where: { $0.id == id }) {
                route = .paper(id)
            }
        } catch { errorMessage = "Could not restore the saved library: \(error.localizedDescription)" }
    }

    private func persistWorkspace(immediately: Bool = false) {
        guard let offlineStore else { return }
        workspace.revision += 1
        workspace.recent = recentPapers
        workspace.starred = starredPapers
        workspace.library = libraryPapers
        workspace.chats = chatOverviews
        workspace.openPaperIDs = openSessions.map(\.id)
        if case let .paper(id) = route { workspace.activePaperID = id }
        else { workspace.activePaperID = nil }
        let snapshot = workspace
        let previous = persistenceTask
        previous?.cancel()
        persistenceTask = Task {
            await previous?.value
            do {
                if !immediately { try await Task.sleep(for: .milliseconds(100)) }
                guard !Task.isCancelled else { return }
                try await offlineStore.saveWorkspace(snapshot)
            } catch is CancellationError {
                return
            } catch { errorMessage = "Could not save the offline library: \(error.localizedDescription)" }
        }
    }

    func flushLocalWorkspace() async {
        while let task = persistenceTask {
            let revision = workspace.revision
            await task.value
            if workspace.revision == revision { return }
        }
    }

    func refreshLibrary() async {
        guard !isRefreshingLibrary else { return }
        let generation = workspaceGeneration
        isRefreshingLibrary = true
        defer {
            if generation == workspaceGeneration { isRefreshingLibrary = false; persistWorkspace() }
        }
        do {
            let recent = try await client.recentPapers()
            guard generation == workspaceGeneration else { return }
            isOffline = false
            let pending = recentPapers.filter { workspace.pendingReadingStates[$0.id] != nil }
            recentPapers = pending + recent.filter { paper in !pending.contains(where: { $0.id == paper.id }) }
            persistWorkspace()
            for paper in recent where workspace.papers[paper.id] == nil {
                guard let legacy = await PDFCache.shared.cachedURL(paperID: paper.id) else { continue }
                guard generation == workspaceGeneration else { return }
                if let _ = try? await PDFCache.shared.storeLocalFile(
                    at: legacy, paperID: paper.id, root: paperCacheRoot
                ) { workspace.papers[paper.id] = paper }
            }
            await syncPendingReadingStates()
        } catch { if generation == workspaceGeneration { reportBackground(error) } }
        guard generation == workspaceGeneration, !isOffline else { return }
        // Endpoints update independently; failure preserves each saved list.
        do {
            let value = try await client.starredPapers()
            guard generation == workspaceGeneration else { return }
            starredPapers = value; persistWorkspace()
        } catch { if generation == workspaceGeneration { reportBackground(error) } }
        do {
            let value = try await client.libraryPapers()
            guard generation == workspaceGeneration else { return }
            libraryPapers = value; persistWorkspace()
        } catch { if generation == workspaceGeneration { reportBackground(error) } }
        do {
            let value = try await client.chats()
            guard generation == workspaceGeneration else { return }
            chatOverviews = value; persistWorkspace()
        } catch { if generation == workspaceGeneration { reportBackground(error) } }
        if generation == workspaceGeneration, !isOffline {
            for session in openSessions { refreshPaperInBackground(session) }
        }
    }

    private func reportBackground(_ error: Error) {
        guard !Self.isCancellation(error) else { return }
        if isConnectivityFailure(error) { isOffline = true }
        // Cached reading remains available; foreground actions report errors.
    }

    private func isConnectivityFailure(_ error: Error) -> Bool {
        if let error = error as? URLError { return error.code != .cancelled }
        if case APIError.server(let status, _) = error { return [401, 502, 503, 504].contains(status) }
        if case APIError.unauthorized = error { return true }
        return false
    }

    func loadModels() async {
        do {
            models = try await client.models()
            try? await offlineStore?.save(models, key: "models")
            let chosen = models.first(where: { $0.id == selectedModelID })
                ?? models.first(where: \.isDefault)
                ?? models.first
            selectModel(chosen?.id)
        } catch {
            if let saved: [ModelOption] = try? await offlineStore?.load("models") { models = saved }
            selectModel(models.first(where: \.isDefault)?.id ?? models.first?.id)
        }
    }

    func selectModel(_ id: String?) {
        selectedModelID = id
        guard let model = models.first(where: { $0.id == id }) else {
            selectedEffortID = nil
            return
        }
        if !model.supportedReasoningEfforts.contains(where: {
            $0.reasoningEffort == selectedEffortID
        }) {
            selectedEffortID = model.defaultReasoningEffort
        }
    }

    func navigate(to destination: WorkspaceRoute, fromSidebar: Bool = false) {
        defer { persistWorkspace() }
        if destination != route, let session = activeSession {
            stopPageViewTracking(session)
        }
        if fromSidebar {
            navigationHistory = []
            route = destination
            if case let .paper(id) = destination,
               let session = openSessions.first(where: { $0.id == id }) {
                startPageViewTracking(session)
            }
            if destination == .search {
                searchFocusToken = UUID()
            }
            return
        }
        guard destination != route else { return }
        navigationHistory.append(route)
        route = destination
        if case let .paper(id) = destination,
           let session = openSessions.first(where: { $0.id == id }) {
            startPageViewTracking(session)
        }
        if destination == .search {
            searchFocusToken = UUID()
        }
    }

    func goBack() {
        defer { persistWorkspace() }
        guard let destination = navigationHistory.popLast() else { return }
        if let session = activeSession {
            stopPageViewTracking(session)
        }
        route = destination
        if case let .paper(id) = destination,
           let session = openSessions.first(where: { $0.id == id }) {
            startPageViewTracking(session)
        }
    }

    func prepareSearch(for query: String) {
        searchGeneration = UUID()
        searchPapers = []
        hasMoreSearchResults = false
        isLoadingMoreSearchResults = false
        searchResultTotal = nil
        searchPaperCount = nil
        searchNextOffset = 0
        isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = UUID()
        searchGeneration = generation
        guard !trimmed.isEmpty else {
            searchPapers = []
            isSearching = false
            isLoadingMoreSearchResults = false
            hasMoreSearchResults = false
            searchResultTotal = nil
            searchPaperCount = nil
            searchNextOffset = 0
            return
        }
        isSearching = true
        isLoadingMoreSearchResults = false
        hasMoreSearchResults = false
        defer {
            if searchGeneration == generation {
                isSearching = false
            }
        }
        if isOffline {
            searchPapers = libraryPapers.filter {
                $0.title.localizedCaseInsensitiveContains(trimmed)
                    || $0.creators.contains { $0.displayName.localizedCaseInsensitiveContains(trimmed) }
            }.map {
                LibrarySearchPaper(itemKey: $0.itemKey, attachmentKey: $0.attachmentKey,
                    title: $0.title, creators: $0.creators, year: $0.year, evidence: [],
                    matchCount: 0, hasMoreEvidence: false)
            }
            searchPaperCount = searchPapers.count
            searchResultTotal = nil
            return
        }
        do {
            let response = try await client.search(
                trimmed,
                limit: searchPageSize,
                offset: 0
            )
            guard searchGeneration == generation,
                  searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else {
                return
            }
            isSearching = false
            searchPapers = response.papers
            hasMoreSearchResults = response.hasMore ?? (response.papers.count == searchPageSize)
            searchNextOffset = response.nextOffset ?? response.papers.count
            searchResultTotal = response.total
            searchPaperCount = response.paperCount
        } catch {
            guard searchGeneration == generation,
                  !Task.isCancelled,
                  !Self.isCancellation(error) else { return }
            report(error)
        }
    }

    func loadMoreSearchResults() async {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, hasMoreSearchResults,
              !isSearching, !isLoadingMoreSearchResults else { return }
        let generation = searchGeneration
        let offset = searchNextOffset
        isLoadingMoreSearchResults = true
        defer {
            if searchGeneration == generation {
                isLoadingMoreSearchResults = false
            }
        }
        do {
            let response = try await client.search(
                trimmed,
                limit: searchPageSize,
                offset: offset
            )
            guard searchGeneration == generation,
                  searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else {
                return
            }
            let existingIDs = Set(searchPapers.map(\.id))
            searchPapers.append(contentsOf: response.papers.filter { !existingIDs.contains($0.id) })
            hasMoreSearchResults = response.hasMore
                ?? (response.papers.count == searchPageSize)
            searchNextOffset = response.nextOffset ?? (offset + response.papers.count)
            searchResultTotal = response.total
            searchPaperCount = response.paperCount
            if response.papers.isEmpty {
                hasMoreSearchResults = false
            }
        } catch {
            guard searchGeneration == generation,
                  !Task.isCancelled,
                  !Self.isCancellation(error) else { return }
            report(error)
        }
    }

    func open(searchResult: LibrarySearchResult) async {
        guard let key = searchResult.usableAttachmentKey else { return }
        await perform {
            let paper = try await resolvePaper(attachmentKey: key)
            let session = try await openPaper(paper, fromSidebar: false)
            if let matchedPage = searchResult.matchedPage ?? searchResult.pageStart {
                let pageIndex = max(0, matchedPage - 1)
                recordPageActivity(in: session, pageIndex: pageIndex)
                session.pageIndex = pageIndex
                session.pdfHighlightTarget = PDFHighlightTarget(
                    token: UUID(),
                    query: searchResult.highlightQuery ?? searchQuery,
                    pageIndex: session.pageIndex,
                    occurrenceIndex: 0,
                    rects: []
                )
            }
        }
    }

    func open(searchPaper result: LibrarySearchPaper) async {
        guard let key = result.attachmentKey ?? result.representative?.usableAttachmentKey else {
            return
        }
        await perform {
            let paper = try await resolvePaper(attachmentKey: key)
            _ = try await openPaper(paper, fromSidebar: false)
        }
    }

    func open(libraryPaper: LibraryPaper) async {
        await perform {
            let paper = try await resolvePaper(attachmentKey: libraryPaper.attachmentKey)
            _ = try await openPaper(paper, fromSidebar: false)
        }
    }

    /// Opens a PDF selected by Zotero's external PDF viewer integration.
    /// Zotero hands macOS a file URL such as
    /// `file:///…/Zotero/storage/FQCTIC3M/document.pdf`; the storage directory
    /// name is the attachment key understood by the PaperChat server.
    func openExternalPDF(at url: URL) async {
        guard let attachmentKey = Self.zoteroAttachmentKey(from: url) else {
            errorMessage = "This PDF is not a Zotero storage attachment."
            return
        }
        guard PDFDocument(url: url) != nil else {
            errorMessage = "Zotero did not provide a readable PDF."
            return
        }

        // A document-open event can arrive before the window's startup task.
        // Restore the saved session here as well so a cold launch can resolve it.
        if !isAuthenticated {
            await restoreSession()
        }
        guard isAuthenticated else {
            errorMessage = "Sign in to PaperChat before opening a Zotero PDF."
            return
        }

        await perform {
            let paper: Paper
            do {
                paper = try await resolvePaper(attachmentKey: attachmentKey)
            } catch let error as APIError where error.isZoteroAttachmentNotFound {
                paper = try await client.resolveLocal(
                    attachmentKey: attachmentKey,
                    filename: url.lastPathComponent
                )
            }
            _ = try await PDFCache.shared.storeLocalFile(at: url, paperID: paper.id, root: paperCacheRoot)
            _ = try await openPaper(paper, fromSidebar: false)
        }
    }

    func open(paper: Paper, fromSidebar: Bool = false) async {
        await perform { _ = try await openPaper(paper, fromSidebar: fromSidebar) }
    }

    func open(chat: ChatOverview) async {
        await perform {
            guard let paperID = chat.paperID else {
                let session: ChatSession
                if let existing = managementSessions.first(where: { $0.selectedThread?.id == chat.id }) {
                    session = existing
                } else {
                    session = ChatSession()
                    if isOffline {
                        guard let thread: ChatThread = try await offlineStore?.load("thread/" + chat.id) else {
                            throw OfflineError.chatNotCached
                        }
                        session.selectedThread = thread
                    } else {
                        session.selectedThread = try await client.thread(id: chat.id)
                        try? await offlineStore?.save(session.selectedThread, key: "thread/" + chat.id)
                    }
                    session.isChatPresented = true
                    session.chatRoute = .conversation
                    managementSessions.append(session)
                }
                navigate(to: .management(session.id))
                return
            }
            let paper: Paper
            if let saved = workspace.papers[paperID] { paper = saved }
            else { paper = try await client.paper(id: paperID) }
            let session = try await openPaper(paper, fromSidebar: false)
            if let thread = session.threads.first(where: { $0.id == chat.id }) {
                try await selectThread(thread, in: session)
                session.isChatPresented = true
            }
        }
    }

    @discardableResult
    private func openPaper(_ paper: Paper, fromSidebar: Bool) async throws -> PaperSession {
        if let existing = openSessions.first(where: { $0.id == paper.id }) {
            refreshAgentTextAvailability(in: existing)
            if existing.documentStructure == nil {
                Task { await loadStructure(in: existing) }
            }
            if !fromSidebar {
                promoteInRecent(existing.paper)
            }
            navigate(to: .paper(existing.id), fromSidebar: fromSidebar)
            return existing
        }

        let cachedPaper = workspace.papers[paper.id] ?? paper
        let session = PaperSession(paper: cachedPaper)
        if let cached = await PDFCache.shared.cachedURL(paperID: paper.id, root: paperCacheRoot) {
            session.pdfURL = cached
            await restorePaperExtras(session)
            openSessions.append(session)
            if !fromSidebar { promoteInRecent(cachedPaper) }
            navigate(to: .paper(session.id), fromSidebar: fromSidebar)
            refreshPaperInBackground(session)
            return session
        }
        guard !isOffline else { throw OfflineError.pdfNotDownloaded }
        let detail = try await client.paper(id: paper.id)
        session.paper = detail
        session.pageIndex = detail.readingState?.pageIndex ?? 0
        session.scrollOffset = detail.readingState?.scrollOffset ?? 0
        session.zoomScale = detail.readingState?.zoomScale ?? 0
        if let legacy = await PDFCache.shared.cachedURL(paperID: detail.id) {
            session.pdfURL = try await PDFCache.shared.storeLocalFile(
                at: legacy, paperID: detail.id, root: paperCacheRoot
            )
        } else {
            let (data, etag) = try await client.downloadPDF(paperID: detail.id)
            session.pdfURL = try await PDFCache.shared.store(data, paperID: detail.id, etag: etag, root: paperCacheRoot)
        }
        workspace.papers[detail.id] = detail
        openSessions.append(session)
        if !fromSidebar { promoteInRecent(detail) }
        navigate(to: .paper(session.id), fromSidebar: fromSidebar)
        refreshPaperInBackground(session)
        return session
    }

    private func resolvePaper(attachmentKey: String) async throws -> Paper {
        if let paper = workspace.papers.values.first(where: {
            $0.identifiers?.contains(where: { $0.kind == "zotero" && $0.value == attachmentKey }) == true
        }) { return paper }
        guard !isOffline else { throw OfflineError.pdfNotDownloaded }
        return try await client.resolve(attachmentKey: attachmentKey)
    }

    private func restorePaperExtras(_ session: PaperSession) async {
        if let threads: [ChatThread] = try? await offlineStore?.load("threads/" + session.id) {
            session.threads = threads
            session.selectedThread = threads.first { $0.id == session.paper.readingState?.activeThreadID }
        }
        if let overview: BookmarkOverview = try? await offlineStore?.load("bookmarks/" + session.id) {
            session.bookmarks = overview.bookmarks
            session.bookmarkSuggestions = overview.suggestions
        }
        session.documentStructure = try? await offlineStore?.load("structure/" + session.id)
        await loadCachedMinerU(in: session)
    }

    private func refreshPaperInBackground(_ session: PaperSession) {
        guard !isOffline, paperRefreshTasks[session.id] == nil else { return }
        let generation = workspaceGeneration
        paperRefreshTasks[session.id] = Task { [weak self, weak session] in
            guard let self, let session else { return }
            defer { if generation == workspaceGeneration { paperRefreshTasks[session.id] = nil } }
            do {
                var detail = try await client.paper(id: session.id)
                guard !Task.isCancelled, generation == workspaceGeneration else { return }
                // Never move a viewport that the user is already reading.
                detail.readingState = workspace.papers[session.id]?.readingState ?? session.paper.readingState
                session.paper = detail
                workspace.papers[session.id] = detail
                let threads = try await client.threads(paperID: session.id)
                guard !Task.isCancelled, generation == workspaceGeneration else { return }
                session.threads = threads
                if session.selectedThread == nil {
                    session.selectedThread = threads.first { $0.id == detail.readingState?.activeThreadID }
                }
                try? await offlineStore?.save(threads, key: "threads/" + session.id)
                await loadBookmarks(in: session)
                await loadStructure(in: session)
                refreshAgentTextAvailability(in: session)
                persistWorkspace()
            } catch { if generation == workspaceGeneration { reportBackground(error) } }
        }
    }

    private func loadCachedMinerU(in session: PaperSession) async {
        guard let pdfURL = session.pdfURL,
              let key = session.paper.identifiers?.first(where: { $0.kind == "zotero" })?.value else { return }
        session.mineruDocument = try? await MinerUCache.shared.load(
            paperID: session.id, attachmentKey: key, pdfURL: pdfURL, root: paperCacheRoot
        )
    }

    private func refreshAgentTextAvailability(in session: PaperSession) {
        guard !isOffline else { return }
        session.agentTextAvailability = .checking
        Task { [weak self, weak session] in
            guard let self, let session else { return }
            let available = (try? await client.textAvailability(paperID: session.id)) ?? false
            session.agentTextAvailability = available ? .available : .unavailable
        }
    }

    private func promoteInRecent(_ paper: Paper) {
        recentPapers.removeAll(where: { $0.id == paper.id })
        recentPapers.insert(paper, at: 0)
        workspace.papers[paper.id] = paper
        persistWorkspace()
    }

    func toggleStar(in session: PaperSession) async {
        guard !isOffline else { errorMessage = "Connect to the server to change stars or bookmarks."; return }
        let next = !session.paper.isStarred
        do {
            let saved = try await client.setStar(paperID: session.id, starred: next)
            session.paper.starred = saved
            recentPapers = recentPapers.map {
                var paper = $0
                if paper.id == session.id { paper.starred = saved }
                return paper
            }
            if saved {
                starredPapers.removeAll(where: { $0.id == session.id })
                starredPapers.insert(session.paper, at: 0)
            } else {
                starredPapers.removeAll(where: { $0.id == session.id })
            }
            workspace.papers[session.id] = session.paper
            persistWorkspace()
        } catch {
            report(error)
        }
    }

    func presentChat(in session: PaperSession) {
        session.sidebarMode = .chat
        if session.selectedThread == nil, session.paper.readingState?.activeThreadID != nil {
            session.chatRoute = .conversation
        } else if session.threads.isEmpty {
            beginNewChat(in: session)
        } else if session.selectedThread == nil {
            session.chatRoute = .list
        }
        session.isChatPresented = true
    }

    func presentSearch(in session: PaperSession) {
        session.sidebarMode = .search
        session.isChatPresented = true
        session.pdfSearchFocusRequest += 1
    }

    func presentBookmarks(in session: PaperSession) {
        session.sidebarMode = .bookmarks
        session.isChatPresented = true
        Task { await loadBookmarks(in: session) }
    }

    func presentNavigate(in session: PaperSession) {
        session.sidebarMode = .navigate
        session.isChatPresented = true
        Task { await loadStructure(in: session) }
    }

    func loadStructure(in session: PaperSession) async {
        let generation = workspaceGeneration
        guard !isSimulatorBookmarkReproMode else { return }
        guard !session.isStructureLoading else { return }
        if session.documentStructure == nil {
            session.documentStructure = try? await offlineStore?.load("structure/" + session.id)
        }
        await loadCachedMinerU(in: session)
        guard !isOffline else { return }
        session.isStructureLoading = true
        defer { session.isStructureLoading = false }
        do {
            let structure = try await client.structure(paperID: session.id)
            guard generation == workspaceGeneration, !Task.isCancelled else { return }
            session.documentStructure = structure
            try? await offlineStore?.save(structure, key: "structure/" + session.id)
        } catch {
            guard !Self.isCancellation(error) else { return }
            reportBackground(error)
        }
        guard generation == workspaceGeneration, !isOffline,
              let pdfURL = session.pdfURL,
              let attachmentKey = session.paper.identifiers?.first(where: { $0.kind == "zotero" })?.value
        else { return }
        do {
            let cachedETag = await MinerUCache.shared.cachedETag(paperID: session.id, root: paperCacheRoot)
            let (data, etag) = try await client.downloadMinerU(paperID: session.id, etag: cachedETag)
            guard generation == workspaceGeneration, !Task.isCancelled else { return }
            if let data {
                try await MinerUCache.shared.store(data, paperID: session.id, etag: etag, root: paperCacheRoot)
            }
            session.mineruDocument = try await MinerUCache.shared.load(
                paperID: session.id, attachmentKey: attachmentKey, pdfURL: pdfURL, root: paperCacheRoot
            )
        } catch APIError.server(404, _) {
            session.mineruDocument = nil
        } catch {
            guard !Self.isCancellation(error) else { return }
            // Use a cached MinerU ZIP when Zotero or the network is unavailable.
            if session.mineruDocument == nil {
                session.mineruDocument = try? await MinerUCache.shared.load(
                    paperID: session.id, attachmentKey: attachmentKey, pdfURL: pdfURL, root: paperCacheRoot
                )
            }
        }
    }

    func openStructureAnchor(_ anchor: DocumentAnchor?, in session: PaperSession) {
        guard let anchor else { return }
        session.pageIndex = anchor.pageIndex
        session.pdfViewportTarget = nil
        session.pdfHighlightTarget = PDFHighlightTarget(
            token: UUID(), query: nil, pageIndex: anchor.pageIndex,
            occurrenceIndex: nil, rects: anchor.rects
        )
        recordPageActivity(in: session, pageIndex: anchor.pageIndex)
    }

    func openMatchedReference(_ reference: DocumentReference) async {
        guard let attachmentKey = reference.matchedAttachmentKey else { return }
        await perform {
            let paper = try await resolvePaper(attachmentKey: attachmentKey)
            _ = try await openPaper(paper, fromSidebar: false)
        }
    }

    func loadBookmarks(in session: PaperSession) async {
        let generation = workspaceGeneration
        guard !isOffline else { return }
        guard !isSimulatorBookmarkReproMode else { return }
        do {
            let overview = try await client.bookmarks(paperID: session.id)
            guard generation == workspaceGeneration, !Task.isCancelled else { return }
            try? await offlineStore?.save(overview, key: "bookmarks/" + session.id)
            session.bookmarks = overview.bookmarks
            session.bookmarkSuggestions = overview.suggestions
        } catch {
            guard !Self.isCancellation(error) else { return }
            reportBackground(error)
        }
    }

    func addPageBookmark(in session: PaperSession, pageIndex: Int? = nil) async {
        if isSimulatorBookmarkReproMode {
            let targetPage = pageIndex ?? session.bookmarkPageIndex
            let pagePosition = targetPage == session.bookmarkPageIndex
                ? session.pagePosition
                : 0
            let timestamp = ISO8601DateFormatter().string(from: .now)
            session.bookmarks.append(
                PaperBookmark(
                    id: UUID().uuidString,
                    paperID: session.id,
                    kind: .page,
                    pageIndex: targetPage,
                    pagePosition: pagePosition,
                    selectedText: nil,
                    selectionRects: [],
                    note: "Local simulator bookmark",
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            )
            sortBookmarks(in: session)
            return
        }
        guard !isOffline else { errorMessage = "Connect to the server to change bookmarks."; return }
        do {
            let targetPage = pageIndex ?? session.bookmarkPageIndex
            let bookmark = try await client.createBookmark(
                paperID: session.id,
                kind: .page,
                pageIndex: targetPage,
                pagePosition: targetPage == session.bookmarkPageIndex ? session.pagePosition : 0,
                selectedText: nil,
                selectionRects: []
            )
            session.bookmarks.removeAll(where: { $0.id == bookmark.id })
            session.bookmarks.append(bookmark)
            sortBookmarks(in: session)
            session.bookmarkSuggestions.removeAll(where: { $0.pageIndex == targetPage })
            await cacheBookmarks(in: session)
        } catch {
            report(error)
        }
    }

    func addSelectionBookmark(in session: PaperSession) async {
        guard !isOffline else { errorMessage = "Connect to the server to change stars or bookmarks."; return }
        guard !isSimulatorBookmarkReproMode else { return }
        guard let selection = session.selectionSnapshot, !selection.rects.isEmpty else { return }
        do {
            let pageIndex = selection.rects.first?.pageIndex ?? session.pageIndex
            let bookmark = try await client.createBookmark(
                paperID: session.id,
                kind: .selection,
                pageIndex: pageIndex,
                pagePosition: selection.rects.first.map {
                    min(max(1 - ($0.y + $0.height / 2), 0), 1)
                } ?? session.pagePosition,
                selectedText: selection.text,
                selectionRects: selection.rects
            )
            session.bookmarks.append(bookmark)
            sortBookmarks(in: session)
            await cacheBookmarks(in: session)
        } catch {
            report(error)
        }
    }

    func deleteBookmark(_ bookmark: PaperBookmark, in session: PaperSession) async {
        guard !isOffline else { errorMessage = "Connect to the server to change stars or bookmarks."; return }
        guard !isSimulatorBookmarkReproMode else { return }
        do {
            try await client.deleteBookmark(id: bookmark.id)
            session.bookmarks.removeAll(where: { $0.id == bookmark.id })
            await cacheBookmarks(in: session)
            await loadBookmarks(in: session)
        } catch {
            report(error)
        }
    }

    func openBookmark(_ bookmark: PaperBookmark, in session: PaperSession) {
        session.pageIndex = bookmark.pageIndex
        if bookmark.kind == .selection, !bookmark.selectionRects.isEmpty {
            session.pdfViewportTarget = nil
            session.pdfHighlightTarget = PDFHighlightTarget(
                token: UUID(),
                query: bookmark.selectedText,
                pageIndex: bookmark.pageIndex,
                occurrenceIndex: nil,
                rects: bookmark.selectionRects
            )
        } else {
            session.pdfViewportTarget = PDFViewportTarget(
                token: UUID(),
                pageIndex: bookmark.pageIndex,
                pagePosition: bookmark.pagePosition
            )
            session.pdfHighlightTarget = nil
        }
        recordPageActivity(in: session, pageIndex: bookmark.pageIndex)
    }

    func openSuggestion(_ suggestion: BookmarkSuggestion, in session: PaperSession) {
        session.pdfViewportTarget = nil
        session.pageIndex = suggestion.pageIndex
        session.pdfHighlightTarget = nil
        recordPageActivity(in: session, pageIndex: suggestion.pageIndex)
    }

    private func cacheBookmarks(in session: PaperSession) async {
        try? await offlineStore?.save(
            BookmarkOverview(bookmarks: session.bookmarks, suggestions: session.bookmarkSuggestions),
            key: "bookmarks/" + session.id
        )
    }

    private func sortBookmarks(in session: PaperSession) {
        session.bookmarks.sort {
            ($0.pageIndex, $0.createdAt) < ($1.pageIndex, $1.createdAt)
        }
    }

    func beginManagementChat() {
        let session = ChatSession()
        session.isChatPresented = true
        session.chatRoute = .compose
        managementSessions.append(session)
        navigate(to: .management(session.id))
    }

    func isConversationVisible(_ session: ChatSession) -> Bool {
        if session.isManagement { return route == .management(session.id) }
        return route == .paper(session.id) && session.isChatPresented
    }

    func showChatList(_ session: ChatSession) {
        if session.isManagement { navigate(to: .chats) }
        else { session.chatRoute = .list }
    }

    func beginNewChat(in session: ChatSession) {
        if session.isManagement {
            beginManagementChat()
            return
        }
        session.selectedThread = nil
        if let paper = session as? PaperSession {
            paper.paper.readingState?.activeThreadID = nil
            scheduleReadingStateSave(paper)
        }
        session.messages = []
        session.streamingMessage = nil
        session.chatRoute = .compose
        session.isChatPresented = true
    }

    func switchThread(_ thread: ChatThread, in session: PaperSession) async {
        await perform { try await selectThread(thread, in: session) }
    }

    private func selectThread(_ thread: ChatThread, in session: ChatSession) async throws {
        session.selectedThread = thread
        session.chatRoute = .conversation
        session.streamingMessage = nil
        if let messages: [ChatMessage] = try? await offlineStore?.load("messages/" + thread.id) {
            session.messages = messages
        }
        if !isOffline {
            session.messages = try await client.messages(threadID: thread.id)
            try? await offlineStore?.save(session.messages, key: "messages/" + thread.id)
        }
        if let paper = session as? PaperSession { try await saveReadingState(paper) }
    }

    func refreshConversation(in session: ChatSession) async {
        guard !isOffline else { return }
        guard let threadID = session.selectedThread?.id else { return }
        // The sending device owns its transient streaming bubble until its
        // POST stream finishes. Event invalidations still keep other devices
        // current without duplicating that local bubble or extra reads.
        guard session.streamingMessage == nil else { return }
        do {
            let messages = try await client.messages(threadID: threadID)
            guard session.selectedThread?.id == threadID else { return }
            guard session.streamingMessage == nil else { return }
            session.messages = messages
            try? await offlineStore?.save(messages, key: "messages/" + threadID)
            if !messages.contains(where: { $0.status == "streaming" }) {
                await refreshChatOverviews()
            }
        } catch {
            guard !Task.isCancelled, !Self.isCancellation(error) else { return }
            report(error)
        }
    }

    func followConversation(in session: ChatSession) async {
        guard !isOffline else { return }
        guard let threadID = session.selectedThread?.id else { return }
        var retryDelay = 1
        while !Task.isCancelled, session.selectedThread?.id == threadID {
            do {
                for try await _ in await client.threadEvents(threadID: threadID) {
                    guard !Task.isCancelled, session.selectedThread?.id == threadID else { return }
                    await refreshConversation(in: session)
                    retryDelay = 1
                }
            } catch {
                guard !Task.isCancelled, !Self.isCancellation(error) else { return }
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(retryDelay))
            retryDelay = min(retryDelay * 2, 15)
        }
    }

    func appDidBecomeActive() async {
        guard isAuthenticated else { return }
        await refreshLibrary()
        guard let session = activeSession else { return }
        guard !isOffline else { startPageViewTracking(session); return }
        startPageViewTracking(session)
        do {
            let threads = try await client.threads(paperID: session.id)
            session.threads = threads
            if let selectedID = session.selectedThread?.id {
                session.selectedThread = threads.first(where: { $0.id == selectedID })
                    ?? session.selectedThread
            }
        } catch {
            guard !Self.isCancellation(error) else { return }
            report(error)
        }
        if session.isChatPresented, session.chatRoute == .conversation {
            await refreshConversation(in: session)
        }
    }

    func appDidResignActive() {
        guard let session = activeSession else { return }
        stopPageViewTracking(session)
        rememberReadingState(session)
        persistWorkspace(immediately: true)
    }

    func chatKitRequest(body: String) async -> AsyncThrowingStream<ChatKitNetworkEvent, Error> {
        let generation = workspaceGeneration
        let key = ChatKitOfflineCache.key(body: body)
        let store = offlineStore
        return AsyncThrowingStream { continuation in
            let task = Task {
                func deliver(_ data: Data) {
                    continuation.yield(.headers(200, "application/json"))
                    continuation.yield(.chunk(String(decoding: data, as: UTF8.self)))
                }
                do {
                    if isOffline {
                        guard let key else { throw OfflineError.sendingRequiresConnection }
                        guard let data: Data = try await store?.load(key) else { throw OfflineError.chatNotCached }
                        deliver(ChatKitOfflineCache.readOnly(data))
                    } else if let key {
                        // Buffer read responses so a connection failure can fall
                        // back cleanly without partially delivering two responses.
                        var data = Data()
                        var status = 200
                        var contentType = "application/json"
                        for try await event in await client.chatKitRequest(body: body) {
                            switch event {
                            case .headers(let code, let type): status = code; contentType = type
                            case .chunk(let text): data.append(Data(text.utf8))
                            }
                        }
                        try Task.checkCancellation()
                        guard generation == workspaceGeneration else { throw CancellationError() }
                        if status == 200, (try? JSONSerialization.jsonObject(with: data)) != nil {
                            try? await store?.save(data, key: key)
                            deliver(data)
                        } else if [401, 502, 503, 504].contains(status),
                                  let cached: Data = try await store?.load(key) {
                            isOffline = true
                            deliver(ChatKitOfflineCache.readOnly(cached))
                        } else {
                            continuation.yield(.headers(status, contentType))
                            continuation.yield(.chunk(String(decoding: data, as: UTF8.self)))
                        }
                    } else {
                        for try await event in await client.chatKitRequest(body: body) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    guard !Task.isCancelled else { continuation.finish(); return }
                    reportBackground(error)
                    if let key, isConnectivityFailure(error),
                       let cached: Data = try? await store?.load(key) {
                        deliver(ChatKitOfflineCache.readOnly(cached))
                        continuation.finish()
                    } else { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func chatKitSelectedThread(_ id: String, in session: ChatSession) async {
        do {
            let thread: ChatThread
            if isOffline {
                let saved: ChatThread? = try? await offlineStore?.load("thread/" + id)
                guard let cached = session.threads.first(where: { $0.id == id }) ?? saved else { throw OfflineError.chatNotCached }
                thread = cached
            } else {
                thread = try await client.thread(id: id)
                try? await offlineStore?.save(thread, key: "thread/" + id)
            }
            guard thread.paperID == (session.isManagement ? nil : session.id) else { return }
            session.selectedThread = thread
            session.chatRoute = .conversation
            if !session.threads.contains(where: { $0.id == id }) { session.threads.insert(thread, at: 0) }
            if !session.isManagement { try? await offlineStore?.save(session.threads, key: "threads/" + session.id) }
            if let paper = session as? PaperSession { try await saveReadingState(paper) }
        } catch { report(error) }
    }

    private func cacheChatKitThread(_ id: String, in session: ChatSession) async {
        // Read directly through the native bridge: ChatKit's own short-lived
        // response cache can otherwise omit a just-completed turn from disk.
        let generation = workspaceGeneration
        var type = "threads.get_by_id"
        var params: [String: Any] = ["thread_id": id]
        while !isOffline, generation == workspaceGeneration, !Task.isCancelled {
            var context: [String: Any] = [:]
            if !session.isManagement { context["paper_id"] = session.id }
            guard let body = try? JSONSerialization.data(withJSONObject: [
                "type": type, "params": params, "metadata": ["paperchat": context]
            ]) else { return }
            do {
                var data = Data()
                for try await event in await chatKitRequest(body: String(decoding: body, as: UTF8.self)) {
                    if case .chunk(let text) = event { data.append(Data(text.utf8)) }
                }
                guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let page = type == "threads.get_by_id" ? response["items"] as? [String: Any] : response
                guard page?["has_more"] as? Bool == true,
                      let items = page?["data"] as? [[String: Any]],
                      let after = items.last?["id"] as? String, after != params["after"] as? String else { return }
                type = "items.list"
                params = ["thread_id": id, "limit": 9999, "order": "asc", "after": after]
            } catch { reportBackground(error); return }
        }
    }

    func chatKitFinished(in session: ChatSession) async {
        guard !isOffline else { return }
        session.isSending = false
        session.draft = ""
        if let id = session.selectedThread?.id {
            do {
                let thread = try await client.thread(id: id)
                try? await offlineStore?.save(thread, key: "thread/" + id)
                if session.selectedThread?.id == id { session.selectedThread = thread }
            } catch { report(error) }
        }
        if let id = session.selectedThread?.id { await cacheChatKitThread(id, in: session) }
        await refreshConversation(in: session)
        await refreshChatOverviews()
    }

    func send(in session: ChatSession) async {
        let question = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !session.isSending,
              !session.messages.contains(where: { $0.status == "streaming" }) else { return }
        session.isSending = true
        defer { session.isSending = false }
        let selectedText = session.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let messageCountBeforeSend = session.messages.count

        do {
            let thread: ChatThread
            if let selected = session.selectedThread {
                thread = selected
            } else {
                let title = String(question.prefix(80))
                if session.isManagement {
                    thread = try await client.createManagementChat(title: title)
                } else {
                    thread = try await client.createThread(paperID: session.id, title: title)
                }
                session.threads.insert(thread, at: 0)
                session.selectedThread = thread
                session.chatRoute = .conversation
                if let paper = session as? PaperSession { try await saveReadingState(paper) }
            }

            session.draft = ""
            let localUser = ChatMessage(
                id: UUID().uuidString,
                threadID: thread.id,
                role: "user",
                content: question,
                pageRefs: session.isManagement ? [] : [.init(pageIndex: session.pageIndex)],
                selectedText: selectedText,
                status: "completed",
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            session.messages.append(localUser)
            let assistant = StreamingChatMessage(threadID: thread.id)
            session.streamingMessage = assistant
            for try await event in await client.streamMessage(
                threadID: thread.id,
                content: question,
                pageIndex: session.pageIndex,
                selectedText: selectedText,
                model: selectedModel?.model,
                effort: selectedEffortID
            ) {
                switch event {
                case let .delta(text):
                    assistant.append(text)
                case let .answer(content):
                    assistant.replaceContent(with: content)
                case let .progress(update):
                    assistant.updateProgress(update)
                case .failure:
                    assistant.finish(status: "failed")
                    if let messages = try? await client.messages(threadID: thread.id) {
                        session.messages = messages
                        session.streamingMessage = nil
                    }
                case .done:
                    assistant.finish(status: "completed")
                    session.messages = try await client.messages(threadID: thread.id)
                    session.streamingMessage = nil
                    await refreshChatOverviews()
                case .message:
                    break
                }
            }
        } catch {
            session.streamingMessage?.finish(status: "failed")
            if let thread = session.selectedThread,
               let messages = try? await client.messages(threadID: thread.id) {
                let requestReachedServer = messages.count > messageCountBeforeSend
                session.messages = messages
                session.streamingMessage = nil
                if !requestReachedServer {
                    session.draft = question
                }
            } else {
                session.draft = question
                session.messages = Array(session.messages.prefix(messageCountBeforeSend))
                session.streamingMessage = nil
            }
        }
    }

    private func refreshChatOverviews() async {
        if let chats = try? await client.chats() {
            chatOverviews = chats
            persistWorkspace()
        }
    }

    func searchPDF(_ query: String, in session: PaperSession) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = session.pdfURL else {
            session.pdfSearchResults = []
            return
        }
        let worker = Task.detached(priority: .userInitiated) {
            Self.findPDFMatches(query: trimmed, url: url)
        }
        let results = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled,
              session.pdfSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else {
            return
        }
        session.pdfSearchResults = results
    }

    nonisolated private static func findPDFMatches(
        query: String,
        url: URL
    ) -> [PDFSearchResult] {
        guard let document = PDFDocument(url: url) else { return [] }
        var results: [PDFSearchResult] = []
        for pageIndex in 0..<document.pageCount {
            guard !Task.isCancelled else { return [] }
            guard let text = document.page(at: pageIndex)?.string else { continue }
            let source = text as NSString
            var searchRange = NSRange(location: 0, length: source.length)
            var occurrence = 0
            while searchRange.length > 0 {
                guard !Task.isCancelled else { return [] }
                let found = source.range(
                    of: query,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange
                )
                guard found.location != NSNotFound else { break }
                let contextStart = max(0, found.location - 80)
                let contextEnd = min(source.length, NSMaxRange(found) + 120)
                let snippet = source.substring(
                    with: NSRange(location: contextStart, length: contextEnd - contextStart)
                )
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                results.append(PDFSearchResult(
                    id: "\(pageIndex)-\(occurrence)-\(found.location)",
                    pageIndex: pageIndex,
                    occurrenceIndex: occurrence,
                    snippet: snippet
                ))
                occurrence += 1
                let next = NSMaxRange(found)
                searchRange = NSRange(location: next, length: source.length - next)
            }
        }
        return results
    }

    func selectPDFSearchResult(_ result: PDFSearchResult, in session: PaperSession) {
        session.pdfViewportTarget = nil
        recordPageActivity(in: session, pageIndex: result.pageIndex)
        session.pageIndex = result.pageIndex
        session.pdfHighlightTarget = PDFHighlightTarget(
            token: UUID(),
            query: session.pdfSearchQuery,
            pageIndex: result.pageIndex,
            occurrenceIndex: result.occurrenceIndex,
            rects: []
        )
    }

    func pageChanged(_ index: Int, in session: PaperSession) {
        guard session.pageIndex != index else { return }
        session.pdfViewportTarget = nil
        recordPageActivity(in: session, pageIndex: index)
        session.pageIndex = index
        scheduleReadingStateSave(session)
    }

    func pdfViewStateChanged(
        in session: PaperSession,
        pageIndex: Int,
        zoomScale: Double,
        scrollOffset: Double,
        pagePosition: Double? = nil
    ) {
        recordPageActivity(in: session, pageIndex: pageIndex)
        session.pageIndex = pageIndex
        session.zoomScale = zoomScale
        session.scrollOffset = scrollOffset
        if let pagePosition { session.pagePosition = pagePosition }
        scheduleReadingStateSave(session)
    }

    @discardableResult
    private func rememberReadingState(_ session: PaperSession) -> Bool {
        let position = PendingReadingState(
            pageIndex: session.pageIndex, scrollOffset: session.scrollOffset,
            zoomScale: max(session.zoomScale, 0.01),
            activeThreadID: session.selectedThread?.id ?? session.paper.readingState?.activeThreadID
        )
        if let previous = workspace.papers[session.id]?.readingState,
           previous.pageIndex == position.pageIndex, previous.scrollOffset == position.scrollOffset,
           previous.zoomScale == position.zoomScale, previous.activeThreadID == position.activeThreadID { return false }
        workspace.pendingReadingStates[session.id] = position
        var paper = session.paper
        paper.readingState = ReadingState(
            paperID: session.id, deviceID: persistentDeviceID(), pageIndex: position.pageIndex,
            scrollOffset: position.scrollOffset, zoomScale: position.zoomScale,
            displayMode: "singlePageContinuous", activeThreadID: position.activeThreadID,
            updatedAt: ISO8601DateFormatter().string(from: .now)
        )
        session.paper = paper
        workspace.papers[session.id] = paper
        return true
    }

    private func scheduleReadingStateSave(_ session: PaperSession) {
        guard !isSimulatorBookmarkReproMode else { return }
        guard rememberReadingState(session) else { return }
        // Persist before the network debounce, including when offline.
        persistWorkspace()
        saveTasks[session.id]?.cancel()
        saveTasks[session.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, !isOffline else { return }
            await syncPendingReadingStates()
        }
    }

    private func saveReadingState(_ session: PaperSession) async throws {
        rememberReadingState(session)
        persistWorkspace()
        if !isOffline { await syncPendingReadingStates() }
    }

    private func syncPendingReadingStates() async {
        guard !isSyncingReadingStates, !isOffline else { return }
        let generation = workspaceGeneration
        isSyncingReadingStates = true
        defer {
            if generation == workspaceGeneration { isSyncingReadingStates = false; persistWorkspace() }
        }
        // Coalesce positions, but do not lose a newer position written while
        // awaiting an earlier acknowledgement. Bound retries of rejected edits.
        for _ in 0..<3 {
            guard generation == workspaceGeneration, !isOffline,
                  !workspace.pendingReadingStates.isEmpty else { break }
            for (id, state) in workspace.pendingReadingStates {
                do {
                    try await client.saveReadingState(
                        paperID: id, pageIndex: state.pageIndex, scrollOffset: state.scrollOffset,
                        zoomScale: state.zoomScale, displayMode: "singlePageContinuous",
                        activeThreadID: state.activeThreadID
                    )
                    guard generation == workspaceGeneration else { return }
                    if workspace.pendingReadingStates[id]?.revision == state.revision {
                        workspace.pendingReadingStates.removeValue(forKey: id)
                    }
                } catch {
                    guard generation == workspaceGeneration else { return }
                    reportBackground(error)
                    if isOffline { return }
                }
            }
        }
    }

    private func startPageViewTracking(_ session: PaperSession) {
        guard !isSimulatorBookmarkReproMode else { return }
        recordPageActivity(in: session, pageIndex: session.pageIndex)
        guard pageViewTasks[session.id] == nil else { return }
        pageViewTasks[session.id] = Task { [weak self, weak session] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, let session else { return }
                self.checkpointPageView(session, at: Date())
            }
        }
    }

    private func stopPageViewTracking(_ session: PaperSession) {
        checkpointPageView(session, at: Date())
        pageViewTasks[session.id]?.cancel()
        pageViewTasks[session.id] = nil
        pageViewTrackers[session.id] = nil
    }

    private func recordPageActivity(in session: PaperSession, pageIndex: Int) {
        guard !isSimulatorBookmarkReproMode else { return }
        let current = Date()
        guard var tracker = pageViewTrackers[session.id] else {
            pageViewTrackers[session.id] = PageViewTracker(
                pageIndex: pageIndex,
                checkpoint: current,
                lastActivity: current,
                newVisitPending: true
            )
            return
        }
        if tracker.pageIndex != pageIndex {
            checkpointPageView(session, at: current)
            pageViewTrackers[session.id] = PageViewTracker(
                pageIndex: pageIndex,
                checkpoint: current,
                lastActivity: current,
                newVisitPending: true
            )
            return
        }
        if current.timeIntervalSince(tracker.lastActivity) > 90 {
            checkpointPageView(session, at: tracker.lastActivity.addingTimeInterval(90))
            tracker.checkpoint = current
            tracker.newVisitPending = true
        }
        tracker.lastActivity = current
        pageViewTrackers[session.id] = tracker
    }

    private func checkpointPageView(_ session: PaperSession, at current: Date) {
        guard !isSimulatorBookmarkReproMode else { return }
        guard var tracker = pageViewTrackers[session.id] else { return }
        let eligibleEnd = min(current, tracker.lastActivity.addingTimeInterval(90))
        let seconds = eligibleEnd.timeIntervalSince(tracker.checkpoint)
        guard seconds >= 1 else { return }
        let pageIndex = tracker.pageIndex
        let newVisit = tracker.newVisitPending
        tracker.checkpoint = eligibleEnd
        tracker.newVisitPending = false
        pageViewTrackers[session.id] = tracker
        Task { [weak self, weak session] in
            guard let self, let session, !isOffline else { return }
            try? await client.recordPageView(
                paperID: session.id,
                pageIndex: pageIndex,
                activeSeconds: min(seconds, 90),
                newVisit: newVisit
            )
            if session.sidebarMode == .bookmarks, session.isChatPresented {
                await self.loadBookmarks(in: session)
            }
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do { try await operation() }
        catch { report(error) }
    }

    private func report(_ error: Error) {
        if Self.isCancellation(error) {
            return
        }
        if isConnectivityFailure(error) { isOffline = true }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                errorMessage = "The request timed out. Check the PaperChat server and try again."
            case .notConnectedToInternet, .networkConnectionLost:
                errorMessage = "The network connection is unavailable. Check your connection and try again."
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                errorMessage = "PaperChat could not reach the server. Check the server address and connection."
            default:
                errorMessage = "A network error occurred. Please try again."
            }
            return
        }
        errorMessage = error.localizedDescription
    }

    nonisolated static func zoteroAttachmentKey(from url: URL) -> String? {
        guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else { return nil }
        let components = url.pathComponents
        guard let storageIndex = components.lastIndex(of: "storage"),
              components.indices.contains(storageIndex + 1) else { return nil }
        let key = components[storageIndex + 1]
        guard key.range(of: "^[A-Z0-9]{8}$", options: .regularExpression) != nil else {
            return nil
        }
        return key
    }

    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }

    private func normalizedServerURL() -> URL? {
        let value = serverURLString.hasSuffix("/") ? serverURLString : serverURLString + "/"
        return URL(string: value)
    }

    private func persistentDeviceID() -> String {
        if let existing = UserDefaults.standard.string(forKey: "deviceID") { return existing }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: "deviceID")
        return value
    }

    private func deviceName() -> String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }
}
