import Foundation

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
}

struct Creator: Codable, Hashable, Sendable {
    let name: String?
    let firstName: String?
    let lastName: String?

    var displayName: String {
        name ?? [firstName, lastName].compactMap { $0 }.joined(separator: " ")
    }
}

struct PaperIdentifier: Codable, Hashable, Sendable {
    let kind: String
    let libraryType: String?
    let libraryID: String?
    let value: String
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
}

struct PageReference: Codable, Hashable, Sendable {
    let pageIndex: Int
}

struct LibrarySearchResponse: Codable, Sendable {
    let results: [LibrarySearchResult]
}

struct LibrarySearchResult: Codable, Identifiable, Sendable {
    var id: String { resolvedAttachmentKey ?? "\(title)-\(year ?? "")" }
    let title: String
    let creators: [Creator]?
    let year: String?
    let resolvedAttachmentKey: String?
    let attachmentKey: String?

    var usableAttachmentKey: String? { resolvedAttachmentKey ?? attachmentKey }
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
