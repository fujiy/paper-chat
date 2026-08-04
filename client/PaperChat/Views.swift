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
    @EnvironmentObject private var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var visibilityBeforeImmersive: NavigationSplitViewVisibility = .automatic
    @State private var isPDFImmersive = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 170, ideal: 225, max: 300)
        } detail: {
            WorkspaceDetail(isPDFImmersive: $isPDFImmersive)
        }
        .navigationSplitViewStyle(.prominentDetail)
        .onChange(of: isPDFImmersive) { _, isImmersive in
            if isImmersive {
                visibilityBeforeImmersive = columnVisibility
                columnVisibility = .detailOnly
            } else {
                columnVisibility = visibilityBeforeImmersive
            }
        }
        .onChange(of: model.route) { _, route in
            guard isPDFImmersive else { return }
            if case .paper = route { return }
            withAnimation(.smooth(duration: 0.28)) {
                isPDFImmersive = false
            }
        }
    }
}

struct LibrarySidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
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

                if !model.recentPapers.isEmpty {
                    Section("Recent") {
                        ForEach(model.recentPapers.prefix(8)) { paper in
                            Button {
                                Task { await model.open(paper: paper, fromSidebar: true) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(paper.title)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(2)
                                    Text(compactPaperMetadata(paper.authors, paper.year))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 10))
                            .listRowBackground(
                                model.route == .paper(paper.id)
                                    ? Color.accentColor.opacity(0.14)
                                    : Color.clear
                            )
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack {
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
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .navigationTitle("")
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
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, minHeight: 28)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 10))
        .listRowBackground(selected ? Color.accentColor.opacity(0.14) : Color.clear)
    }
}

struct WorkspaceDetail: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    @Binding var isPDFImmersive: Bool

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
                ReaderWorkspace(session: session, isImmersive: $isPDFImmersive)
                    .opacity(model.route == .paper(session.id) ? 1 : 0)
                    .allowsHitTesting(model.route == .paper(session.id))
                    .accessibilityHidden(model.route != .paper(session.id))
                    .zIndex(model.route == .paper(session.id) ? 2 : 0)
            }
        }
        .navigationTitle(navigationTitle)
        .paperNavigationSubtitle(navigationSubtitle)
        .paperNavigationTitleStyle()
        .paperChromeHidden(isPDFImmersive)
        .background {
            WorkspaceShortcuts()
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
                    Menu("Add Bookmark", systemImage: "bookmark") {
                        if session.selectionSnapshot != nil {
                            Button("Selected Text", systemImage: "text.quote") {
                                model.presentBookmarks(in: session)
                                Task { await model.addSelectionBookmark(in: session) }
                            }
                        }
                        Button("Current Page", systemImage: "doc") {
                            model.presentBookmarks(in: session)
                            Task { await model.addPageBookmark(in: session) }
                        }
                    }
                    if let itemKey = session.paper.identifiers?
                        .first(where: { $0.kind == "zotero_item" })?.value,
                       let url = URL(string: "zotero://select/library/items/\(itemKey)") {
                        Button {
                            openURL(url)
                        }
                        label: {
                            Text("Z")
                        }
                        .accessibilityLabel("Open in Zotero")
                        .help("Open in Zotero")
                    }
                    Button(
                        session.isChatPresented ? "Hide Sidebar" : "Show Sidebar",
                        systemImage: "sidebar.right"
                    ) {
                        withAnimation(.snappy(duration: 0.22)) {
                            if session.isChatPresented {
                                session.isChatPresented = false
                            } else if session.sidebarMode == .bookmarks {
                                model.presentBookmarks(in: session)
                            } else {
                                model.presentChat(in: session)
                            }
                        }
                    }
                }
            }
        }
    }

    private var navigationTitle: String {
        if let session = model.activeSession {
            return session.paper.title
        }
        switch model.route {
        case .start: return "Start"
        case .search: return "Search"
        case .allPapers: return "All Papers"
        case .recent: return "Recent"
        case .starred: return "Starred"
        case .chats: return "Chats"
        case .paper: return ""
        }
    }

    private var navigationSubtitle: String {
        guard let session = model.activeSession else { return "" }
        return compactPaperMetadata(session.paper.authors, session.paper.year)
    }
}

private struct WorkspaceShortcuts: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack {
            Button("Find in PDF") {
                guard let session = model.activeSession else { return }
                session.isPDFSearchPresented = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(model.activeSession == nil)

            Button("Search Library") {
                model.navigate(to: .search)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button("Add Bookmark") {
                guard let session = model.activeSession else { return }
                model.presentBookmarks(in: session)
                if session.selectionSnapshot != nil {
                    Task { await model.addSelectionBookmark(in: session) }
                } else {
                    Task { await model.addPageBookmark(in: session) }
                }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(model.activeSession == nil)
        }
        .frame(width: 1, height: 1)
        .opacity(0.001)
        .clipped()
        .accessibilityHidden(true)
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
                .frame(maxWidth: .infinity)
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
    @State private var expandedPaperIDs: Set<String> = []

    private var groups: [LibrarySearchPaper] { model.searchPapers }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(
                text: $model.searchQuery,
                prompt: "Search title, author, DOI, citekey, or full text"
            )
            .focused($searchFocused)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(.bar)

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
                                SearchPaperSection(
                                    group: group,
                                    query: model.searchQuery,
                                    isExpanded: expandedPaperIDs.contains(group.id)
                                ) {
                                    withAnimation(.snappy) {
                                        if expandedPaperIDs.contains(group.id) {
                                            expandedPaperIDs.remove(group.id)
                                        } else {
                                            expandedPaperIDs.insert(group.id)
                                        }
                                    }
                                }
                            }
                            if model.hasMoreSearchResults {
                                HStack(spacing: 8) {
                                    if model.isLoadingMoreSearchResults {
                                        ProgressView().controlSize(.small)
                                        Text("Loading more results…")
                                    } else {
                                        Image(systemName: "arrow.down.circle")
                                        Text("Scroll to load more")
                                    }
                                }
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .id(model.searchPapers.count)
                                .task(id: model.searchPapers.count) {
                                    await model.loadMoreSearchResults()
                                }
                            } else if !model.isSearching {
                                Label(
                                    allResultsSummary,
                                    systemImage: "checkmark.circle"
                                )
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                            }
                        }
                        .frame(maxWidth: 860)
                        .padding(24)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.searchFocusToken) { searchFocused = true }
        .task(id: model.searchQuery) {
            model.prepareSearch(for: model.searchQuery)
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await model.search(model.searchQuery)
            } catch {
                return
            }
        }
    }

    private var allResultsSummary: String {
        let matches = model.searchResultTotal
            ?? model.searchPapers.reduce(0) { $0 + $1.matchCount }
        let papers = model.searchPaperCount ?? groups.count
        return "All results loaded · \(papers) papers, \(matches) matches"
    }
}

struct SearchPaperSection: View {
    @EnvironmentObject private var model: AppModel
    let group: LibrarySearchPaper
    let query: String
    let isExpanded: Bool
    let toggleExpanded: () -> Void

    private var visibleResults: ArraySlice<LibrarySearchResult> {
        group.evidence.prefix(isExpanded ? group.evidence.count : 5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Task { await model.open(searchPaper: group) }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HighlightedSnippet(text: group.title, query: query)
                            .font(.headline)
                            .lineLimit(2)
                        HighlightedSnippet(
                            text: paperMetadata(group.creators, group.year),
                            query: query
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(group.attachmentKey == nil && group.representative?.usableAttachmentKey == nil)

            Divider()

            ForEach(visibleResults) { result in
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

            if group.evidence.count > 5 {
                Button(
                    isExpanded ? "Show less" : "Show \(group.evidence.count - 5) more",
                    systemImage: isExpanded ? "chevron.up" : "chevron.down",
                    action: toggleExpanded
                )
                .font(.caption.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
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
                }
                searchStart = range.upperBound
            }
        }
        return result
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
    @Binding var isImmersive: Bool

    var body: some View {
        GeometryReader { geometry in
            ReaderLayout(
                session: session,
                availableWidth: geometry.size.width,
                isImmersive: $isImmersive
            )
        }
    }
}

struct ReaderLayout: View {
    @ObservedObject var session: PaperSession
    let availableWidth: CGFloat
    @Binding var isImmersive: Bool

    private var usesOverlayChat: Bool { availableWidth < 820 }
    private var presentedChatWidth: CGFloat {
        guard !isImmersive, session.isChatPresented else { return 0 }
        if usesOverlayChat {
            return min(max(availableWidth * 0.88, 300), 430)
        }
        return min(session.chatWidth, availableWidth * 0.48)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            PDFPane(
                session: session,
                isImmersive: $isImmersive,
                horizontalScrollAllowance: presentedChatWidth
            )

            if !isImmersive, session.isChatPresented {
                if usesOverlayChat {
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
                } else {
                    ResizableChatSidebar(session: session, totalWidth: availableWidth)
                    .background(.regularMaterial)
                    .shadow(color: .black.opacity(0.16), radius: 14, x: -4)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .clipped()
    }
}

private struct ResizableChatSidebar: View {
    @ObservedObject var session: PaperSession
    let totalWidth: CGFloat
    @State private var transientWidth: CGFloat?

    private var maximumWidth: CGFloat { totalWidth * 0.48 }
    private var committedWidth: CGFloat {
        min(max(session.chatWidth, 300), maximumWidth)
    }
    private var displayedWidth: CGFloat { transientWidth ?? committedWidth }

    var body: some View {
        HStack(spacing: 0) {
            ChatResizeHandle(
                initialWidth: displayedWidth,
                totalWidth: totalWidth,
                onChanged: { transientWidth = $0 },
                onEnded: { width in
                    if abs(session.chatWidth - width) > 0.5 {
                        session.chatWidth = width
                    }
                    transientWidth = nil
                }
            )
            .zIndex(10)
            ChatPane(session: session)
                .frame(width: displayedWidth)
        }
    }
}

struct ChatResizeHandle: View {
    let initialWidth: CGFloat
    let totalWidth: CGFloat
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void
    @State private var dragOrigin: DragOrigin?
    @State private var latestWidth: CGFloat?

    private struct DragOrigin {
        let sidebarWidth: CGFloat
        let pointerX: CGFloat
    }

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
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragOrigin == nil {
                        dragOrigin = DragOrigin(
                            sidebarWidth: initialWidth,
                            pointerX: value.startLocation.x
                        )
                    }
                    guard let dragOrigin else { return }
                    let proposed = dragOrigin.sidebarWidth
                        + dragOrigin.pointerX
                        - value.location.x
                    let width = min(max(proposed, 300), totalWidth * 0.48)
                    latestWidth = width
                    onChanged(width)
                }
                .onEnded { _ in
                    onEnded(latestWidth ?? initialWidth)
                    latestWidth = nil
                    dragOrigin = nil
                }
        )
    }
}

struct PDFPane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: PaperSession
    @Binding var isImmersive: Bool
    let horizontalScrollAllowance: CGFloat
    @State private var thumbnailsAreCompact = false
    @State private var pdfViewportRange = PDFViewportRange.full
    @State private var thumbnailInteractionToken = UUID()
    @State private var suppressThumbnailCompactionUntil = Date.distantPast

    private let thumbnailOverlayInset: CGFloat = 100

    private var presentsCompactThumbnails: Bool {
        #if os(macOS)
        false
        #else
        thumbnailsAreCompact
        #endif
    }

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
                        viewportRange: $pdfViewportRange,
                        selectedText: $session.selectedText,
                        selectionSnapshot: $session.selectionSnapshot,
                        highlightTarget: session.pdfHighlightTarget,
                        viewportTarget: session.pdfViewportTarget,
                        isImmersive: isImmersive,
                        horizontalScrollAllowance: horizontalScrollAllowance,
                        bottomOverlayInset: thumbnailOverlayInset,
                        thumbnailInteractionToken: thumbnailInteractionToken,
                        onCompactPresentationChange: { shouldCompact in
                            #if !os(macOS)
                            if shouldCompact, Date.now < suppressThumbnailCompactionUntil {
                                return
                            }
                            guard thumbnailsAreCompact != shouldCompact else { return }
                            withAnimation(.smooth(duration: 0.24)) {
                                thumbnailsAreCompact = shouldCompact
                            }
                            #endif
                        }
                    )
                } else {
                    ProgressView("Downloading PDF…")
                }
            }

            if !isImmersive, session.isPDFSearchPresented {
                PDFSearchPanel(session: session)
                    .frame(width: 360)
                    .padding(10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

        }
        .overlay(alignment: .bottom) {
            if !isImmersive, let url = session.pdfURL {
                PDFThumbnailStrip(
                    url: url,
                    pageIndex: Binding(
                        get: { session.pageIndex },
                        set: { model.pageChanged($0, in: session) }
                    ),
                    isCompact: presentsCompactThumbnails,
                    viewportRange: pdfViewportRange,
                    onInteractionBegan: {
                        #if !os(macOS)
                        suppressThumbnailCompactionUntil = Date.now.addingTimeInterval(1)
                        thumbnailInteractionToken = UUID()
                        #endif
                    },
                    onSelectPage: { page in
                        model.pageChanged(page, in: session)
                    },
                    onTapPage: {
                        #if !os(macOS)
                        withAnimation(.smooth(duration: 0.24)) {
                            thumbnailsAreCompact = false
                        }
                        #endif
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.28), value: isImmersive)
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
            await model.searchPDF(session.pdfSearchQuery, in: session)
        }
    }
}

struct ChatPane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: PaperSession

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: sidebarModeBinding) {
                Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    .tag(PaperSidebarMode.chat)
                Label("Bookmarks", systemImage: "bookmark")
                    .tag(PaperSidebarMode.bookmarks)
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .labelsHidden()
            .padding(.horizontal, 12)
            .frame(height: 48)
            Divider()

            Group {
                switch session.sidebarMode {
                case .chat:
                    VStack(spacing: 0) {
                        if session.agentTextAvailability == .unavailable {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(
                                    "No OCR or indexed text is available for this paper. "
                                        + "The agent cannot read it unless you include a PDF selection."
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Color.orange.opacity(0.09))
                            Divider()
                        }
                        switch session.chatRoute {
                        case .list:
                            ChatListView(session: session)
                        case .conversation, .compose:
                            ConversationView(session: session)
                        }
                    }
                case .bookmarks:
                    BookmarksView(session: session)
                }
            }
        }
        .background(Color.platformBackground)
    }

    private var sidebarModeBinding: Binding<PaperSidebarMode> {
        Binding(
            get: { session.sidebarMode },
            set: { mode in
                guard mode != session.sidebarMode else { return }
                DispatchQueue.main.async {
                    session.sidebarMode = mode
                    if mode == .bookmarks {
                        Task { await model.loadBookmarks(in: session) }
                    }
                }
            }
        )
    }
}

struct BookmarksView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: PaperSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bookmarks").font(.headline)
                Spacer()
                Menu("Add Bookmark", systemImage: "plus") {
                    if session.selectionSnapshot != nil {
                        Button("Selected Text", systemImage: "text.quote") {
                            Task { await model.addSelectionBookmark(in: session) }
                        }
                    }
                    Button("Current Page", systemImage: "doc") {
                        Task { await model.addPageBookmark(in: session) }
                    }
                }
                .labelStyle(.iconOnly)
                .help("Add bookmark")
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            Divider()

            if session.bookmarks.isEmpty, session.bookmarkSuggestions.isEmpty {
                ContentUnavailableView(
                    "No Bookmarks Yet",
                    systemImage: "bookmark",
                    description: Text("Bookmark the current page or selected text.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if !session.bookmarks.isEmpty {
                            bookmarkSection
                        }
                        if !session.bookmarkSuggestions.isEmpty {
                            suggestionSection
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var bookmarkSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SAVED")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            ForEach(session.bookmarks) { bookmark in
                Button {
                    model.openBookmark(bookmark, in: session)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: bookmark.kind == .selection ? "text.quote" : "bookmark.fill")
                            .foregroundStyle(.tint)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bookmarkTitle(bookmark))
                                .font(.callout.weight(.medium))
                                .lineLimit(bookmark.kind == .selection ? 2 : 1)
                            Text("Page \(bookmark.pageIndex + 1)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 9))
                .contextMenu {
                    Button("Delete Bookmark", systemImage: "trash", role: .destructive) {
                        Task { await model.deleteBookmark(bookmark, in: session) }
                    }
                }
            }
        }
    }

    private var suggestionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SUGGESTED FROM READING")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            ForEach(session.bookmarkSuggestions) { suggestion in
                HStack(spacing: 8) {
                    Button {
                        model.openSuggestion(suggestion, in: session)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "clock")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Page \(suggestion.pageIndex + 1)")
                                    .font(.callout.weight(.medium))
                                Text(viewingDuration(suggestion.totalActiveSeconds))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button("Add Page Bookmark", systemImage: "plus") {
                        Task {
                            await model.addPageBookmark(
                                in: session,
                                pageIndex: suggestion.pageIndex
                            )
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
                .padding(9)
                .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private func bookmarkTitle(_ bookmark: PaperBookmark) -> String {
        if let text = bookmark.selectedText?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text.replacingOccurrences(of: "\n", with: " ")
        }
        return "Page \(bookmark.pageIndex + 1)"
    }

    private func viewingDuration(_ seconds: Double) -> String {
        let minutes = max(1, Int(seconds / 60))
        return minutes == 1 ? "Viewed for about 1 minute" : "Viewed for about \(minutes) minutes"
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
                Button("Refresh Chat", systemImage: "arrow.clockwise") {
                    Task { await model.refreshConversation(in: session) }
                }
                .labelStyle(.iconOnly)
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
                        if let streamingMessage = session.streamingMessage {
                            StreamingMessageBubble(
                                message: streamingMessage,
                                session: session
                            ) {
                                proxy.scrollTo(streamingMessage.id, anchor: .bottom)
                            }
                            .id(streamingMessage.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: session.messages.count) {
                    if let last = session.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .refreshable {
                    await model.refreshConversation(in: session)
                }
            }

            Divider()
            ChatComposer(session: session)
        }
        .task(
            id: "\(session.selectedThread?.id ?? "none"):"
                + "\(model.route == .paper(session.id) && session.isChatPresented)"
        ) {
            guard model.route == .paper(session.id), session.isChatPresented else { return }
            await model.followConversation(in: session)
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
                            .font(.system(size: 16))
                            .padding(.horizontal, 6)
                            .padding(.top, 5)
                    }
                    TextEditor(text: $session.draft)
                        .focused($editorFocused)
                        .font(.system(size: 16))
                        .lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 1)
                        .padding(.top, 3)
                        .frame(minHeight: 72, maxHeight: 170)
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
                    .disabled(
                        session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || session.streamingMessage != nil
                            || session.messages.contains(where: { $0.status == "streaming" })
                    )
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
            Text(model.selectedModel?.displayName ?? "Default model")
                .lineLimit(1)
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
                Text((model.selectedEffortID ?? selectedModel.defaultReasoningEffort).capitalized)
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

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 32) }
            VStack(
                alignment: isUser ? .trailing : .leading,
                spacing: 6
            ) {
                if isUser {
                    UserMessageContext(message: message)
                }

                messageContent
                    .frame(maxWidth: isUser ? nil : .infinity, alignment: .leading)
                    .padding(isUser ? 10 : 0)
                    .background {
                        if isUser {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.secondary.opacity(0.10))
                        }
                    }

                if !message.content.isEmpty {
                    HStack(spacing: 6) {
                        Button("Copy", systemImage: "square.on.square") {
                            copyMessageToPasteboard()
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.platformSecondaryLabel)
                        .help("Copy message")

                        Text(messageTimestamp)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color.platformTertiaryLabel)
                    }
                }
            }
            .frame(maxWidth: isUser ? nil : .infinity, alignment: isUser ? .trailing : .leading)
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            if message.status == "failed", message.content.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Response failed. You can try again or keep chatting.")
                        .foregroundStyle(Color.platformPrimaryLabel)
                }
                .font(.callout)
            } else if message.content.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, 2)
            } else {
                ChatRichText(
                    source: message.content,
                    isStreaming: message.status == "streaming"
                ) { page in
                    model.pageChanged(page - 1, in: session)
                }
            }
            if message.status == "failed", !message.content.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Response interrupted")
                        .foregroundStyle(Color.platformPrimaryLabel)
                }
                .font(.caption)
            }
        }
    }

    private var messageTimestamp: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: message.createdAt)
        return date?.formatted(.dateTime.hour().minute()) ?? ""
    }

    private func copyMessageToPasteboard() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        #else
        UIPasteboard.general.string = message.content
        #endif
    }
}

private struct UserMessageContext: View {
    let message: ChatMessage

    private var pageNumbers: [Int] {
        Array(Set(message.pageRefs.map { $0.pageIndex + 1 })).sorted()
    }

    private var pageLabel: String? {
        guard !pageNumbers.isEmpty else { return nil }
        let numbers = pageNumbers.map(String.init).joined(separator: ", ")
        return pageNumbers.count == 1 ? "Page \(numbers)" : "Pages \(numbers)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let pageLabel {
                Label(pageLabel, systemImage: "doc.text")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.platformSecondaryLabel)
            }
            if let selectedText = message.selectedText?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !selectedText.isEmpty {
                Label("PDF selection", systemImage: "text.quote")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.platformSecondaryLabel)
                Text(selectedText)
                    .font(.caption)
                    .foregroundStyle(Color.platformSecondaryLabel)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
    }
}

private struct StreamingMessageBubble: View {
    @ObservedObject var message: StreamingChatMessage
    @ObservedObject var session: PaperSession
    let onContentUpdate: () -> Void

    var body: some View {
        MessageBubble(message: message.snapshot, session: session)
            .onAppear(perform: onContentUpdate)
            .onChange(of: message.content) { _, _ in
                onContentUpdate()
            }
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
    static var platformPrimaryLabel: Color {
        #if os(macOS)
        Color(nsColor: .labelColor)
        #else
        Color(uiColor: .label)
        #endif
    }

    static var platformSecondaryLabel: Color {
        #if os(macOS)
        Color(nsColor: .secondaryLabelColor)
        #else
        Color(uiColor: .secondaryLabel)
        #endif
    }

    static var platformTertiaryLabel: Color {
        #if os(macOS)
        Color(nsColor: .tertiaryLabelColor)
        #else
        Color(uiColor: .tertiaryLabel)
        #endif
    }

    static var platformBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

private extension View {
    @ViewBuilder
    func paperChromeHidden(_ hidden: Bool) -> some View {
        #if os(macOS)
        toolbarVisibility(hidden ? .hidden : .visible, for: .windowToolbar)
        #else
        toolbarVisibility(hidden ? .hidden : .visible, for: .navigationBar)
            .statusBarHidden(hidden)
        #endif
    }

    @ViewBuilder
    func paperNavigationTitleStyle() -> some View {
        #if os(macOS)
        self
        #else
        navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    func paperNavigationSubtitle(_ subtitle: String) -> some View {
        #if os(macOS)
        navigationSubtitle(subtitle)
        #else
        if #available(iOS 26.0, *) {
            navigationSubtitle(subtitle)
        } else {
            self
        }
        #endif
    }
}
