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
        try await request("api/chats?include_management=true")
    }

    func search(_ query: String, limit: Int, offset: Int) async throws -> LibrarySearchResponse {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "evidence_limit", value: "5"),
            URLQueryItem(name: "caller", value: "paperchat-swift"),
        ]
        let queryString = components.percentEncodedQuery ?? ""
        return try await request("api/library/search?\(queryString)")
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

    func resolveLocal(attachmentKey: String, filename: String) async throws -> Paper {
        try await request(
            "api/papers/resolve-local",
            method: "POST",
            body: ["attachment_key": attachmentKey, "filename": filename]
        )
    }

    func paper(id: String) async throws -> Paper {
        try await request("api/papers/\(id)")
    }

    func textAvailability(paperID: String) async throws -> Bool {
        let response: TextAvailabilityResponse = try await request(
            "api/papers/\(paperID)/text-availability"
        )
        return response.available
    }

    func structure(paperID: String) async throws -> DocumentStructure {
        try await request("api/papers/\(paperID)/structure")
    }

    func setStar(paperID: String, starred: Bool) async throws -> Bool {
        let response: StarResponse = try await request(
            "api/papers/\(paperID)/star",
            method: "PATCH",
            body: ["starred": starred]
        )
        return response.starred
    }

    func bookmarks(paperID: String) async throws -> BookmarkOverview {
        try await request("api/papers/\(paperID)/bookmarks")
    }

    func createBookmark(
        paperID: String,
        kind: BookmarkKind,
        pageIndex: Int,
        scrollOffset: Double,
        selectedText: String?,
        selectionRects: [BookmarkSelectionRect]
    ) async throws -> PaperBookmark {
        try await request(
            "api/papers/\(paperID)/bookmarks",
            method: "POST",
            body: BookmarkCreateBody(
                kind: kind,
                pageIndex: pageIndex,
                scrollOffset: max(0, scrollOffset),
                selectedText: selectedText,
                selectionRects: selectionRects
            )
        )
    }

    func deleteBookmark(id: String) async throws {
        let request = try authorizedRequest("api/bookmarks/\(id)", method: "DELETE")
        let (data, response) = try await data(for: request, authenticated: true)
        try validate(response: response, data: data)
    }

    func recordPageView(
        paperID: String,
        pageIndex: Int,
        activeSeconds: Double,
        newVisit: Bool
    ) async throws {
        let body: [String: AnyEncodable] = [
            "page_index": AnyEncodable(pageIndex),
            "active_seconds": AnyEncodable(activeSeconds),
            "new_visit": AnyEncodable(newVisit),
        ]
        let _: UpdatedAt = try await request(
            "api/papers/\(paperID)/page-views", method: "POST", body: body
        )
    }

    func threads(paperID: String) async throws -> [ChatThread] {
        try await request("api/papers/\(paperID)/threads")
    }

    func createThread(paperID: String, title: String = "Main") async throws -> ChatThread {
        try await request(
            "api/papers/\(paperID)/threads", method: "POST", body: ["title": title]
        )
    }

    func createManagementChat(title: String) async throws -> ChatThread {
        try await request("api/chats", method: "POST", body: ["title": title])
    }

    func thread(id: String) async throws -> ChatThread {
        try await request("api/threads/\(id)")
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

    func downloadMinerU(paperID: String, etag: String?) async throws -> (Data?, String?) {
        var request = try authorizedRequest("api/papers/\(paperID)/mineru")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await data(for: request, authenticated: true)
        if (response as? HTTPURLResponse)?.statusCode == 304 { return (nil, etag) }
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
                            case "answer":
                                continuation.yield(.answer(payload?["content"] as? String ?? ""))
                            case "progress":
                                continuation.yield(.progress(ChatProgressUpdate(
                                    id: payload?["id"] as? String ?? UUID().uuidString,
                                    kind: payload?["kind"] as? String ?? "activity",
                                    title: payload?["title"] as? String ?? "Working",
                                    detail: payload?["detail"] as? String ?? "",
                                    status: payload?["status"] as? String ?? "running",
                                    operation: payload?["operation"] as? String ?? "replace"
                                )))
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

    func chatKitRequest(body: String) -> AsyncThrowingStream<ChatKitNetworkEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try authorizedRequest("api/chatkit", method: "POST")
                    request.httpBody = Data(body.utf8)
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    var result = try await session.bytes(for: request)
                    if (result.1 as? HTTPURLResponse)?.statusCode == 401 {
                        try await refresh()
                        request = try withLatestAccessToken(request)
                        result = try await session.bytes(for: request)
                    }
                    guard let response = result.1 as? HTTPURLResponse else {
                        throw APIError.invalidResponse
                    }
                    let type = response.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
                    continuation.yield(.headers(response.statusCode, type))
                    if type.contains("text/event-stream") {
                        // Preserve SSE frame boundaries and Unicode without one JS call per byte.
                        for try await line in result.0.lines {
                            try Task.checkCancellation()
                            if line.hasPrefix("data:") {
                                continuation.yield(.chunk(line + "\n\n"))
                            }
                        }
                    } else {
                        var data = Data()
                        for try await byte in result.0 { data.append(byte) }
                        continuation.yield(.chunk(String(decoding: data, as: UTF8.self)))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func threadEvents(threadID: String) -> AsyncThrowingStream<Void, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try authorizedRequest("api/threads/\(threadID)/events")
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
                        try Task.checkCancellation()
                        if line.hasPrefix("event: ") {
                            eventName = String(line.dropFirst(7))
                        } else if line.hasPrefix("data: "), eventName == "sync" {
                            continuation.yield(())
                            eventName = ""
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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
        var result = try await dataWithTransientRetry(for: request)
        if authenticated, (result.1 as? HTTPURLResponse)?.statusCode == 401 {
            try await refresh()
            result = try await dataWithTransientRetry(for: withLatestAccessToken(request))
        }
        return result
    }

    private func dataWithTransientRetry(for request: URLRequest) async throws -> (Data, URLResponse) {
        let canRetry = request.httpMethod == "GET" || request.httpMethod == "HEAD"
        var attempt = 0
        while true {
            let result = try await session.data(for: request)
            guard canRetry,
                  let response = result.1 as? HTTPURLResponse,
                  Self.transientStatusCodes.contains(response.statusCode),
                  attempt < 2 else {
                return result
            }
            attempt += 1
            try await Task.sleep(for: .milliseconds(250 * attempt))
        }
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
                    Self.errorDetail(data: data, response: http)
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
            if let apiError = error as? APIError, apiError.isAuthenticationFailure {
                KeychainStore.delete(account: "tokens")
                tokens = nil
            }
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
                Self.errorDetail(data: data, response: response)
            )
        }
    }

    private static let transientStatusCodes: Set<Int> = [502, 503, 504]

    private static func errorDetail(data: Data, response: HTTPURLResponse) -> String {
        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = payload["error"] as? String, !error.isEmpty {
                return error
            }
            if let detail = payload["detail"] as? String, !detail.isEmpty {
                return detail
            }
        }
        let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if transientStatusCodes.contains(response.statusCode)
            || contentType.contains("text/html")
            || body.lowercased().hasPrefix("<!doctype html")
            || body.lowercased().hasPrefix("<html") {
            return "The server is temporarily unavailable. Please try again."
        }
        return body.isEmpty ? "Request failed." : String(body.prefix(500))
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

private struct BookmarkCreateBody: Encodable {
    let kind: BookmarkKind
    let pageIndex: Int
    let scrollOffset: Double
    let selectedText: String?
    let selectionRects: [BookmarkSelectionRect]
}

enum APIError: LocalizedError {
    case invalidURL, invalidResponse, unauthorized, http(Int), server(Int, String), decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The PaperChat server URL is invalid. Check it in the sign-in screen."
        case .invalidResponse:
            "PaperChat received an invalid response from the server. Please try again."
        case .unauthorized:
            "Your PaperChat session has expired. Please sign in again."
        case let .http(status):
            Self.message(status: status, detail: "")
        case let .server(status, detail):
            Self.message(status: status, detail: detail)
        case .decoding:
            "PaperChat could not read the server response. The app and server may be out of date."
        }
    }

    var isAuthenticationFailure: Bool {
        switch self {
        case .unauthorized, .server(400, _), .server(401, _):
            true
        default:
            false
        }
    }

    var isZoteroAttachmentNotFound: Bool {
        if case .server(404, "zotero_attachment_not_found") = self {
            return true
        }
        return false
    }

    private static func message(status: Int, detail: String) -> String {
        switch detail {
        case "zotero_pdf_processing", "pdf_not_cached":
            return "This PDF is still being downloaded from Zotero. Please try again in a minute."
        case "zotero_attachment_not_found", "not_found":
            return "This Zotero attachment has not reached PaperChat yet. Zotero may still be syncing. Please try again later."
        case "zotero_auth_failed", "unauthorized":
            return "PaperChat could not authenticate with the Zotero API. Check the Zotero API credentials on the server."
        case "zotero_timeout", "zotero_unavailable":
            return "The Zotero API is temporarily unavailable. Please try again later."
        case "zotero_pdf_cache_error", "invalid_cache_path":
            return "PaperChat found the Zotero PDF, but its server cache is invalid. Check the Zotero service logs and try again."
        case "zotero_request_failed":
            return "PaperChat could not complete the request to Zotero. Please try again later."
        case "PDF source not found":
            return "This paper no longer has a Zotero PDF source. Open it again from Zotero or refresh the library."
        default:
            break
        }

        switch status {
        case 400:
            return "The request was not accepted by the server. Check the entered information and try again."
        case 401:
            return "Your PaperChat session has expired. Please sign in again."
        case 403:
            return "You do not have permission to perform this action."
        case 404:
            return "The requested paper or conversation could not be found. Refresh the library and try again."
        case 409:
            return detail.isEmpty ? "The request conflicts with an operation already in progress. Please try again shortly." : detail
        case 422:
            return "PaperChat could not process the request. Check the entered information and try again."
        case 502, 503, 504:
            return "A PaperChat service is temporarily unavailable. Please try again later."
        case 500...599:
            return "PaperChat encountered a server problem. Please try again later."
        default:
            return "The request failed (\(status)). Please try again."
        }
    }
}

struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { encodeValue = value.encode }
    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}


enum ChatKitNetworkEvent: Sendable {
    case headers(Int, String)
    case chunk(String)
}
