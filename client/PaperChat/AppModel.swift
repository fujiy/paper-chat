import Foundation
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
    @Published var searchResults: [LibrarySearchResult] = []
    @Published var searchQuery = ""
    @Published var route: WorkspaceRoute = .start
    @Published var openSessions: [PaperSession] = []
    @Published var models: [ModelOption] = []
    @Published var selectedModelID: String?

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
        searchResults = []
        openSessions = []
        route = .start
    }

    func refreshLibrary() async {
        await perform { recentPapers = try await client.recentPapers() }
    }

    func loadModels() async {
        do {
            let loaded = try await client.models()
            models = loaded
            if selectedModelID == nil || !loaded.contains(where: { $0.id == selectedModelID }) {
                selectedModelID = loaded.first(where: \.isDefault)?.id ?? loaded.first?.id
            }
        } catch {
            models = []
            selectedModelID = nil
        }
    }

    func showStart() {
        route = .start
    }

    func showRecent() {
        route = .recent
    }

    func showSearch() {
        route = .search
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
            try await openPaper(paper)
        }
    }

    func open(paper: Paper) async {
        await perform { try await openPaper(paper) }
    }

    private func openPaper(_ paper: Paper) async throws {
        if let existing = openSessions.first(where: { $0.id == paper.id }) {
            route = .paper(existing.id)
            return
        }

        let detail = try await client.paper(id: paper.id)
        let session = PaperSession(paper: detail)
        session.threads = try await client.threads(paperID: detail.id)
        if let activeID = detail.readingState?.activeThreadID,
           let active = session.threads.first(where: { $0.id == activeID }) {
            session.selectedThread = active
        }
        if let selectedThread = session.selectedThread {
            session.messages = try await client.messages(threadID: selectedThread.id)
            session.chatRoute = .conversation
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
        route = .paper(session.id)
    }

    func showChatList(_ session: PaperSession) {
        session.chatRoute = .list
    }

    func switchThread(_ thread: ChatThread, in session: PaperSession) async {
        session.selectedThread = thread
        session.chatRoute = .conversation
        await perform {
            session.messages = try await client.messages(threadID: thread.id)
            try await saveReadingState(session)
        }
    }

    func createThread(in session: PaperSession) async {
        await perform {
            let thread = try await client.createThread(
                paperID: session.id, title: "Chat \(session.threads.count + 1)"
            )
            session.threads.insert(thread, at: 0)
            session.selectedThread = thread
            session.messages = []
            session.chatRoute = .conversation
            session.isChatPresented = true
            try await saveReadingState(session)
        }
    }

    func send(in session: PaperSession) async {
        guard let thread = session.selectedThread else { return }
        let question = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
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
        do {
            for try await event in await client.streamMessage(
                threadID: thread.id,
                content: question,
                pageIndex: session.pageIndex,
                selectedText: session.selectedText,
                model: selectedModel?.model
            ) {
                switch event {
                case let .delta(text):
                    assistant.content += text
                    session.messages[assistantIndex] = assistant
                case let .failure(detail):
                    errorMessage = detail
                case .done:
                    session.messages = try await client.messages(threadID: thread.id)
                case .message:
                    break
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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
