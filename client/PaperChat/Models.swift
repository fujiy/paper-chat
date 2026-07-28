import Foundation
import SwiftUI

struct AuthTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let sessionId: String
}

struct Paper: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var authors: [Creator]
    var year: String?
    var identifiers: [PaperIdentifier]?
    var readingState: ReadingState?
    var lastOpenedAt: String?
    var starred: Bool?

    var isStarred: Bool { starred == true }
}

struct Creator: Codable, Hashable, Sendable {
    let name: String?
    let firstName: String?
    let lastName: String?

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            name = value
            firstName = nil
            lastName = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        firstName = try container.decodeIfPresent(String.self, forKey: .firstName)
        lastName = try container.decodeIfPresent(String.self, forKey: .lastName)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(firstName, forKey: .firstName)
        try container.encodeIfPresent(lastName, forKey: .lastName)
    }

    var displayName: String {
        name ?? [firstName, lastName].compactMap { $0 }.joined(separator: " ")
    }

    private enum CodingKeys: String, CodingKey {
        case name, firstName, lastName
    }
}

struct PaperIdentifier: Codable, Hashable, Sendable {
    let kind: String
    let libraryType: String?
    let libraryID: String?
    let value: String

    private enum CodingKeys: String, CodingKey {
        case kind, libraryType, value
        case libraryID = "libraryId"
    }
}

struct ReadingState: Codable, Hashable, Sendable {
    let paperID: String
    let deviceID: String
    var pageIndex: Int
    var scrollOffset: Double
    var zoomScale: Double
    var displayMode: String
    var activeThreadID: String?
    let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case pageIndex, scrollOffset, zoomScale, displayMode, updatedAt
        case paperID = "paperId"
        case deviceID = "deviceId"
        case activeThreadID = "activeThreadId"
    }
}

struct ChatThread: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let paperID: String
    var title: String
    let backendType: String
    let backendThreadID: String?
    let backendStatus: String
    let isPrimary: Int
    let lastUsedAt: String

    private enum CodingKeys: String, CodingKey {
        case id, title, backendType, backendStatus, isPrimary, lastUsedAt
        case paperID = "paperId"
        case backendThreadID = "backendThreadId"
    }
}

struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let threadID: String
    let role: String
    var content: String
    let pageRefs: [PageReference]
    let selectedText: String?
    let status: String
    let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case id, role, content, pageRefs, selectedText, status, createdAt
        case threadID = "threadId"
    }
}

struct PageReference: Codable, Hashable, Sendable {
    let pageIndex: Int
}

struct LibrarySearchResponse: Codable, Sendable {
    let results: [LibrarySearchResult]
}

struct LibrarySearchResult: Codable, Identifiable, Sendable {
    var id: String {
        "\(resolvedAttachmentKey ?? title)-\(matchedPage ?? pageStart ?? 0)-\(snippet ?? "")"
    }
    let title: String
    let paperTitle: String?
    let creators: [Creator]?
    let year: String?
    let resolvedAttachmentKey: String?
    let attachmentKey: String?
    let pageStart: Int?
    let pageEnd: Int?
    let matchedPage: Int?
    let snippet: String?
    let highlightQuery: String?

    var usableAttachmentKey: String? { resolvedAttachmentKey ?? attachmentKey }
    var displayTitle: String { paperTitle ?? title }
}

struct LibraryPaperResponse: Codable, Sendable {
    let papers: [LibraryPaper]
}

struct LibraryPaper: Codable, Identifiable, Hashable, Sendable {
    var id: String { attachmentKey }
    let itemKey: String
    let attachmentKey: String
    let title: String
    let creators: [Creator]
    let year: String?
}

struct StarResponse: Codable, Sendable {
    let starred: Bool
}

struct ChatOverview: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let paperID: String
    let title: String
    let backendType: String
    let backendThreadID: String?
    let backendStatus: String
    let isPrimary: Int
    let lastUsedAt: String
    let paperTitle: String
    let authors: [Creator]
    let year: String?
}

struct ModelListResponse: Codable, Sendable {
    let models: [ModelOption]
}

struct ModelOption: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let isDefault: Bool
    let defaultReasoningEffort: String
    let supportedReasoningEfforts: [ReasoningEffortOption]
}

struct ReasoningEffortOption: Codable, Identifiable, Hashable, Sendable {
    var id: String { reasoningEffort }
    let reasoningEffort: String
    let description: String
}

enum WorkspaceRoute: Hashable {
    case start
    case search
    case allPapers
    case recent
    case starred
    case chats
    case paper(String)
}

enum ChatRoute {
    case list
    case conversation
    case compose
}

struct PDFSearchResult: Identifiable, Hashable, Sendable {
    let id: String
    let pageIndex: Int
    let occurrenceIndex: Int
    let snippet: String
}

struct PDFHighlightTarget: Equatable, Sendable {
    let token: UUID
    let query: String
    let pageIndex: Int
    let occurrenceIndex: Int
}

@MainActor
final class PaperSession: ObservableObject, Identifiable {
    let id: String
    @Published var paper: Paper
    @Published var pdfURL: URL?
    @Published var pageIndex: Int
    @Published var zoomScale: Double
    @Published var scrollOffset: Double
    @Published var selectedText: String?
    @Published var draft = ""
    @Published var threads: [ChatThread] = []
    @Published var selectedThread: ChatThread?
    @Published var messages: [ChatMessage] = []
    @Published var isChatPresented = false
    @Published var chatRoute: ChatRoute = .list
    @Published var chatWidth: CGFloat = 390
    @Published var isPDFSearchPresented = false
    @Published var pdfSearchQuery = ""
    @Published var pdfSearchResults: [PDFSearchResult] = []
    @Published var pdfHighlightTarget: PDFHighlightTarget?

    init(paper: Paper) {
        id = paper.id
        self.paper = paper
        pageIndex = paper.readingState?.pageIndex ?? 0
        zoomScale = paper.readingState?.zoomScale ?? 0
        scrollOffset = paper.readingState?.scrollOffset ?? 0
    }
}

enum StreamEvent: Sendable {
    case message(String)
    case delta(String)
    case done
    case failure(String)
}

extension JSONDecoder {
    static var paperChat: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

extension JSONEncoder {
    static var paperChat: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}
