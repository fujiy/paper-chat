import SwiftUI
#if os(macOS)
import AppKit
#endif

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.isAuthenticated {
                LibraryWorkspace()
            } else {
                SignInView()
            }
        }
        .dynamicTypeSize(.xSmall ... .xxxLarge)
        .overlay {
            if model.isBusy {
                ProgressView()
                    .controlSize(.large)
                    .padding(22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
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
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            VStack(spacing: 5) {
                Text("PaperChat").font(.largeTitle.bold())
                Text("Your papers and conversations, continued everywhere.")
                    .foregroundStyle(.secondary)
            }
            Form {
                TextField("Server URL", text: $model.serverURLString)
                    .textContentType(.URL)
                SecureField("One-time bootstrap token", text: $bootstrapToken)
                Button("Connect") {
                    Task { await model.signIn(bootstrapToken: bootstrapToken) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(bootstrapToken.isEmpty)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 500)
        }
        .padding()
    }
}

struct LibraryWorkspace: View {
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 235, max: 310)
        } detail: {
            WorkspaceDetail()
        }
    }
}

struct LibrarySidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            SidebarButton(
                title: "Start",
                systemImage: "house",
                selected: model.route == .start
            ) { model.navigate(to: .start, fromSidebar: true) }
            SidebarButton(
                title: "Search",
                systemImage: "magnifyingglass",
                selected: model.route == .search
            ) { model.navigate(to: .search, fromSidebar: true) }
            SidebarButton(
                title: "All Papers",
                systemImage: "books.vertical",
                selected: model.route == .allPapers
            ) { model.navigate(to: .allPapers, fromSidebar: true) }
            SidebarButton(
                title: "Recent",
                systemImage: "clock",
                selected: model.route == .recent
            ) { model.navigate(to: .recent, fromSidebar: true) }
            SidebarButton(
                title: "Starred",
                systemImage: "star",
                selected: model.route == .starred
            ) { model.navigate(to: .starred, fromSidebar: true) }
            SidebarButton(
                title: "Chats",
                systemImage: "bubble.left.and.bubble.right",
                selected: model.route == .chats
            ) { model.navigate(to: .chats, fromSidebar: true) }
        }
        .listStyle(.sidebar)
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Refresh Library", systemImage: "arrow.clockwise") {
                        Task { await model.refreshLibrary() }
                    }
                    Divider()
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                        Task { await model.signOut() }
                    }
                } label: {
                    Label("Library actions", systemImage: "ellipsis.circle")
                }
            }
        }
    }
}

struct SidebarButton: View {
    let title: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.14) : Color.clear)
    }
}

struct WorkspaceDetail: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            switch model.route {
            case .start:
                StartPage()
            case .search:
                LibrarySearchPage()
            case .allPapers:
                AllPapersPage()
            case .recent:
                PaperListPage(
                    title: "Recent",
                    emptyTitle: "No Recent Papers",
                    emptyIcon: "clock",
                    papers: model.recentPapers
                )
            case .starred:
                PaperListPage(
                    title: "Starred",
                    emptyTitle: "No Starred Papers",
                    emptyIcon: "star",
                    papers: model.starredPapers
                )
            case .chats:
                ChatsPage()
            case .paper:
                Color.platformBackground
            }

            ForEach(model.openSessions) { session in
                ReaderWorkspace(session: session)
                    .opacity(model.route == .paper(session.id) ? 1 : 0)
                    .allowsHitTesting(model.route == .paper(session.id))
                    .accessibilityHidden(model.route != .paper(session.id))
                    .zIndex(model.route == .paper(session.id) ? 2 : 0)
            }
        }
        .toolbar {
            if !model.navigationHistory.isEmpty {
                ToolbarItem(placement: .navigation) {
                    Button("Back", systemImage: "chevron.left") {
                        model.goBack()
                    }
                    .labelStyle(.iconOnly)
                }
            }
            ToolbarItem(placement: .principal) {
                WorkspaceHeader()
            }
            if let session = model.activeSession {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(
                        session.paper.isStarred ? "Unstar" : "Star",
                        systemImage: session.paper.isStarred ? "star.fill" : "star"
                    ) {
                        Task { await model.toggleStar(in: session) }
                    }
                    Button("Find in PDF", systemImage: "magnifyingglass") {
                        withAnimation(.snappy) {
                            session.isPDFSearchPresented.toggle()
                        }
                    }
                    if let itemKey = session.paper.identifiers?
                        .first(where: { $0.kind == "zotero_item" })?.value,
                       let url = URL(string: "zotero://select/library/items/\(itemKey)") {
                        Button("Open in Zotero", systemImage: "arrow.up.forward.app") {
                            openURL(url)
                        }
                    }
                    Button(
                        session.isChatPresented ? "Hide Chat" : "Show Chat",
                        systemImage: "sidebar.right"
                    ) {
                        withAnimation(.snappy(duration: 0.22)) {
                            if session.isChatPresented {
                                session.isChatPresented = false
                            } else {
                                model.presentChat(in: session)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct WorkspaceHeader: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let session = model.activeSession {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text(session.paper.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(paperMetadata(session.paper.authors, session.paper.year))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                HStack(spacing: 7) {
                    Text(session.paper.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(compactPaperMetadata(session.paper.authors, session.paper.year))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: 700, alignment: .leading)
        } else {
            Text(pageTitle)
                .font(.headline)
                .frame(maxWidth: 700, alignment: .leading)
        }
    }

    private var pageTitle: String {
        switch model.route {
        case .start: "Start"
        case .search: "Search"
        case .allPapers: "All Papers"
        case .recent: "Recent"
        case .starred: "Starred"
        case .chats: "Chats"
        case .paper: ""
        }
    }
}

struct StartPage: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)
                    Text("PaperChat")
                        .font(.largeTitle.bold())
                    Text("Continue reading, or search your Zotero library.")
                        .foregroundStyle(.secondary)
                }

                SearchField(
                    text: $model.searchQuery,
                    prompt: "Search title, author, DOI, citekey, or full text"
                )
                .focused($searchFocused)
                .frame(maxWidth: 620)
                .onChange(of: searchFocused) {
                    if searchFocused {
                        model.navigate(to: .search)
                    }
                }

                if !model.recentPapers.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Continue Reading").font(.title2.bold())
                            Spacer()
                            Button("See All") { model.navigate(to: .recent) }
                        }
                        ForEach(model.recentPapers.prefix(4)) { paper in
                            PaperCard(paper: paper) {
                                Task { await model.open(paper: paper) }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 36)
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tertiary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 42)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.32), lineWidth: 0.5)
        }
    }
}

struct LibrarySearchPage: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFocused: Bool

    private var groups: [SearchPaperGroup] {
        SearchPaperGroup.group(model.searchResults)
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(
                text: $model.searchQuery,
                prompt: "Search title, author, DOI, citekey, or full text"
            )
            .focused($searchFocused)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            Group {
                if model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "Search Your Library",
                        systemImage: "magnifyingglass",
                        description: Text("Results include matching passages from your PDFs.")
                    )
                } else if model.isSearching && groups.isEmpty {
                    ProgressView("Searching…")
                } else if groups.isEmpty {
                    ContentUnavailableView.search(text: model.searchQuery)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(groups) { group in
                                SearchPaperSection(group: group, query: model.searchQuery)
                            }
                        }
                        .frame(maxWidth: 860)
                        .padding(24)
                    }
                }
            }
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.searchFocusToken) { searchFocused = true }
        .task(id: model.searchQuery) {
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await model.search(model.searchQuery)
            } catch {
                return
            }
        }
    }
}

struct SearchPaperSection: View {
    @EnvironmentObject private var model: AppModel
    let group: SearchPaperGroup
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(paperMetadata(group.creators, group.year))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(14)

            Divider()

            ForEach(group.results) { result in
                Button {
                    Task { await model.open(searchResult: result) }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Text("p. \(result.matchedPage ?? result.pageStart ?? 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .leading)
                        HighlightedSnippet(
                            text: result.snippet ?? result.title,
                            query: query
                        )
                        .font(.callout)
                        .lineLimit(4)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.right")
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 68)
            }
        }
        .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct HighlightedSnippet: View {
    let text: String
    let query: String

    var body: some View {
        Text(attributedText)
            .multilineTextAlignment(.leading)
    }

    private var attributedText: AttributedString {
        var result = AttributedString(text)
        let terms = query.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { $0.count > 1 }
        for term in terms {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(
                    of: term,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchStart..<text.endIndex
                  ) {
                if let attributedRange = Range(range, in: result) {
                    result[attributedRange].backgroundColor = .yellow.opacity(0.45)
                    result[attributedRange].font = .body.bold()
                }
                searchStart = range.upperBound
            }
        }
        return result
    }
}

struct SearchPaperGroup: Identifiable {
    let id: String
    let title: String
    let creators: [Creator]
    let year: String?
    let results: [LibrarySearchResult]

    static func group(_ results: [LibrarySearchResult]) -> [SearchPaperGroup] {
        let grouped = Dictionary(grouping: results) {
            "\($0.displayTitle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))|\($0.year ?? "")|\($0.usableAttachmentKey ?? "")"
        }
        return grouped.map { key, values in
            let first = values[0]
            return SearchPaperGroup(
                id: key,
                title: first.displayTitle,
                creators: first.creators ?? [],
                year: first.year,
                results: values.sorted {
                    ($0.matchedPage ?? $0.pageStart ?? 0) < ($1.matchedPage ?? $1.pageStart ?? 0)
                }
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

struct AllPapersPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.libraryPapers.isEmpty {
            ContentUnavailableView(
                "No Papers",
                systemImage: "books.vertical",
                description: Text("Refresh the library after Zotero synchronization finishes.")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.libraryPapers) { paper in
                        LibraryPaperCard(paper: paper) {
                            Task { await model.open(libraryPaper: paper) }
                        }
                    }
                }
                .frame(maxWidth: 860)
                .padding(24)
            }
        }
    }
}

struct PaperListPage: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let emptyTitle: String
    let emptyIcon: String
    let papers: [Paper]

    var body: some View {
        if papers.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: emptyIcon)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(papers) { paper in
                        PaperCard(paper: paper) {
                            Task { await model.open(paper: paper) }
                        }
                    }
                }
                .frame(maxWidth: 860)
                .padding(24)
            }
        }
    }
}

struct PaperCard: View {
    let paper: Paper
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "doc.richtext")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(paper.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(paperMetadata(paper.authors, paper.year))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if paper.isStarred {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct LibraryPaperCard: View {
    let paper: LibraryPaper
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "doc.richtext")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(paper.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(paperMetadata(paper.creators, paper.year))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ChatsPage: View {
    @EnvironmentObject private var model: AppModel

    private var groups: [(String, [ChatOverview])] {
        Dictionary(grouping: model.chatOverviews, by: \.paperID)
            .values
            .map { ($0[0].paperTitle, $0) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        if groups.isEmpty {
            ContentUnavailableView(
                "No Chats Yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Chats you start from a paper will appear here.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.0) { paperTitle, chats in
                        VStack(alignment: .leading, spacing: 0) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(paperTitle).font(.headline).lineLimit(2)
                                Text(paperMetadata(chats[0].authors, chats[0].year))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(14)
                            Divider()
                            ForEach(chats) { chat in
                                Button {
                                    Task { await model.open(chat: chat) }
                                } label: {
                                    HStack {
                                        Image(systemName: "bubble.left")
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(chat.title).lineLimit(1)
                                            Text(chat.lastUsedAt)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption.bold())
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .frame(maxWidth: 860)
                .padding(24)
            }
        }
    }
}

struct ReaderWorkspace: View {
    @ObservedObject var session: PaperSession

    var body: some View {
        GeometryReader { geometry in
            ReaderLayout(session: session, availableWidth: geometry.size.width)
        }
    }
}

struct ReaderLayout: View {
    @ObservedObject var session: PaperSession
    let availableWidth: CGFloat

    private var usesOverlayChat: Bool { availableWidth < 820 }

    var body: some View {
        ZStack(alignment: .trailing) {
            if usesOverlayChat {
                PDFPane(session: session)
                if session.isChatPresented {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.snappy) { session.isChatPresented = false }
                        }
                    ChatPane(session: session)
                        .frame(width: min(max(availableWidth * 0.88, 300), 430))
                        .background(.regularMaterial)
                        .shadow(color: .black.opacity(0.2), radius: 18, x: -5)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            } else {
                HStack(spacing: 0) {
                    PDFPane(session: session)
                        .frame(maxWidth: .infinity)
                    if session.isChatPresented {
                        ChatResizeHandle(session: session, totalWidth: availableWidth)
                            .zIndex(10)
                        ChatPane(session: session)
                            .frame(width: min(session.chatWidth, availableWidth * 0.48))
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
        }
        .clipped()
    }
}

struct ChatResizeHandle: View {
    @ObservedObject var session: PaperSession
    let totalWidth: CGFloat
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(.secondary.opacity(0.38))
                .frame(width: 3, height: 42)
        }
        .frame(width: 18)
        .contentShape(Rectangle())
        .onHover { hovering in
            #if os(macOS)
            if hovering { NSCursor.resizeLeftRight.push() }
            else { NSCursor.pop() }
            #endif
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartWidth == nil { dragStartWidth = session.chatWidth }
                    let proposed = (dragStartWidth ?? session.chatWidth) - value.translation.width
                    session.chatWidth = min(max(proposed, 300), totalWidth * 0.55)
                }
                .onEnded { _ in dragStartWidth = nil }
        )
    }
}

struct PDFPane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: PaperSession

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let url = session.pdfURL {
                    PDFKitView(
                        url: url,
                        pageIndex: Binding(
                            get: { session.pageIndex },
                            set: { model.pageChanged($0, in: session) }
                        ),
                        zoomScale: Binding(
                            get: { session.zoomScale },
                            set: {
                                model.pdfViewStateChanged(
                                    in: session,
                                    pageIndex: session.pageIndex,
                                    zoomScale: $0,
                                    scrollOffset: session.scrollOffset
                                )
                            }
                        ),
                        scrollOffset: Binding(
                            get: { session.scrollOffset },
                            set: {
                                model.pdfViewStateChanged(
                                    in: session,
                                    pageIndex: session.pageIndex,
                                    zoomScale: session.zoomScale,
                                    scrollOffset: $0
                                )
                            }
                        ),
                        selectedText: $session.selectedText,
                        highlightTarget: session.pdfHighlightTarget
                    )
                } else {
                    ProgressView("Downloading PDF…")
                }
            }

            if session.isPDFSearchPresented {
                PDFSearchPanel(session: session)
                    .frame(width: 360)
                    .padding(10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("Page \(session.pageIndex + 1)")
                if session.zoomScale > 0 {
                    Text("· \(Int(session.zoomScale * 100))%")
                }
                Spacer()
                if let selection = session.selectedText, !selection.isEmpty {
                    Label("Selection ready for chat", systemImage: "text.quote")
                        .foregroundStyle(.tint)
                }
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.bar)
        }
    }
}

struct PDFSearchPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: PaperSession
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in PDF", text: $session.pdfSearchQuery)
                    .textFieldStyle(.plain)
                    .focused($focused)
                if !session.pdfSearchQuery.isEmpty {
                    Text("\(session.pdfSearchResults.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button("Close", systemImage: "xmark") {
                    session.isPDFSearchPresented = false
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
            }
            .padding(11)

            if !session.pdfSearchResults.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.pdfSearchResults.prefix(100)) { result in
                            Button {
                                model.selectPDFSearchResult(result, in: session)
                            } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    Text("p. \(result.pageIndex + 1)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    HighlightedSnippet(
                                        text: result.snippet,
                                        query: session.pdfSearchQuery
                                    )
                                    .font(.caption)
                                    .lineLimit(3)
                                    Spacer(minLength: 0)
                                }
                                .padding(9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 330)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.32), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        .onAppear { focused = true }
        .task(id: session.pdfSearchQuery) {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            model.searchPDF(session.pdfSearchQuery, in: session)
        }
    }
}

struct ChatPane: View {
    @ObservedObject var session: PaperSession

    var body: some View {
        Group {
            switch session.chatRoute {
            case .list:
                ChatListView(session: session)
            case .conversation, .compose:
                ConversationView(session: session)
            }
        }
        .background(Color.platformBackground)
    }
}

struct ChatListView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: PaperSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats").font(.headline)
                Spacer()
                Button("New Chat", systemImage: "square.and.pencil") {
                    model.beginNewChat(in: session)
                }
                .labelStyle(.iconOnly)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            Divider()

            if session.threads.isEmpty {
                Spacer()
                Text("Ask your first question about this paper.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
                Divider()
                ChatComposer(session: session)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(session.threads) { thread in
                            Button {
                                Task { await model.switchThread(thread, in: session) }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "bubble.left")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(thread.title)
                                            .font(.callout.weight(.medium))
                                            .lineLimit(1)
                                        Text(thread.lastUsedAt)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.bold())
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                }
            }
        }
    }
}

struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: PaperSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("All Chats", systemImage: "chevron.left") {
                    model.showChatList(session)
                }
                .labelStyle(.iconOnly)
                Text(session.selectedThread?.title ?? "New Chat")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("New Chat", systemImage: "square.and.pencil") {
                    model.beginNewChat(in: session)
                }
                .labelStyle(.iconOnly)
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 11) {
                        if session.messages.isEmpty {
                            Text("Ask a question about this paper.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, 28)
                        }
                        ForEach(session.messages) { message in
                            MessageBubble(message: message, session: session)
                                .id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: session.messages.count) {
                    if let last = session.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()
            ChatComposer(session: session)
        }
    }
}

struct ChatComposer: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: PaperSession
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let selected = session.selectedText, !selected.isEmpty {
                Text("“\(selected)”")
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 5) {
                ZStack(alignment: .topLeading) {
                    if session.draft.isEmpty {
                        Text("Ask about page \(session.pageIndex + 1)…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                    }
                    TextEditor(text: $session.draft)
                        .focused($editorFocused)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 62, maxHeight: 150)
                }

                HStack(spacing: 8) {
                    ModelMenu()
                    EffortMenu()
                    Spacer()
                    Button("Send", systemImage: "arrow.up.circle.fill") {
                        Task { await model.send(in: session) }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .buttonStyle(.plain)
                    .disabled(session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.48), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        editorFocused
                            ? Color.accentColor.opacity(0.65)
                            : Color.secondary.opacity(0.3)
                    )
            }
        }
        .padding(10)
        .onAppear {
            if session.selectedThread == nil {
                editorFocused = true
            }
        }
    }
}

struct ModelMenu: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu {
            if model.models.isEmpty {
                Text("Server default")
            } else {
                ForEach(model.models) { option in
                    Button {
                        model.selectModel(option.id)
                    } label: {
                        if model.selectedModelID == option.id {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.selectedModel?.displayName ?? "Default model")
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

struct EffortMenu: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let selectedModel = model.selectedModel,
           !selectedModel.supportedReasoningEfforts.isEmpty {
            Menu {
                ForEach(selectedModel.supportedReasoningEfforts) { effort in
                    Button {
                        model.selectedEffortID = effort.reasoningEffort
                    } label: {
                        if model.selectedEffortID == effort.reasoningEffort {
                            Label(effort.reasoningEffort.capitalized, systemImage: "checkmark")
                        } else {
                            Text(effort.reasoningEffort.capitalized)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text((model.selectedEffortID ?? selectedModel.defaultReasoningEffort).capitalized)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    @ObservedObject var session: PaperSession
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 7) {
                Text(message.content.isEmpty ? "…" : message.content)
                    .textSelection(.enabled)
                if message.role == "assistant", !citedPages.isEmpty {
                    HStack {
                        ForEach(citedPages, id: \.self) { page in
                            Button("p. \(page)") {
                                model.pageChanged(page - 1, in: session)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(10)
            .background(
                message.role == "user"
                    ? Color.accentColor.opacity(0.18)
                    : Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 12)
            )
            if message.role != "user" { Spacer(minLength: 32) }
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

private func paperMetadata(_ authors: [Creator], _ year: String?) -> String {
    [authors.map(\.displayName).filter { !$0.isEmpty }.joined(separator: ", "), year]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
}

private func compactPaperMetadata(_ authors: [Creator], _ year: String?) -> String {
    let names = authors.map(\.displayName).filter { !$0.isEmpty }
    let author = names.isEmpty ? nil : names.count == 1 ? names[0] : "\(names[0]) et al."
    return [author, year]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

extension Color {
    static var platformBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}
