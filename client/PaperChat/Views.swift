import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.isAuthenticated { LibraryView() }
            else { SignInView() }
        }
        .overlay {
            if model.isBusy { ProgressView().controlSize(.large) }
        }
        .alert("PaperChat", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct SignInView: View {
    @EnvironmentObject private var model: AppModel
    @State private var bootstrapToken = ""

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("PaperChat").font(.largeTitle.bold())
                Text("Your papers and conversations, continued everywhere.")
                    .foregroundStyle(.secondary)
            }
            Form {
                TextField("Server URL", text: $model.serverURLString)
                    .textContentType(.URL)
                SecureField("One-time bootstrap token", text: $bootstrapToken)
                Button("Connect") { Task { await model.signIn(bootstrapToken: bootstrapToken) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(bootstrapToken.isEmpty)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 520)
        }
        .padding()
    }
}

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedPaper) {
                Section("Recent") {
                    ForEach(model.recentPapers) { paper in
                        PaperRow(title: paper.title, authors: paper.authors, year: paper.year)
                            .tag(paper)
                            .onTapGesture { Task { await model.choose(paper: paper) } }
                    }
                }
                if !model.searchResults.isEmpty {
                    Section("Zotero Library") {
                        ForEach(model.searchResults) { result in
                            PaperRow(
                                title: result.title,
                                authors: result.creators ?? [],
                                year: result.year
                            )
                            .onTapGesture { Task { await model.open(searchResult: result) } }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .searchable(text: $query, prompt: "Search Zotero")
            .onSubmit(of: .search) { Task { await model.search(query) } }
            .toolbar {
                ToolbarItem {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.loadRecent() }
                    }
                }
                ToolbarItem {
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                        Task { await model.signOut() }
                    }
                }
            }
        } detail: {
            if model.selectedPaper != nil { ReaderWorkspace() }
            else {
                ContentUnavailableView(
                    "Choose a paper",
                    systemImage: "doc.text",
                    description: Text("Open a recent paper or search your Zotero library.")
                )
            }
        }
    }
}

struct PaperRow: View {
    let title: String
    let authors: [Creator]
    let year: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).lineLimit(2)
            Text(
                [authors.prefix(2).map(\.displayName).joined(separator: ", "), year]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

struct ReaderWorkspace: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                TabView {
                    PDFPane().tabItem { Label("Reader", systemImage: "doc.richtext") }
                    ChatPane().tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                }
            } else {
                #if os(macOS)
                HSplitView {
                    PDFPane().frame(minWidth: 420)
                    ChatPane().frame(minWidth: 320, idealWidth: 420, maxWidth: 560)
                }
                #else
                HStack(spacing: 0) {
                    PDFPane().frame(minWidth: 420)
                    Divider()
                    ChatPane().frame(minWidth: 320, idealWidth: 420, maxWidth: 560)
                }
                #endif
            }
        }
        .navigationTitle(model.selectedPaper?.title ?? "Paper")
        .toolbar {
            if let itemKey = model.selectedPaper?.identifiers?
                .first(where: { $0.kind == "zotero_item" })?.value,
               let url = URL(string: "zotero://select/library/items/\(itemKey)") {
                Button("Open in Zotero", systemImage: "arrow.up.forward.app") {
                    openURL(url)
                }
            }
        }
    }
}

struct PDFPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let url = model.pdfURL {
                PDFKitView(
                    url: url,
                    pageIndex: Binding(
                        get: { model.pageIndex },
                        set: { model.pageChanged($0) }
                    ),
                    selectedText: $model.selectedText
                )
            } else {
                ProgressView("Downloading PDF…")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("Page \(model.pageIndex + 1)")
                Spacer()
                if let selection = model.selectedText, !selection.isEmpty {
                    Label("Selection ready for chat", systemImage: "text.quote")
                        .foregroundStyle(.tint)
                }
            }
            .font(.caption)
            .padding(8)
            .background(.bar)
        }
    }
}

struct ChatPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Thread", selection: $model.selectedThread) {
                    ForEach(model.threads) { thread in Text(thread.title).tag(Optional(thread)) }
                }
                .pickerStyle(.menu)
                .onChange(of: model.selectedThread) { _, thread in
                    Task { await model.switchThread(to: thread) }
                }
                Spacer()
                Button("New Thread", systemImage: "plus") {
                    Task { await model.createThread() }
                }
                .labelStyle(.iconOnly)
            }
            .padding()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.messages.count) {
                    if let last = model.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let selected = model.selectedText, !selected.isEmpty {
                    Text("“\(selected)”")
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .bottom) {
                    TextField("Ask about page \(model.pageIndex + 1)…", text: $model.draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...6)
                        .onSubmit { Task { await model.send() } }
                    Button("Send", systemImage: "arrow.up.circle.fill") {
                        Task { await model.send() }
                    }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
        }
        .background(Color.platformBackground)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 8) {
                Text(message.content.isEmpty ? "…" : message.content)
                    .textSelection(.enabled)
                if message.role == "assistant", !citedPages.isEmpty {
                    HStack {
                        ForEach(citedPages, id: \.self) { page in
                            Button("p. \(page)") { model.pageChanged(page - 1) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(12)
            .background(
                message.role == "user" ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 14)
            )
            if message.role != "user" { Spacer(minLength: 40) }
        }
    }

    private var citedPages: [Int] {
        let pattern = #"\[p\.\s*(\d+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(message.content.startIndex..., in: message.content)
        return Array(Set(regex.matches(in: message.content, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: message.content) else { return nil }
            return Int(message.content[range])
        })).sorted()
    }
}

private extension Color {
    static var platformBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}
