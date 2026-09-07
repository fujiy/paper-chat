import Foundation
import PDFKit
import SwiftUI
#if !os(macOS)
import UIKit
#endif

@MainActor
final class AppModel: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isBusy = false
    @Published var isSearching = false
    @Published var isLoadingMoreSearchResults = false
    @Published var hasMoreSearchResults = false
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

    private var client = APIClient(baseURL: URL(string: "http://localhost:8001/")!)
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
        guard
            let baseURL = normalizedServerURL(),
            let tokenData = try? KeychainStore.load(account: "tokens"),
            let tokens = try? JSONDecoder.paperChat.decode(AuthTokens.self, from: tokenData)
        else { return }
        await client.configure(baseURL: baseURL, tokens: tokens)
        isAuthenticated = true
        await refreshLibrary()
        await loadModels()
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
            isAuthenticated = true
        }
        if isAuthenticated {
            await refreshLibrary()
            await loadModels()
        }
    }

    func signOut() async {
        try? await client.revokeCurrentSession()
        KeychainStore.delete(account: "tokens")
        saveTasks.values.forEach { $0.cancel() }
        saveTasks = [:]
        pageViewTasks.values.forEach { $0.cancel() }
        pageViewTasks = [:]
        pageViewTrackers = [:]
        isAuthenticated = false
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
    }

    func refreshLibrary() async {
        await perform {
            async let recent = client.recentPapers()
            async let starred = client.starredPapers()
            async let papers = client.libraryPapers()
            async let chats = client.chats()
            recentPapers = try await recent
            starredPapers = try await starred
            libraryPapers = try await papers
            chatOverviews = try await chats
        }
    }

    func loadModels() async {
        do {
            models = try await client.models()
            let chosen = models.first(where: { $0.id == selectedModelID })
                ?? models.first(where: \.isDefault)
                ?? models.first
            selectModel(chosen?.id)
        } catch {
            models = []
            selectedModelID = nil
            selectedEffortID = nil
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
            let paper = try await client.resolve(attachmentKey: key)
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
            let paper = try await client.resolve(attachmentKey: key)
            _ = try await openPaper(paper, fromSidebar: false)
        }
    }

    func open(libraryPaper: LibraryPaper) async {
        await perform {
            let paper = try await client.resolve(attachmentKey: libraryPaper.attachmentKey)
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
                paper = try await client.resolve(attachmentKey: attachmentKey)
            } catch let error as APIError where error.isZoteroAttachmentNotFound {
                paper = try await client.resolveLocal(
                    attachmentKey: attachmentKey,
                    filename: url.lastPathComponent
                )
            }
            _ = try await PDFCache.shared.storeLocalFile(at: url, paperID: paper.id)
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
                    session.selectedThread = try await client.thread(id: chat.id)
                    session.isChatPresented = true
                    session.chatRoute = .conversation
                    session.messages = try await client.messages(threadID: chat.id)
                    managementSessions.append(session)
                }
                navigate(to: .management(session.id))
                return
            }
            let paper = try await client.paper(id: paperID)
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

        let detail = try await client.paper(id: paper.id)
        let session = PaperSession(paper: detail)
        session.threads = try await client.threads(paperID: detail.id)
        if let overview = try? await client.bookmarks(paperID: detail.id) {
            session.bookmarks = overview.bookmarks
            session.bookmarkSuggestions = overview.suggestions
        }
        if let activeID = detail.readingState?.activeThreadID,
           let active = session.threads.first(where: { $0.id == activeID }) {
            try await selectThread(active, in: session)
        }
        if let cached = await PDFCache.shared.cachedURL(paperID: detail.id) {
            session.pdfURL = cached
        } else {
            let (data, etag) = try await client.downloadPDF(paperID: detail.id)
            session.pdfURL = try await PDFCache.shared.store(data, paperID: detail.id, etag: etag)
        }
        if !fromSidebar {
            promoteInRecent(detail)
        }
        openSessions.append(session)
        refreshAgentTextAvailability(in: session)
        Task { await loadStructure(in: session) }
        navigate(to: .paper(session.id), fromSidebar: fromSidebar)
        return session
    }

    private func refreshAgentTextAvailability(in session: PaperSession) {
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
    }

    func toggleStar(in session: PaperSession) async {
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
        } catch {
            report(error)
        }
    }

    func presentChat(in session: PaperSession) {
        session.sidebarMode = .chat
        if session.threads.isEmpty {
            beginNewChat(in: session)
        } else if session.selectedThread == nil {
            session.chatRoute = .list
        }
        session.isChatPresented = true
    }

    func presentBookmarks(in session: PaperSession) {
        session.sidebarMode = .bookmarks
        session.isChatPresented = true
        Task { await loadBookmarks(in: session) }
    }

    func presentStructure(in session: PaperSession) {
        session.sidebarMode = .structure
        session.isChatPresented = true
        Task { await loadStructure(in: session) }
    }

    func loadStructure(in session: PaperSession) async {
        guard !session.isStructureLoading else { return }
        session.isStructureLoading = true
        defer { session.isStructureLoading = false }
        do {
            session.documentStructure = try await client.structure(paperID: session.id)
        } catch {
            guard !Self.isCancellation(error) else { return }
            report(error)
        }
    }

    func openStructureAnchor(_ anchor: DocumentAnchor?, in session: PaperSession) {
        guard let anchor else { return }
        session.pageIndex = anchor.pageIndex
        session.pdfViewportTarget = PDFViewportTarget(
            token: UUID(), pageIndex: anchor.pageIndex, scrollOffset: 0
        )
        session.pdfHighlightTarget = PDFHighlightTarget(
            token: UUID(), query: nil, pageIndex: anchor.pageIndex,
            occurrenceIndex: nil, rects: anchor.rects
        )
        recordPageActivity(in: session, pageIndex: anchor.pageIndex)
    }

    func openMatchedReference(_ reference: DocumentReference) async {
        guard let attachmentKey = reference.matchedAttachmentKey else { return }
        await perform {
            let paper = try await client.resolve(attachmentKey: attachmentKey)
            _ = try await openPaper(paper, fromSidebar: false)
        }
    }

    func loadBookmarks(in session: PaperSession) async {
        do {
            let overview = try await client.bookmarks(paperID: session.id)
            session.bookmarks = overview.bookmarks
            session.bookmarkSuggestions = overview.suggestions
        } catch {
            guard !Self.isCancellation(error) else { return }
            report(error)
        }
    }

    func addPageBookmark(in session: PaperSession, pageIndex: Int? = nil) async {
        do {
            let targetPage = pageIndex ?? session.pageIndex
            let bookmark = try await client.createBookmark(
                paperID: session.id,
                kind: .page,
                pageIndex: targetPage,
                scrollOffset: targetPage == session.pageIndex ? session.scrollOffset : 0,
                selectedText: nil,
                selectionRects: []
            )
            session.bookmarks.removeAll(where: { $0.id == bookmark.id })
            session.bookmarks.append(bookmark)
            sortBookmarks(in: session)
            session.bookmarkSuggestions.removeAll(where: { $0.pageIndex == targetPage })
        } catch {
            report(error)
        }
    }

    func addSelectionBookmark(in session: PaperSession) async {
        guard let selection = session.selectionSnapshot, !selection.rects.isEmpty else { return }
        do {
            let pageIndex = selection.rects.first?.pageIndex ?? session.pageIndex
            let bookmark = try await client.createBookmark(
                paperID: session.id,
                kind: .selection,
                pageIndex: pageIndex,
                scrollOffset: session.scrollOffset,
                selectedText: selection.text,
                selectionRects: selection.rects
            )
            session.bookmarks.append(bookmark)
            sortBookmarks(in: session)
        } catch {
            report(error)
        }
    }

    func deleteBookmark(_ bookmark: PaperBookmark, in session: PaperSession) async {
        do {
            try await client.deleteBookmark(id: bookmark.id)
            session.bookmarks.removeAll(where: { $0.id == bookmark.id })
            await loadBookmarks(in: session)
        } catch {
            report(error)
        }
    }

    func openBookmark(_ bookmark: PaperBookmark, in session: PaperSession) {
        session.pageIndex = bookmark.pageIndex
        session.scrollOffset = bookmark.scrollOffset
        session.pdfViewportTarget = PDFViewportTarget(
            token: UUID(),
            pageIndex: bookmark.pageIndex,
            scrollOffset: bookmark.scrollOffset
        )
        if bookmark.kind == .selection, !bookmark.selectionRects.isEmpty {
            session.pdfHighlightTarget = PDFHighlightTarget(
                token: UUID(),
                query: bookmark.selectedText,
                pageIndex: bookmark.pageIndex,
                occurrenceIndex: nil,
                rects: bookmark.selectionRects
            )
        } else {
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
        session.messages = try await client.messages(threadID: thread.id)
        if let paper = session as? PaperSession { try await saveReadingState(paper) }
    }

    func refreshConversation(in session: ChatSession) async {
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
            if !messages.contains(where: { $0.status == "streaming" }) {
                await refreshChatOverviews()
            }
        } catch {
            guard !Task.isCancelled, !Self.isCancellation(error) else { return }
            report(error)
        }
    }

    func followConversation(in session: ChatSession) async {
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
        scrollOffset: Double
    ) {
        recordPageActivity(in: session, pageIndex: pageIndex)
        session.pageIndex = pageIndex
        session.zoomScale = zoomScale
        session.scrollOffset = scrollOffset
        scheduleReadingStateSave(session)
    }

    private func scheduleReadingStateSave(_ session: PaperSession) {
        saveTasks[session.id]?.cancel()
        saveTasks[session.id] = Task { [weak self, weak session] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, let session else { return }
            try? await self.saveReadingState(session)
        }
    }

    private func saveReadingState(_ session: PaperSession) async throws {
        try await client.saveReadingState(
            paperID: session.id,
            pageIndex: session.pageIndex,
            scrollOffset: session.scrollOffset,
            zoomScale: max(session.zoomScale, 0.01),
            displayMode: "singlePageContinuous",
            activeThreadID: session.selectedThread?.id
        )
    }

    private func startPageViewTracking(_ session: PaperSession) {
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
            guard let self, let session else { return }
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
