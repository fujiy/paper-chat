import Foundation

actor APIClient {
    private var baseURL: URL
    private var tokens: AuthTokens?
    private let session: URLSession
    private var refreshTask: Task<AuthTokens, Error>?

    init(baseURL: URL, tokens: AuthTokens? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.tokens = tokens
        self.session = session
    }

    func configure(baseURL: URL, tokens: AuthTokens?) {
        self.baseURL = baseURL
        self.tokens = tokens
    }

    func register(bootstrapToken: String, deviceID: String, deviceName: String) async throws -> AuthTokens {
        let body = [
            "bootstrap_token": bootstrapToken,
            "device_id": deviceID,
            "device_name": deviceName,
        ]
        let result: AuthTokens = try await request(
            "api/auth/register", method: "POST", body: body, authenticated: false
        )
        tokens = result
        return result
    }

    func recentPapers() async throws -> [Paper] {
        try await request("api/papers/recent")
    }

    func starredPapers() async throws -> [Paper] {
        try await request("api/papers/starred")
    }

    func libraryPapers() async throws -> [LibraryPaper] {
        let response: LibraryPaperResponse = try await request("api/library/papers?limit=1000")
        return response.papers
    }

    func chats() async throws -> [ChatOverview] {
        try await request("api/chats")
    }

    func search(_ query: String) async throws -> [LibrarySearchResult] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let response: LibrarySearchResponse = try await request("api/library/search?q=\(encoded)")
        return response.results
    }

    func models() async throws -> [ModelOption] {
        let response: ModelListResponse = try await request("api/models")
        return response.models
    }

    func resolve(attachmentKey: String) async throws -> Paper {
        try await request(
            "api/papers/resolve",
            method: "POST",
            body: ["attachment_key": attachmentKey]
        )
    }

    func paper(id: String) async throws -> Paper {
        try await request("api/papers/\(id)")
    }

    func setStar(paperID: String, starred: Bool) async throws -> Bool {
        let response: StarResponse = try await request(
            "api/papers/\(paperID)/star",
            method: "PATCH",
            body: ["starred": starred]
        )
        return response.starred
    }

    func threads(paperID: String) async throws -> [ChatThread] {
        try await request("api/papers/\(paperID)/threads")
    }

    func createThread(paperID: String, title: String = "Main") async throws -> ChatThread {
        try await request(
            "api/papers/\(paperID)/threads", method: "POST", body: ["title": title]
        )
    }

    func messages(threadID: String) async throws -> [ChatMessage] {
        try await request("api/threads/\(threadID)/messages")
    }

    func saveReadingState(
        paperID: String,
        pageIndex: Int,
        scrollOffset: Double,
        zoomScale: Double,
        displayMode: String,
        activeThreadID: String?
    ) async throws {
        let body: [String: AnyEncodable] = [
            "page_index": AnyEncodable(pageIndex),
            "scroll_offset": AnyEncodable(scrollOffset),
            "zoom_scale": AnyEncodable(zoomScale),
            "display_mode": AnyEncodable(displayMode),
            "active_thread_id": AnyEncodable(activeThreadID),
        ]
        let _: UpdatedAt = try await request(
            "api/papers/\(paperID)/reading-state", method: "PATCH", body: body
        )
    }

    func downloadPDF(paperID: String) async throws -> (Data, String?) {
        let request = try authorizedRequest("api/papers/\(paperID)/pdf")
        let (data, response) = try await data(for: request, authenticated: true)
        try validate(response: response, data: data)
        return (data, (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"))
    }

    func revokeCurrentSession() async throws {
        guard let sessionID = tokens?.sessionId else { return }
        let request = try authorizedRequest("api/sessions/\(sessionID)", method: "DELETE")
        let (data, response) = try await data(for: request, authenticated: true)
        try validate(response: response, data: data)
        tokens = nil
    }

    func streamMessage(
        threadID: String,
        content: String,
        pageIndex: Int,
        selectedText: String?,
        model: String?,
        effort: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = try authorizedRequest(
                        "api/threads/\(threadID)/messages", method: "POST"
                    )
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "content": content,
                        "current_page_index": pageIndex,
                        "selected_text": (selectedText ?? NSNull()) as Any,
                        "client_request_id": UUID().uuidString,
                        "model": (model ?? NSNull()) as Any,
                        "effort": (effort ?? NSNull()) as Any,
                    ])
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    var result = try await session.bytes(for: request)
                    if (result.1 as? HTTPURLResponse)?.statusCode == 401 {
                        try await refresh()
                        request = try withLatestAccessToken(request)
                        result = try await session.bytes(for: request)
                    }
                    guard let http = result.1 as? HTTPURLResponse, http.statusCode == 200 else {
                        throw APIError.http((result.1 as? HTTPURLResponse)?.statusCode ?? -1)
                    }
                    var eventName = ""
                    for try await line in result.0.lines {
                        if line.hasPrefix("event: ") {
                            eventName = String(line.dropFirst(7))
                        } else if line.hasPrefix("data: ") {
                            let data = Data(line.dropFirst(6).utf8)
                            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                            switch eventName {
                            case "message":
                                continuation.yield(.message(payload?["message_id"] as? String ?? ""))
                            case "delta":
                                continuation.yield(.delta(payload?["delta"] as? String ?? ""))
                            case "done":
                                continuation.yield(.done)
                            case "error":
                                continuation.yield(.failure(payload?["detail"] as? String ?? "Unknown error"))
                            default:
                                break
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func request<Response: Decodable, Body: Encodable>(
        _ path: String,
        method: String = "GET",
        body: Body? = Optional<String>.none,
        authenticated: Bool = true
    ) async throws -> Response {
        var request = try authorizedRequest(path, method: method, authenticated: authenticated)
        if let body {
            request.httpBody = try JSONEncoder.paperChat.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await data(for: request, authenticated: authenticated)
        try validate(response: response, data: data)
        do {
            return try JSONDecoder.paperChat.decode(Response.self, from: data)
        } catch let error as DecodingError {
            throw APIError.decoding(Self.describe(error))
        }
    }

    private func data(
        for request: URLRequest, authenticated: Bool
    ) async throws -> (Data, URLResponse) {
        var result = try await session.data(for: request)
        if authenticated, (result.1 as? HTTPURLResponse)?.statusCode == 401 {
            try await refresh()
            result = try await session.data(for: withLatestAccessToken(request))
        }
        return result
    }

    private func refresh() async throws {
        if let refreshTask {
            tokens = try await refreshTask.value
            return
        }
        guard let refreshToken = tokens?.refreshToken else { throw APIError.unauthorized }
        guard let url = URL(string: "api/auth/refresh", relativeTo: baseURL)?.absoluteURL else {
            throw APIError.invalidURL
        }
        let session = session
        let task = Task {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.httpBody = try JSONEncoder.paperChat.encode(
                ["refresh_token": refreshToken]
            )
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.server(
                    http.statusCode,
                    String(data: data, encoding: .utf8) ?? "Request failed"
                )
            }
            let refreshed = try JSONDecoder.paperChat.decode(AuthTokens.self, from: data)
            try KeychainStore.save(JSONEncoder.paperChat.encode(refreshed), account: "tokens")
            return refreshed
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            tokens = try await task.value
        } catch {
            KeychainStore.delete(account: "tokens")
            tokens = nil
            throw error
        }
    }

    private func withLatestAccessToken(_ request: URLRequest) throws -> URLRequest {
        guard let accessToken = tokens?.accessToken else { throw APIError.unauthorized }
        var request = request
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func authorizedRequest(
        _ path: String, method: String = "GET", authenticated: Bool = true
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        if authenticated {
            guard let accessToken = tokens?.accessToken else { throw APIError.unauthorized }
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.server(
                response.statusCode,
                String(data: data, encoding: .utf8) ?? "Request failed"
            )
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        let context: DecodingError.Context
        let detail: String
        switch error {
        case let .typeMismatch(type, value):
            context = value
            detail = "Expected \(type)"
        case let .valueNotFound(type, value):
            context = value
            detail = "Missing \(type)"
        case let .keyNotFound(key, value):
            context = value
            detail = "Missing key \(key.stringValue)"
        case let .dataCorrupted(value):
            context = value
            detail = "Corrupt data"
        @unknown default:
            return error.localizedDescription
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        let location = path.isEmpty ? "<root>" : path
        return "\(detail) at \(location): \(context.debugDescription)"
    }
}

private struct UpdatedAt: Decodable { let updatedAt: String }

enum APIError: LocalizedError {
    case invalidURL, invalidResponse, unauthorized, http(Int), server(Int, String), decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid server URL."
        case .invalidResponse: "The server returned an invalid response."
        case .unauthorized: "Sign in to continue."
        case let .http(status): "Request failed (\(status))."
        case let .server(status, detail): "Server error \(status): \(detail)"
        case let .decoding(detail): "The server response could not be decoded. \(detail)"
        }
    }
}

struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { encodeValue = value.encode }
    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}
