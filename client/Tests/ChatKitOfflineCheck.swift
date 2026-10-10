// Run with an asset-cache directory argument. First run downloads public UI
// assets; the second phase uses a new WKWebView, new cache object, disabled
// native networking and the exact production ChatKit.html/asset server/bridge.
import AppKit
import WebKit

private final class ChatStub: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var offline = false
        var count = 0
        var thread = Data()
        func setOffline() { lock.lock(); defer { lock.unlock() }; offline = true }
        func completeTurn() {
            lock.lock(); defer { lock.unlock() }
            thread = Data(String(decoding: thread, as: UTF8.self)
                .replacingOccurrences(of: "OFFLINE_CHATKIT_OK", with: "OFFLINE_CHATKIT_OK_COMPLETED").utf8)
        }
        func response(_ request: URLRequest) throws -> Data {
            lock.lock(); defer { lock.unlock() }
            count += 1
            if offline { throw URLError(.notConnectedToInternet) }
            guard let body = request.httpBody,
                  let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { return thread }
            let value = try JSONSerialization.jsonObject(with: thread) as! [String: Any]
            switch json["type"] as? String {
            case "threads.list": return try JSONSerialization.data(withJSONObject: ["data": [value], "has_more": false])
            case "items.list": return try JSONSerialization.data(withJSONObject: value["items"]!)
            default: return thread
            }
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.state.response(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor private final class Bridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let model: AppModel
    weak var view: WKWebView?
    var result: [String: Any]?
    var errors: [String] = []
    var pageLinkOpened = false
    var tasks: [Task<Void, Never>] = []
    init(model: AppModel) { self.model = model }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let value = message.body as? [String: Any] else { return }
        if message.name == "probe", !message.frameInfo.isMainFrame {
            if (value["text"] as? String)?.contains("OFFLINE_CHATKIT_OK") == true { result = value }
            return
        }
        guard message.frameInfo.isMainFrame else { return }
        switch value["kind"] as? String {
        case "loaded":
            tasks.append(Task {
                _ = try? await view?.callAsyncJavaScript("await window.paperchatConfigure({threadID:'proof-thread',context:{},colorScheme:'light',domainKey:'local-dev',models:[],offline:\(model.isOffline)});", arguments: [:], in: nil, contentWorld: .page)
            })
        case "error": errors.append(value["message"] as? String ?? "unknown")
        case "fetch":
            guard let id = value["id"] as? String, let body = value["body"] as? String else { return }
            tasks.append(Task {
                do {
                    for try await event in await model.chatKitRequest(body: body) {
                        switch event {
                        case .headers(let code, let type): await deliver(["id": id, "kind": "headers", "status": code, "contentType": type])
                        case .chunk(let text): await deliver(["id": id, "kind": "chunk", "text": text])
                        }
                    }
                    await deliver(["id": id, "kind": "done"])
                } catch { errors.append(error.localizedDescription); await deliver(["id": id, "kind": "error", "text": error.localizedDescription]) }
            })
        default: break
        }
    }
    func deliver(_ value: [String: Any]) async {
        _ = try? await view?.callAsyncJavaScript("window.paperchatReceive(event);", arguments: ["event": value], in: nil, contentWorld: .page)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if action.request.url?.host == "paperchat.invalid" {
            pageLinkOpened = action.request.url?.path == "/page/3"
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
}

@main @MainActor struct ChatKitOfflineCheck {
    static func main() async throws {
        _ = NSApplication.shared
        guard CommandLine.arguments.count == 2 else { fatalError("Pass a temporary UI-asset cache directory") }
        let assetsDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
        let workspaceDirectory = FileManager.default.temporaryDirectory.appending(path: "chatkit-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let html = try String(contentsOfFile: "client/PaperChat/ChatKit.html", encoding: .utf8)
        ChatStub.state.thread = try Data(contentsOf: URL(fileURLWithPath: "client/Tests/Fixtures/OfflineChatThread.json"))
        let serverURL = URL(string: "http://chatkit-check.invalid/")!
        let store = OfflineStore(serverURL: serverURL, directory: workspaceDirectory)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatStub.self]
        let api = APIClient(baseURL: serverURL, tokens: AuthTokens(accessToken: "synthetic", refreshToken: "synthetic",
            expiresIn: 3600, sessionId: "synthetic"), session: URLSession(configuration: config))
        let probe = #"""
            if (location.pathname.startsWith('/deployments/chatkit/')) {
              const style=document.createElement('style');
              style.textContent='#chatkit-thread-container { opacity: 1 !important; }';
              document.documentElement.appendChild(style);
              let attempts=0;
              const timer=setInterval(()=>{
                const text=document.body?.innerText||'';
                if(text.includes('OFFLINE_CHATKIT_OK')) {
                  const link=document.querySelector('a[href="https://paperchat.invalid/page/3"]');
                  window.webkit.messageHandlers.probe.postMessage({text,math:document.querySelectorAll('.katex').length,
                    link:link?.href,origin:location.origin,locked:text.includes('Offline. Connect to send messages.')});
                  if(link&&!window.proofClicked){window.proofClicked=true;link.click();}
                }
                if(++attempts>250)clearInterval(timer);
              },100);
            }
            """#
        var firstRequestCount = 0
        for offline in [false, true] {
            let model = AppModel(client: api, offlineStore: store, monitorNetwork: false)
            model.isOffline = offline
            if offline { ChatStub.state.setOffline() }
            let assets = ChatKitAssetCache(directory: assetsDirectory)
            // Public CDN resources are fetched only in the first phase. WebKit
            // itself is prevented from making external requests by production CSP.
            let server = ChatKitAssetServer(html: html, assets: assets)
            await server.setOffline(offline)
            let page = try await server.start()
            let options = WKWebViewConfiguration()
            options.websiteDataStore = .nonPersistent()
            let bridge = Bridge(model: model)
            options.userContentController.add(bridge, name: "paperchat")
            options.userContentController.add(bridge, name: "probe")
            options.userContentController.addUserScript(WKUserScript(source: probe, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 800), configuration: options)
            bridge.view = view
            view.navigationDelegate = bridge
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFrontRegardless()
            view.load(URLRequest(url: page))
            for _ in 0..<250 {
                if let result = bridge.result, (result["math"] as? Int ?? 0) >= 2,
                   bridge.pageLinkOpened, !offline || result["locked"] as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard let result = bridge.result else { fatalError("ChatKit did not render: \(bridge.errors)") }
            precondition((result["math"] as? Int ?? 0) >= 2, "Inline and block math did not render")
            precondition(bridge.pageLinkOpened, "Page citation did not reach native navigation")
            precondition((result["origin"] as? String)?.contains("127.0.0.1:") == true, "Iframe lost origin isolation")
            let parentAccess = try await view.evaluateJavaScript("document.querySelector('openai-chatkit').shadowRoot.querySelector('iframe').contentDocument === null") as? Bool
            precondition(parentAccess == true, "Third-party iframe shares the native wrapper origin")
            if offline {
                precondition(result["locked"] as? Bool == true, "Offline thread is not read-only")
                precondition(ChatStub.state.count == firstRequestCount, "Offline chat attempted API networking")
            } else {
                firstRequestCount = ChatStub.state.count
                model.isOffline = true
                bridge.result = nil
                _ = try await view.callAsyncJavaScript("await window.paperchatConfigure({threadID:'proof-thread',context:{},colorScheme:'light',domainKey:'local-dev',models:[],offline:true});", arguments: [:], in: nil, contentWorld: .page)
                for _ in 0..<100 {
                    if bridge.result?["locked"] as? Bool == true { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                precondition(bridge.result?["locked"] as? Bool == true, "Open conversation did not become read-only on disconnect")
                precondition(ChatStub.state.count == firstRequestCount, "Disconnect refresh attempted API networking")
                model.isOffline = false
                bridge.result = nil
                _ = try await view.callAsyncJavaScript("await window.paperchatConfigure({threadID:'proof-thread',context:{},colorScheme:'light',domainKey:'local-dev',models:[],offline:false});", arguments: [:], in: nil, contentWorld: .page)
                for _ in 0..<100 {
                    if bridge.result?["locked"] as? Bool == false { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                precondition(bridge.result?["locked"] as? Bool == false, "Reconnect did not unlock the same conversation")
                firstRequestCount = ChatStub.state.count
                print("PASS live disconnect/reconnect: same chat panel, locked/unlocked composer, no offline API requests")
            }
            if !offline {
                let completed = ChatThread(id: "proof-thread", paperID: nil, title: "Offline proof",
                    backendType: "codex", backendThreadID: nil, backendStatus: "ready",
                    model: nil, effort: nil, isPrimary: 0, lastUsedAt: "2026-10-10")
                let session = ChatSession()
                session.selectedThread = completed
                ChatStub.state.completeTurn()
                let requestsBeforeCompletion = ChatStub.state.count
                await model.chatKitFinished(in: session)
                precondition(ChatStub.state.count > requestsBeforeCompletion,
                             "Completed turn did not refresh native protocol responses")
                let body = #"{"type":"threads.get_by_id","params":{"thread_id":"proof-thread"},"metadata":{"paperchat":{}}}"#
                let saved: Data? = try await store.load(ChatKitOfflineCache.key(body: body)!)
                precondition(saved == ChatStub.state.thread, "Completed thread was not saved")
                firstRequestCount = ChatStub.state.count
                print("PASS completed-turn protocol cache refresh")
            }
            let image = try await view.takeSnapshot(configuration: nil)
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: workspaceDirectory.deletingLastPathComponent().appending(path: "paperchat-chatkit-\(offline ? "offline" : "online").png"))
            }
            print("PASS \(offline ? "offline cold launch" : "online cache warm-up"): body, inline/block math, native page link, isolated iframe\(offline ? ", locked composer, zero API requests" : "")")
            view.stopLoading()
            bridge.tasks.forEach { $0.cancel() }
            options.userContentController.removeScriptMessageHandler(forName: "paperchat")
            options.userContentController.removeScriptMessageHandler(forName: "probe")
            await server.stop()
            window.close()
        }
    }
}
