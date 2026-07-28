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
    @Published var errorMessage: String?
    @Published var recentPapers: [Paper] = []
    @Published var starredPapers: [Paper] = []
    @Published var libraryPapers: [LibraryPaper] = []
    @Published var chatOverviews: [ChatOverview] = []
    @Published var searchResults: [LibrarySearchResult] = []
    @Published var searchQuery = ""
    @Published var searchFocusToken = UUID()
    @Published var route: WorkspaceRoute = .start
    @Published var navigationHistory: [WorkspaceRoute] = []
    @Published var openSessions: [PaperSession] = []
    @Published var models: [ModelOption] = []
    @Published var selectedModelID: String?
    @Published var selectedEffortID: String?

    @Published var serverURLString = UserDefaults.standard.string(forKey: "serverURL")
        ?? "http://localhost:8001/"

    private var client = APIClient(baseURL: URL(string: "http://localhost:8001/")!)
    private var saveTasks: [String: Task<Void, Never>] = [:]

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
        isAuthenticated = false
        recentPapers = []
        starredPapers = []
        libraryPapers = []
        chatOverviews = []
        searchResults = []
        openSessions = []
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
        if fromSidebar {
            navigationHistory = []
            route = destination
            if destination == .search {
                searchFocusToken = UUID()
            }
            return
        }
        guard destination != route else { return }
        navigationHistory.append(route)
        route = destination
        if destination == .search {
            searchFocusToken = UUID()
        }
    }

    func goBack() {
        guard let destination = navigationHistory.popLast() else { return }
        route = destination
    }

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        defer {
            if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
                isSearching = false
            }
        }
        do {
            let results = try await client.search(trimmed)
            guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else {
                return
            }
            searchResults = results
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(searchResult: LibrarySearchResult) async {
        guard let key = searchResult.usableAttachmentKey else { return }
        await perform {
            let paper = try await client.resolve(attachmentKey: key)
            let session = try await openPaper(paper, fromSidebar: false)
            if let matchedPage = searchResult.matchedPage ?? searchResult.pageStart {
                session.pageIndex = max(0, matchedPage - 1)
                session.pdfHighlightTarget = PDFHighlightTarget(
                    token: UUID(),
                    query: searchResult.highlightQuery ?? searchQuery,
                    pageIndex: session.pageIndex,
                    occurrenceIndex: 0
                )
            }
        }
    }

    func open(libraryPaper: LibraryPaper) async {
        await perform {
            let paper = try await client.resolve(attachmentKey: libraryPaper.attachmentKey)
            _ = try await openPaper(paper, fromSidebar: false)
        }
    }

    func open(paper: Paper, fromSidebar: Bool = false) async {
        await perform { _ = try await openPaper(paper, fromSidebar: fromSidebar) }
    }

    func open(chat: ChatOverview) async {
        await perform {
            let paper = try await client.paper(id: chat.paperID)
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
            navigate(to: .paper(existing.id), fromSidebar: fromSidebar)
            return existing
        }

        let detail = try await client.paper(id: paper.id)
        let session = PaperSession(paper: detail)
        session.threads = try await client.threads(paperID: detail.id)
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
        recentPapers.removeAll(where: { $0.id == detail.id })
        recentPapers.insert(detail, at: 0)
        openSessions.append(session)
        navigate(to: .paper(session.id), fromSidebar: fromSidebar)
        return session
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
            errorMessage = error.localizedDescription
        }
    }

    func presentChat(in session: PaperSession) {
        if session.threads.isEmpty {
            beginNewChat(in: session)
        } else if session.selectedThread == nil {
            session.chatRoute = .list
        }
        session.isChatPresented = true
    }

    func showChatList(_ session: PaperSession) {
        session.chatRoute = .list
    }

    func beginNewChat(in session: PaperSession) {
        session.selectedThread = nil
        session.messages = []
        session.chatRoute = .compose
        session.isChatPresented = true
    }

    func switchThread(_ thread: ChatThread, in session: PaperSession) async {
        await perform { try await selectThread(thread, in: session) }
    }

    private func selectThread(_ thread: ChatThread, in session: PaperSession) async throws {
        session.selectedThread = thread
        session.chatRoute = .conversation
        session.messages = try await client.messages(threadID: thread.id)
        try await saveReadingState(session)
    }

    func send(in session: PaperSession) async {
        let question = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        do {
            let thread: ChatThread
            if let selected = session.selectedThread {
                thread = selected
            } else {
                let title = String(question.prefix(80))
                thread = try await client.createThread(paperID: session.id, title: title)
                session.threads.insert(thread, at: 0)
                session.selectedThread = thread
                session.chatRoute = .conversation
                try await saveReadingState(session)
            }

            session.draft = ""
            let localUser = ChatMessage(
                id: UUID().uuidString,
                threadID: thread.id,
                role: "user",
                content: question,
                pageRefs: [.init(pageIndex: session.pageIndex)],
                selectedText: session.selectedText,
                status: "completed",
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            session.messages.append(localUser)
            var assistant = ChatMessage(
                id: UUID().uuidString,
                threadID: thread.id,
                role: "assistant",
                content: "",
                pageRefs: [],
                selectedText: nil,
                status: "streaming",
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            session.messages.append(assistant)
            let assistantIndex = session.messages.count - 1
            for try await event in await client.streamMessage(
                threadID: thread.id,
                content: question,
                pageIndex: session.pageIndex,
                selectedText: session.selectedText,
                model: selectedModel?.model,
                effort: selectedEffortID
            ) {
                switch event {
                case let .delta(text):
                    assistant.content += text
                    session.messages[assistantIndex] = assistant
                case let .failure(detail):
                    errorMessage = detail
                case .done:
                    session.messages = try await client.messages(threadID: thread.id)
                    await refreshChatOverviews()
                case .message:
                    break
                }
            }
        } catch {
            session.draft = question
            errorMessage = error.localizedDescription
        }
    }

    private func refreshChatOverviews() async {
        if let chats = try? await client.chats() {
            chatOverviews = chats
        }
    }

    func searchPDF(_ query: String, in session: PaperSession) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = session.pdfURL,
              let document = PDFDocument(url: url) else {
            session.pdfSearchResults = []
            return
        }
        var results: [PDFSearchResult] = []
        for pageIndex in 0..<document.pageCount {
            guard let text = document.page(at: pageIndex)?.string else { continue }
            let source = text as NSString
            var searchRange = NSRange(location: 0, length: source.length)
            var occurrence = 0
            while searchRange.length > 0 {
                let found = source.range(
                    of: trimmed,
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
        session.pdfSearchResults = results
    }

    func selectPDFSearchResult(_ result: PDFSearchResult, in session: PaperSession) {
        session.pageIndex = result.pageIndex
        session.pdfHighlightTarget = PDFHighlightTarget(
            token: UUID(),
            query: session.pdfSearchQuery,
            pageIndex: result.pageIndex,
            occurrenceIndex: result.occurrenceIndex
        )
    }

    func pageChanged(_ index: Int, in session: PaperSession) {
        guard session.pageIndex != index else { return }
        session.pageIndex = index
        scheduleReadingStateSave(session)
    }

    func pdfViewStateChanged(
        in session: PaperSession,
        pageIndex: Int,
        zoomScale: Double,
        scrollOffset: Double
    ) {
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

    private func perform(_ operation: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do { try await operation() }
        catch { errorMessage = error.localizedDescription }
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
