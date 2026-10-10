import CryptoKit
import Foundation

struct PendingReadingState: Codable, Sendable, Equatable {
    var revision = UUID()
    var pageIndex: Int
    var scrollOffset: Double
    var zoomScale: Double
    var activeThreadID: String?

    private enum CodingKeys: String, CodingKey {
        case revision, pageIndex, scrollOffset, zoomScale
        case activeThreadID = "activeThreadId"
    }
}

struct OfflineWorkspace: Codable, Sendable {
    var version = 1
    var revision = 0
    var recent: [Paper] = []
    var starred: [Paper] = []
    var library: [LibraryPaper] = []
    var chats: [ChatOverview] = []
    var papers: [String: Paper] = [:]
    var openPaperIDs: [String] = []
    var activePaperID: String?
    var pendingReadingStates: [String: PendingReadingState] = [:]

    private enum CodingKeys: String, CodingKey {
        case version, revision, recent, starred, library, chats, papers, pendingReadingStates
        case openPaperIDs = "openPaperIds"
        case activePaperID = "activePaperId"
    }
}

/// Each server has its own namespace. Unsent edits live in the workspace,
/// separately from replaceable API responses and document files.
actor OfflineStore {
    let root: URL
    private var newestRevision = -1

    init(serverURL: URL, directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appending(path: "PaperChat/offline", directoryHint: .isDirectory)
        root = base.appending(path: Self.key(serverURL.absoluteString), directoryHint: .isDirectory)
    }

    func loadWorkspace() throws -> OfflineWorkspace? {
        guard let workspace: OfflineWorkspace = try load("workspace") else { return nil }
        guard workspace.version == 1 else { return nil }
        newestRevision = workspace.revision
        return workspace
    }

    func saveWorkspace(_ workspace: OfflineWorkspace) throws {
        guard workspace.revision >= newestRevision else { return }
        try save(workspace, key: "workspace")
        newestRevision = workspace.revision
    }

    func load<T: Decodable & Sendable>(_ key: String) throws -> T? {
        let url = location(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder.paperChat.decode(T.self, from: Data(contentsOf: url))
    }

    func save<T: Encodable & Sendable>(_ value: T, key: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder.paperChat.encode(value).write(to: location(key), options: .atomic)
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        newestRevision = -1
    }

    nonisolated static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func location(_ key: String) -> URL {
        root.appending(path: Self.key(key) + ".json")
    }
}

enum OfflineError: LocalizedError {
    case pdfNotDownloaded
    case chatNotCached
    case sendingRequiresConnection

    var errorDescription: String? {
        switch self {
        case .pdfNotDownloaded: "This PDF has not been saved on this device. Connect to the server to download it."
        case .chatNotCached: "This conversation has not been saved on this device. Connect to the server to open it."
        case .sendingRequiresConnection: "Connect to the server to send a message."
        }
    }
}

/// Request metadata includes transient page/selection/request IDs. Cache only
/// read operations, keyed by workspace scope and the exact pagination parameters.
enum ChatKitOfflineCache {
    static func key(body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = request["type"] as? String,
              ["threads.list", "threads.get_by_id", "items.list"].contains(type) else { return nil }
        let metadata = request["metadata"] as? [String: Any]
        let paperchat = metadata?["paperchat"] as? [String: Any]
        let value: [String: Any] = [
            "type": type, "params": request["params"] ?? [:],
            "paper_id": paperchat?["paper_id"] ?? NSNull()
        ]
        guard let canonical = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return "chatkit/" + OfflineStore.key(String(decoding: canonical, as: UTF8.self))
    }

    static func readOnly(_ data: Data) -> Data {
        guard var value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        let status: [String: Any] = ["type": "locked", "reason": "Offline. Connect to send messages."]
        if value["items"] != nil { value["status"] = status }
        else if let threads = value["data"] as? [[String: Any]], threads.contains(where: { $0["items"] != nil }) {
            value["data"] = threads.map { thread in
                var thread = thread; thread["status"] = status; return thread
            }
        }
        return (try? JSONSerialization.data(withJSONObject: value)) ?? data
    }
}
