import SwiftUI
import WebKit

struct ChatKitConversation: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var session: ChatSession
    @State private var error: String?
    @AppStorage("chatKitDomainKey") private var domainKey = "local-dev"

    private var configuration: String {
        let selectedModel = model.models.first { $0.model == session.selectedThread?.model }
            ?? model.selectedModel
        let selectedEffort = session.selectedThread?.effort ?? model.selectedEffortID
        var context: [String: Any] = ["current_page_index": session.pageIndex]
        if !session.isManagement { context["paper_id"] = session.id }
        context["selected_text"] = session.selectedText
        context["model"] = selectedModel?.model
        context["effort"] = selectedEffort
        let value: [String: Any] = [
            "threadID": (session.selectedThread?.id ?? (session as? PaperSession)?.paper.readingState?.activeThreadID) as Any? ?? NSNull(),
            "offline": model.isOffline,
            "context": context,
            "colorScheme": colorScheme == .dark ? "dark" : "light",
            "domainKey": domainKey,
            "draft": session.draft,
            "models": model.models.flatMap { option -> [[String: Any]] in
                let efforts = option.supportedReasoningEfforts.map(\.reasoningEffort)
                return (efforts.isEmpty ? [option.defaultReasoningEffort] : efforts).map { effort in
                    let pair = try! JSONSerialization.data(withJSONObject: [option.model, effort])
                    return [
                        "id": "paperchat:" + String(decoding: pair, as: UTF8.self),
                        "label": "\(option.displayName) · \(effort)",
                        "description": option.description,
                        "default": option.id == selectedModel?.id && effort == selectedEffort,
                    ]
                }
            },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let selected = session.selectedText, !selected.isEmpty {
                Text("“\(selected)”").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 7)
            }
            if model.isOffline {
                Text("Offline · Saved chat history only. Sending is unavailable.")
                    .font(.caption).foregroundStyle(.secondary).padding(10)
            }
            if let error, model.isOffline {
                ContentUnavailableView("Chat unavailable offline", systemImage: "wifi.slash", description: Text(error))
            } else {
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(10) }
                ChatKitWebView(
                    configuration: configuration, model: model, session: session,
                    onError: { message in DispatchQueue.main.async { error = message } }
                )
            }
        }
        .onChange(of: model.isOffline) { _, offline in if !offline { error = nil } }
        .onChange(of: session.selectedThread?.id) { _, _ in error = nil }
    }
}

@MainActor
private final class ChatKitCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    var configuration: String
    let model: AppModel
    let session: ChatSession
    var onError: (String) -> Void
    weak var webView: WKWebView?
    var loaded = false
    var tasks: [String: Task<Void, Never>] = [:]
    var assetServer: ChatKitAssetServer?
    var loadTask: Task<Void, Never>?

    init(configuration: String, model: AppModel, session: ChatSession, onError: @escaping (String) -> Void) {
        self.configuration = configuration
        self.model = model
        self.session = session
        self.onError = onError
    }

    func makeView() -> WKWebView {
        let options = WKWebViewConfiguration()
        // Reuse WebKit's HTTP cache when the inspector recreates this view.
        options.websiteDataStore = .default()
        options.userContentController.add(self, name: "paperchat")
        // ChatKit's entry transition can leave computed opacity at zero in WKWebView
        // after its transition attributes are removed (verified on macOS 26.1).
        // Expanded workflow contents exhibit the same WebKit transition issue.
        // Scope the workaround to the ChatKit frame, thread and expanded workflows.
        options.userContentController.addUserScript(WKUserScript(source: """
            if (location.pathname.startsWith('/deployments/chatkit/')) {
                const style = document.createElement('style');
                style.textContent = '#chatkit-thread-container { opacity: 1 !important; } [data-workflow-expanded=true] * { opacity: 1 !important; }';
                document.documentElement.appendChild(style);
            }
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let view = WKWebView(frame: .zero, configuration: options)
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        if let url = Bundle.main.url(forResource: "ChatKit", withExtension: "html"),
           let html = try? String(contentsOf: url, encoding: .utf8) {
            let server = ChatKitAssetServer(html: html, onFailure: { [weak self] message in
                Task { @MainActor in self?.onError(message) }
            })
            assetServer = server
            loadTask = Task { [weak self, weak view] in
                guard let self else { return }
                do {
                    await server.setOffline(model.isOffline)
                    let url = try await server.start()
                    guard !Task.isCancelled else { return }
                    view?.load(URLRequest(url: url))
                } catch { if !Task.isCancelled { onError(error.localizedDescription) } }
            }
        } else { onError("The bundled ChatKit page is missing.") }
        return view
    }

    func update(_ configuration: String) {
        guard self.configuration != configuration else { return }
        self.configuration = configuration
        Task { await assetServer?.setOffline(model.isOffline) }
        configure()
    }

    func configure() {
        guard loaded, let webView else { return }
        let current = configuration
        Task { [weak self] in
            do {
                _ = try await webView.callAsyncJavaScript(
                    "await window.paperchatConfigure(JSON.parse(configuration));",
                    arguments: ["configuration": current], in: nil, contentWorld: .page
                )
            } catch { self?.onError(error.localizedDescription) }
        }
    }

    func deliver(_ value: [String: Any]) async {
        guard let webView else { return }
        _ = try? await webView.callAsyncJavaScript(
            "window.paperchatReceive(event);", arguments: ["event": value],
            in: nil, contentWorld: .page
        )
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // The remote ChatKit iframe cannot call the native authenticated bridge directly.
        guard message.frameInfo.isMainFrame,
              let data = message.body as? [String: Any], let kind = data["kind"] as? String else { return }
        switch kind {
        case "loaded": loaded = true; configure()
        case "error": onError(data["message"] as? String ?? "ChatKit could not load.")
        case "thread":
            if let id = data["threadID"] as? String {
                Task { await model.chatKitSelectedThread(id, in: session) }
            } else {
                session.selectedThread = nil
                session.messages = []
                session.streamingMessage = nil
            }
        case "sending":
            let sending = data["value"] as? Bool ?? false
            session.isSending = sending
            if !sending { Task { await model.chatKitFinished(in: session) } }
        case "cancel":
            if let id = data["id"] as? String { tasks[id]?.cancel(); tasks[id] = nil }
        case "fetch":
            guard let id = data["id"] as? String, let body = data["body"] as? String else { return }
            tasks[id] = Task { [weak self] in
                guard let self else { return }
                defer { tasks[id] = nil }
                do {
                    for try await event in await model.chatKitRequest(body: body) {
                        try Task.checkCancellation()
                        switch event {
                        case let .headers(status, contentType):
                            await deliver(["id": id, "kind": "headers", "status": status, "contentType": contentType])
                        case let .chunk(text):
                            await deliver(["id": id, "kind": "chunk", "text": text])
                        }
                    }
                    await deliver(["id": id, "kind": "done"])
                } catch {
                    await deliver(["id": id, "kind": "error", "text": error.localizedDescription])
                }
            }
        default: break
        }
    }

    func stop() {
        loadTask?.cancel()
        if let assetServer { Task { await assetServer.stop() } }
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        session.isSending = false
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "paperchat")
        webView?.stopLoading()
    }

    private func openLink(_ url: URL) {
        if PaperLink.recognizes(url), url.host != "page" {
            // Navigation callbacks may run inside a WebKit layout/update pass.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                Task { await self.model.openURL(url) }
            }
        } else if url.scheme == "https", url.host == "paperchat.invalid",
           url.path.hasPrefix("/page/"), let page = Int(url.lastPathComponent), page > 0,
           let paper = session as? PaperSession {
            DispatchQueue.main.async { [weak self] in
                self?.model.pageChanged(page - 1, in: paper)
            }
        } else if ["https", "http"].contains(url.scheme ?? "") {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           navigationAction.navigationType == .linkActivated || url.host == "paperchat.invalid" {
            openLink(url)
            decisionHandler(.cancel)
        } else if navigationAction.targetFrame?.isMainFrame == true,
                  loaded, navigationAction.request.url?.scheme != "about" {
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { openLink(url) }
        return nil
    }
}

#if os(macOS)
private struct ChatKitWebView: NSViewRepresentable {
    let configuration: String
    let model: AppModel
    let session: ChatSession
    let onError: (String) -> Void

    func makeCoordinator() -> ChatKitCoordinator {
        ChatKitCoordinator(configuration: configuration, model: model, session: session, onError: onError)
    }
    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeView() }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.update(configuration) }
    static func dismantleNSView(_ view: WKWebView, coordinator: ChatKitCoordinator) { coordinator.stop() }
}
#else
private struct ChatKitWebView: UIViewRepresentable {
    let configuration: String
    let model: AppModel
    let session: ChatSession
    let onError: (String) -> Void

    func makeCoordinator() -> ChatKitCoordinator {
        ChatKitCoordinator(configuration: configuration, model: model, session: session, onError: onError)
    }
    func makeUIView(context: Context) -> WKWebView { context.coordinator.makeView() }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.update(configuration) }
    static func dismantleUIView(_ view: WKWebView, coordinator: ChatKitCoordinator) { coordinator.stop() }
}
#endif
