import Foundation
import SwiftUI
#if !os(macOS)
import UIKit
#endif

@MainActor
final class AppModel: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var recentPapers: [Paper] = []
    @Published var searchResults: [LibrarySearchResult] = []
    @Published var selectedPaper: Paper?
    @Published var selectedThread: ChatThread?
    @Published var threads: [ChatThread] = []
    @Published var messages: [ChatMessage] = []
    @Published var pdfURL: URL?
    @Published var pageIndex = 0
    @Published var selectedText: String?
    @Published var draft = ""

    @Published var serverURLString = UserDefaults.standard.string(forKey: "serverURL")
        ?? "http://localhost:8001/"
    private var client = APIClient(baseURL: URL(string: "http://localhost:8001/")!)

    func restoreSession() async {
        guard
            let baseURL = normalizedServerURL(),
            let tokenData = try? KeychainStore.load(account: "tokens"),
            let tokens = try? JSONDecoder.paperChat.decode(AuthTokens.self, from: tokenData)
        else { return }
        await client.configure(baseURL: baseURL, tokens: tokens)
        isAuthenticated = true
        await loadRecent()
    }

    func signIn(bootstrapToken: String) async {
        await perform {
            guard let url = normalizedServerURL() else { throw APIError.invalidURL }
            await client.configure(baseURL: url, tokens: nil)
            let deviceID = persistentDeviceID()
            let tokens = try await client.register(
                bootstrapToken: bootstrapToken,
                deviceID: deviceID,
                deviceName: deviceName()
            )
            try KeychainStore.save(JSONEncoder.paperChat.encode(tokens), account: "tokens")
            UserDefaults.standard.set(serverURLString, forKey: "serverURL")
            isAuthenticated = true
            await loadRecent()
        }
    }

    func signOut() {
        KeychainStore.delete(account: "tokens")
        isAuthenticated = false
        recentPapers = []
        selectedPaper = nil
    }

    func loadRecent() async {
        await perform { recentPapers = try await client.recentPapers() }
    }

    func search(_ query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            return
        }
        await perform { searchResults = try await client.search(query) }
    }

    func open(searchResult: LibrarySearchResult) async {
        guard let key = searchResult.usableAttachmentKey else { return }
        await perform {
            let paper = try await client.resolve(attachmentKey: key)
            try await open(paper: paper)
        }
    }

    func open(paper: Paper) async throws {
        selectedPaper = try await client.paper(id: paper.id)
        pageIndex = selectedPaper?.readingState?.pageIndex ?? 0
        threads = try await client.threads(paperID: paper.id)
        if threads.isEmpty {
            threads = [try await client.createThread(paperID: paper.id)]
        }
        let activeID = selectedPaper?.readingState?.activeThreadID
        selectedThread = threads.first(where: { $0.id == activeID }) ?? threads.first
        if let selectedThread {
            messages = try await client.messages(threadID: selectedThread.id)
        }
        if let cached = await PDFCache.shared.cachedURL(paperID: paper.id) {
            pdfURL = cached
        } else {
            let (data, etag) = try await client.downloadPDF(paperID: paper.id)
            pdfURL = try await PDFCache.shared.store(data, paperID: paper.id, etag: etag)
        }
    }

    func choose(paper: Paper) async {
        await perform { try await open(paper: paper) }
    }

    func send() async {
        guard let thread = selectedThread else { return }
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        let localUser = ChatMessage(
            id: UUID().uuidString,
            threadID: thread.id,
            role: "user",
            content: question,
            pageRefs: [.init(pageIndex: pageIndex)],
            selectedText: selectedText,
            status: "completed",
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        messages.append(localUser)
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
        messages.append(assistant)
        let assistantIndex = messages.count - 1
        do {
            for try await event in await client.streamMessage(
                threadID: thread.id,
                content: question,
                pageIndex: pageIndex,
                selectedText: selectedText
            ) {
                switch event {
                case let .delta(text):
                    assistant.content += text
                    messages[assistantIndex] = assistant
                case let .failure(detail):
                    errorMessage = detail
                case .done:
                    messages = try await client.messages(threadID: thread.id)
                case .message:
                    break
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pageChanged(_ index: Int) {
        pageIndex = index
        guard let paper = selectedPaper else { return }
        Task {
            try? await client.saveReadingState(
                paperID: paper.id, pageIndex: index, activeThreadID: selectedThread?.id
            )
        }
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
