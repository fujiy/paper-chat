import Foundation

/// A portable reference to a PDF in the server's configured Zotero library.
struct PaperLink: Equatable, Sendable {
    static let host = "paper-chat.fujiy.dev"
    let attachmentKey: String
    let page: Int?

    static func recognizes(_ url: URL) -> Bool {
        url.scheme == "paperchat" ||
            (url.scheme == "https" && url.host == host && url.path == "/open")
    }

    init?(url: URL) {
        guard Self.recognizes(url), url.user == nil, url.password == nil, url.port == nil,
              (url.scheme == "https" || (url.host == "open" && url.path.isEmpty)),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        let attachments = items.filter { $0.name == "attachment" }
        let pages = items.filter { $0.name == "page" }
        guard attachments.count == 1, let key = attachments.first?.value, key.utf8.count == 8,
              key.range(of: "^[A-Z0-9]{8}$", options: .regularExpression) != nil,
              pages.count <= 1 else { return nil }
        if let item = pages.first {
            guard let value = item.value, value.range(of: "^[0-9]+$", options: .regularExpression) != nil,
                  let number = Int(value), number > 0 else { return nil }
            page = number
        } else { page = nil }
        attachmentKey = key
    }

    init(attachmentKey: String, page: Int? = nil) {
        self.attachmentKey = attachmentKey
        self.page = page
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = "/open"
        components.queryItems = [URLQueryItem(name: "attachment", value: attachmentKey)]
        if let page { components.queryItems?.append(URLQueryItem(name: "page", value: String(page))) }
        return components.url!
    }
}
