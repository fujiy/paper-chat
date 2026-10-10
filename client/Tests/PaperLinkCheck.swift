import Foundation

@main struct PaperLinkCheck {
    static func main() {
        let base = "https://paper-chat.fujiy.dev/open?attachment=ABCD1234"
        let link = PaperLink(attachmentKey: "ABCD1234", page: 12)
        precondition(PaperLink(url: link.url) == link)
        precondition(PaperLink(url: URL(string: "paperchat://open?attachment=ABCD1234&page=12")!) == link)
        precondition(PaperLink(url: URL(string: base)!)?.page == nil)
        for raw in [
            base.replacingOccurrences(of: "ABCD1234", with: "ABCD1234%0A"),
            base + "&page=0", base + "&page=-1", base + "&page=bad", base + "&page=1.0",
            base + "&page=9223372036854775808", base + "&page=1&page=2",
            base + "&attachment=EFGH5678", base.replacingOccurrences(of: "ABCD1234", with: "bad"),
            base.replacingOccurrences(of: "https:", with: "http:"),
            base.replacingOccurrences(of: "fujiy.dev", with: "fujiy.dev.evil.test"),
            base.replacingOccurrences(of: "/open?", with: "/api/open?"),
            "paperchat://other?attachment=ABCD1234", "paperchat://open/path?attachment=ABCD1234",
            "https://user@paper-chat.fujiy.dev/open?attachment=ABCD1234"
        ] {
            precondition(PaperLink(url: URL(string: raw)!) == nil, raw)
        }
        print("Paper link parsing passed")
    }
}
