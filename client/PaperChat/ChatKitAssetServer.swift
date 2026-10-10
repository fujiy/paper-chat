import Foundation
import Network

/// Downloaded ChatKit UI assets are independent of authenticated conversation data.
/// Keep the entry script pinned to its cached version so its hashed dependencies
/// remain consistent across launches. Advance the cache directory on UI upgrades.
actor ChatKitAssetCache {
    static let shared = ChatKitAssetCache()
    let root: URL
    private let session: URLSession
    private var downloads: [String: Task<Data, Error>] = [:]
    private let maximumSize = 12 * 1024 * 1024

    init(directory: URL? = nil, session: URLSession = .shared) {
        root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "PaperChat/chatkit-ui-v1", directoryHint: .isDirectory)
        self.session = session
    }

    func asset(_ path: String, allowNetwork: Bool) async throws -> Data {
        guard Self.isAssetPath(path) else { throw URLError(.unsupportedURL) }
        let url = root.appending(path: String(path.dropFirst()))
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if path.hasSuffix(".css"), allowNetwork { await cacheFonts(in: data) }
            return data
        }
        guard allowNetwork else { throw OfflineError.chatNotCached }
        if let download = downloads[path] { return try await download.value }
        let session = session
        let limit = maximumSize
        let task = Task {
            let host = path.hasPrefix("/common/fonts/") ? "cdn.openai.com" : "cdn.platform.openai.com"
            var request = URLRequest(url: URL(string: "https://" + host + path)!)
            request.timeoutInterval = 30
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.host == host, data.count <= limit else {
                throw URLError(.badServerResponse)
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return data
        }
        downloads[path] = task
        defer { downloads[path] = nil }
        let data = try await task.value
        if path.hasSuffix(".css") { await cacheFonts(in: data) }
        return data
    }

    private func cacheFonts(in data: Data) async {
        let css = String(decoding: data, as: UTF8.self)
        let pattern = #"https://cdn\.openai\.com(/common/fonts/[^\s\)\"']+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let source = css as NSString
        let paths = regex.matches(in: css, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range(at: 1)) }
        await withTaskGroup(of: Void.self) { group in
            for path in Set(paths) {
                group.addTask { _ = try? await self.asset(path, allowNetwork: true) }
            }
        }
    }

    nonisolated static func isAssetPath(_ path: String) -> Bool {
        guard !path.contains(".."), !path.contains("%"), !path.contains("\\"),
              path.hasPrefix("/deployments/chatkit/") || path.hasPrefix("/assets/ck1/") || path.hasPrefix("/common/fonts/") else { return false }
        return ["js", "css", "html", "woff", "woff2", "ttf", "svg", "png", "ico"].contains(
            URL(fileURLWithPath: path).pathExtension
        )
    }

    nonisolated static func mimeType(_ path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension {
        case "js": "text/javascript"
        case "css": "text/css"
        case "html": "text/html; charset=utf-8"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "ttf": "font/ttf"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "ico": "image/x-icon"
        default: "application/octet-stream"
        }
    }
}

/// WebKit custom schemes have opaque origins, which do not support ChatKit's
/// origin-checked iframe bridge. A loopback-only, GET-only asset server preserves
/// ordinary HTTP origins without exposing tokens, API endpoints or chat content.
actor ChatKitAssetServer {
    private let assets: ChatKitAssetCache
    private let html: String
    private let onFailure: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "PaperChat.ChatKit.assets")
    private let pagePath = "/" + UUID().uuidString + "/ChatKit.html"
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var pageURL: URL?
    private var startTask: Task<URL, Error>?
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var allowNetwork = true
    private var stopped = false

    init(html: String, assets: ChatKitAssetCache = .shared, onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.assets = assets
        self.onFailure = onFailure
        self.html = html.replacingOccurrences(
            of: "https://cdn.platform.openai.com/deployments/chatkit/chatkit.js",
            with: "__PAPERCHAT_ASSET_ORIGIN__/deployments/chatkit/chatkit.js"
        )
    }

    func setOffline(_ offline: Bool) { allowNetwork = !offline }

    func start() async throws -> URL {
        guard !stopped else { throw CancellationError() }
        if let pageURL { return pageURL }
        if let startTask { return try await startTask.value }
        let task = Task { try await startListener() }
        startTask = task
        defer { startTask = nil }
        return try await task.value
    }

    private func startListener() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.stateChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.start(queue: queue)
        }
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port else { return }
            let url = URL(string: "http://localhost:\(port.rawValue)\(pagePath)")!
            pageURL = url
            startContinuation?.resume(returning: url)
            startContinuation = nil
        case .failed(let error):
            startContinuation?.resume(throwing: error)
            startContinuation = nil
            pageURL = nil
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task {
                guard let self else { connection.cancel(); return }
                var request = accumulated
                if let data { request.append(data) }
                if request.count > 16_384 || error != nil { connection.cancel(); return }
                if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                    await self.respond(connection, request: request)
                } else if !complete { await self.receive(connection, accumulated: request) }
                else { connection.cancel() }
            }
        }
    }

    private func respond(_ connection: NWConnection, request: Data) async {
        guard !stopped else { connection.cancel(); return }
        let parts = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")[0]
            .split(separator: " ")
        guard parts.count == 3, parts[0] == "GET" else {
            send(connection, status: 405, data: Data(), mime: "text/plain"); return
        }
        guard let port = listener?.port?.rawValue else { connection.cancel(); return }
        let headers = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        let host = headers.first { $0.lowercased().hasPrefix("host:") }?
            .dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased()
        guard host == "localhost:\(port)" || host == "127.0.0.1:\(port)" else {
            send(connection, status: 403, data: Data(), mime: "text/plain"); return
        }
        let path = String(parts[1]).components(separatedBy: "?")[0]
        if path == pagePath {
            // Keep the third-party iframe on a different origin from the native
            // wrapper, preserving the original main-frame bridge boundary.
            let page = html.replacingOccurrences(of: "__PAPERCHAT_ASSET_ORIGIN__", with: "http://127.0.0.1:\(port)")
            send(connection, status: 200, data: Data(page.utf8), mime: "text/html; charset=utf-8")
        } else if ChatKitAssetCache.isAssetPath(path) {
            do {
                var data = try await assets.asset(path, allowNetwork: allowNetwork)
                if path.hasSuffix(".css") {
                    data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(
                        of: "https://cdn.openai.com/common/fonts/", with: "/common/fonts/"
                    ).utf8)
                }
                send(connection, status: 200, data: data, mime: ChatKitAssetCache.mimeType(path))
            } catch {
                onFailure("ChatKit UI is not saved completely on this device. Connect to load it first.")
                send(connection, status: 503, data: Data(), mime: "text/plain")
            }
        } else { send(connection, status: 404, data: Data(), mime: "text/plain") }
    }

    private func send(_ connection: NWConnection, status: Int, data: Data, mime: String) {
        // Prevent the third-party UI from making external requests. API requests
        // use the existing main-frame native bridge, including offline responses.
        let assetOrigin = "http://127.0.0.1:\(listener?.port?.rawValue ?? 0)"
        let policy = "default-src 'self' data: blob:; script-src 'self' \(assetOrigin) 'unsafe-inline' 'unsafe-eval'; "
            + "frame-src 'self' \(assetOrigin); style-src 'self' 'unsafe-inline'; connect-src 'none'; img-src 'self' data: blob:"
        var response = Data(("HTTP/1.1 \(status) Response\r\nContent-Type: \(mime)\r\n"
            + "Content-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
            + "Content-Security-Policy: \(policy)\r\n\r\n").utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { await self?.finished(connection) }
        })
    }

    private func finished(_ connection: NWConnection) { connections[ObjectIdentifier(connection)] = nil }

    func stop() {
        stopped = true
        connections.values.forEach { $0.cancel() }
        connections = [:]
        listener?.cancel()
        listener = nil
        startContinuation?.resume(throwing: CancellationError())
        startContinuation = nil
    }
}
