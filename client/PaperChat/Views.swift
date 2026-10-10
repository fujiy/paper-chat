import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.isAuthenticated || model.isSimulatorBookmarkReproMode {
                LibraryWorkspace()
            } else {
                SignInView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isOffline, model.isAuthenticated {
                HStack(spacing: 8) {
                    Label("Offline · Saved papers available", systemImage: "wifi.slash")
                        .font(.caption)
                    Spacer()
                    Button("Reconnect") { Task { await model.refreshLibrary() } }
                        .font(.caption)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.regularMaterial)
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
            #if DEBUG && os(iOS) && targetEnvironment(simulator)
            Button("Load Local Bookmark Test Data", systemImage: "bookmark") {
                model.loadSimulatorBookmarkReproFixture()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("simulator.bookmark-repro")
            #endif
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
            WorkspaceDetail(
                columnVisibility: $columnVisibility,
                isPDFImmersive: $isPDFImmersive
            )
        }
        .navigationSplitViewStyle(.prominentDetail)
        #if !os(macOS)
        // Remove the system toggle at the split-view level so it stays removed
        // when UIKit moves it between columns during sidebar transitions.
        .toolbar(removing: .sidebarToggle)
        #endif
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
        #if !os(macOS)
        .toolbar(removing: .sidebarToggle)
        #endif
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
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var isPDFImmersive: Bool
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

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
            case let .management(id):
                if let session = model.managementSessions.first(where: { $0.id == id }) {
                    ConversationView(session: session)
                        .frame(maxWidth: 960)
                        .frame(maxWidth: .infinity)
                }
            case .paper:
                Color.platformBackground
            }

            ForEach(model.openSessions) { session in
                let isActive = model.route == .paper(session.id)
                ReaderWorkspace(
                    session: session,
                    isActive: isActive,
                    isImmersive: $isPDFImmersive
                )
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(isActive)
                .accessibilityHidden(!isActive)
                .zIndex(isActive ? 2 : 0)
            }
        }
        .navigationTitle(navigationTitle)
        .paperNavigationSubtitle(navigationSubtitle)
        .paperNavigationTitleStyle()
        .paperChromeHidden(isPDFImmersive)
        .background {
            WorkspaceShortcuts()
        }
        #if !os(macOS)
        .toolbar(removing: .sidebarToggle)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: backButtonPlacement) {
                #if !os(macOS)
                if horizontalSizeClass == .regular {
                    Button("Toggle Sidebar", systemImage: "sidebar.left") {
                        withAnimation(.snappy) {
                            columnVisibility = columnVisibility == .all ? .detailOnly : .all
                        }
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("workspace.sidebar")
                }
                #endif
                Button("Back", systemImage: "chevron.left") {
                    model.goBack()
                }
                .labelStyle(.iconOnly)
                .disabled(model.navigationHistory.isEmpty)
                .accessibilityIdentifier("workspace.back")
            }
            if let session = model.activeSession {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(
                        session.paper.isStarred ? "Unstar" : "Star",
                        systemImage: session.paper.isStarred ? "star.fill" : "star"
                    ) {
                        Task { await model.toggleStar(in: session) }
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
                        session.isChatPresented ? "Hide Inspector" : "Show Inspector",
                        systemImage: "sidebar.right"
                    ) {
                        withAnimation(.snappy(duration: 0.22)) {
                            if session.isChatPresented {
                                session.isChatPresented = false
                            } else {
                                session.isChatPresented = true
                            }
                        }
                    }
                }
            }
        }
    }

    private var backButtonPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .navigation
        #else
        .topBarLeading
        #endif
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
        case .management: return "Management Chat"
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
            Button("Search in PDF") {
                guard let session = model.activeSession else { return }
                model.presentSearch(in: session)
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
    @State private var expandedPaperIDs: Set<String> = []

    private var groups: [LibrarySearchPaper] { model.searchPapers }

    var body: some View {
        VStack(spacing: 0) {
            LibrarySearchBar()
            if model.isOffline {
                Text("Searching saved titles and authors on this device")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            }

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

private struct LibrarySearchBar: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        SearchField(
            text: $model.searchQuery,
            prompt: "Search title, author, DOI, citekey, or full text"
        )
        .focused($searchFocused)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
        .onAppear { searchFocused = true }
        .onChange(of: model.searchFocusToken) { searchFocused = true }
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

    private var hasOpenablePDF: Bool {
        group.attachmentKey != nil || group.representative?.usableAttachmentKey != nil
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
                    if hasOpenablePDF {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("PDFなし", systemImage: "doc.badge.minus")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasOpenablePDF)

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
            .map { ($0[0].paperTitle ?? "Management", $0) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("New Management Chat", systemImage: "square.and.pencil") {
                    model.beginManagementChat()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        if groups.isEmpty {
            ContentUnavailableView(
                "No Chats Yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Start a management chat, or open a paper to discuss it.")
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
}

struct ReaderWorkspace: View {
    @ObservedObject var session: PaperSession
    let isActive: Bool
    @Binding var isImmersive: Bool
    #if os(iOS)
    @State private var ignoresKeyboardSafeArea = false
    #endif

    @ViewBuilder
    var body: some View {
        if isActive {
            pdfPane
                #if os(iOS)
                .ignoresSafeArea(
                    ignoresKeyboardSafeArea ? .keyboard : [],
                    edges: .bottom
                )
                #endif
                .inspector(isPresented: inspectorPresented) {
                    Group {
                        #if os(iOS)
                        InspectorChatPane(
                            session: session,
                            ignoresKeyboardSafeArea: $ignoresKeyboardSafeArea
                        )
                        #else
                        InspectorChatPane(session: session)
                        #endif
                    }
                        .inspectorColumnWidth(min: 320, ideal: 390, max: 520)
                        #if os(iOS)
                        .presentationDetents([.medium, .large])
                        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                        #endif
                }
        } else {
            pdfPane
        }
    }

    private var pdfPane: some View {
        PDFPane(
            session: session,
            isImmersive: $isImmersive,
            isInspectorPresented: isActive && !isImmersive && session.isChatPresented
        )
    }

    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { isActive && !isImmersive && session.isChatPresented },
            set: { isPresented in
                guard isActive else { return }
                session.isChatPresented = isPresented
            }
        )
    }
}

private struct InspectorChatPane: View {
    let session: PaperSession
    #if os(iOS)
    @Binding var ignoresKeyboardSafeArea: Bool
    @State private var keyboardIsHiding = false
    #endif

    var body: some View {
        #if os(iOS)
        ChatPane(session: session)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                WindowKeyboardLayoutMonitor { isUndocked in
                    guard !keyboardIsHiding else { return }
                    ignoresKeyboardSafeArea = isUndocked
                }
            }
            .ignoresSafeArea(
                ignoresKeyboardSafeArea ? .keyboard : [],
                edges: .bottom
            )
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillShowNotification
                )
            ) { notification in
                keyboardIsHiding = false
                updateKeyboardSafeArea(from: notification)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardDidShowNotification
                )
            ) { notification in
                updateKeyboardSafeArea(from: notification)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardDidChangeFrameNotification
                )
            ) { notification in
                guard !keyboardIsHiding else { return }
                updateKeyboardSafeArea(from: notification)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillHideNotification
                )
            ) { _ in
                keyboardIsHiding = true
                ignoresKeyboardSafeArea = false
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardDidHideNotification
                )
            ) { _ in
                keyboardIsHiding = false
                ignoresKeyboardSafeArea = false
            }
        #else
        ChatPane(session: session)
        #endif
    }

    #if os(iOS)
    private func updateKeyboardSafeArea(from notification: Notification) {
        guard let screenFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
            as? CGRect else { return }

        // When iPadOS restores an already-floating keyboard, it reports the
        // docked keyboard as dismissed (a zero-height frame) even though the
        // floating keyboard remains visible. SwiftUI nevertheless retains the
        // old docked keyboard safe area, so it must be ignored in this case.
        if screenFrame.height <= 1 {
            ignoresKeyboardSafeArea = true
            return
        }

        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return }
        let frame = window.convert(screenFrame, from: nil)
        let intersection = window.bounds.intersection(frame)
        guard !intersection.isNull, !intersection.isEmpty else { return }

        let isDocked = frame.maxY >= window.bounds.maxY - 1
            && intersection.width >= window.bounds.width - 1
        ignoresKeyboardSafeArea = !isDocked
    }
    #endif
}

#if os(iOS)
private struct WindowKeyboardLayoutMonitor: UIViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeUIView(context: Context) -> KeyboardLayoutMonitorInstallerView {
        let view = KeyboardLayoutMonitorInstallerView()
        view.onChange = onChange
        return view
    }

    func updateUIView(
        _ uiView: KeyboardLayoutMonitorInstallerView,
        context: Context
    ) {
        uiView.onChange = onChange
    }

    static func dismantleUIView(
        _ uiView: KeyboardLayoutMonitorInstallerView,
        coordinator: Void
    ) {
        uiView.removeTrackingView()
    }
}

@MainActor
private final class KeyboardLayoutMonitorInstallerView: UIView, UIGestureRecognizerDelegate {
    var onChange: (@MainActor (Bool) -> Void)?
    private weak var trackingContainer: KeyboardTrackingContainer?
    private weak var tapRecognizer: UITapGestureRecognizer?
    private weak var gestureHostView: UIView?
    private var lastValue: Bool?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installTrackingView()
    }

    func removeTrackingView() {
        trackingContainer?.removeFromSuperview()
        if let tapRecognizer {
            gestureHostView?.removeGestureRecognizer(tapRecognizer)
        }
    }

    private func installTrackingView() {
        removeTrackingView()
        guard let window else { return }

        let container = KeyboardTrackingContainer()
        container.isUserInteractionEnabled = false
        container.translatesAutoresizingMaskIntoConstraints = false
        container.onLayout = { [weak self, weak window] frame in
            guard let self, let window else { return }
            let isUndocked = !frame.isEmpty && frame.width < window.bounds.width - 1
            guard isUndocked != self.lastValue else { return }
            self.lastValue = isUndocked
            self.onChange?(isUndocked)
        }
        window.insertSubview(container, at: 0)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: window.topAnchor),
            container.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: window.bottomAnchor),
        ])
        trackingContainer = container

        let tapRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(dismissKeyboard)
        )
        tapRecognizer.cancelsTouchesInView = false
        tapRecognizer.delegate = self
        window.addGestureRecognizer(tapRecognizer)
        self.tapRecognizer = tapRecognizer
        gestureHostView = window
    }

    @objc private func dismissKeyboard() {
        window?.endEditing(true)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        var touchedView = touch.view
        while let view = touchedView {
            if view is UITextView || view is UITextField {
                return false
            }
            touchedView = view.superview
        }
        return true
    }
}

@MainActor
private final class KeyboardTrackingContainer: UIView {
    var onLayout: (@MainActor (CGRect) -> Void)?
    private let trackingView = UIView()
    private var layoutUpdateScheduled = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        keyboardLayoutGuide.followsUndockedKeyboard = true
        trackingView.backgroundColor = .clear
        trackingView.isUserInteractionEnabled = false
        trackingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trackingView)
        NSLayoutConstraint.activate([
            trackingView.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            trackingView.leadingAnchor.constraint(equalTo: keyboardLayoutGuide.leadingAnchor),
            trackingView.trailingAnchor.constraint(equalTo: keyboardLayoutGuide.trailingAnchor),
            trackingView.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !layoutUpdateScheduled else { return }
        layoutUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutUpdateScheduled = false
            self.onLayout?(self.trackingView.frame)
        }
    }
}
#endif

struct PDFPane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: PaperSession
    @Binding var isImmersive: Bool
    let isInspectorPresented: Bool
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
                        bookmarkPageIndex: $session.bookmarkPageIndex,
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
                        pagePosition: $session.pagePosition,
                        viewportRange: $pdfViewportRange,
                        selectedText: $session.selectedText,
                        selectionSnapshot: $session.selectionSnapshot,
                        highlightTarget: session.pdfHighlightTarget,
                        viewportTarget: session.pdfViewportTarget,
                        documentStructure: session.documentStructure,
                        isImmersive: isImmersive,
                        isInspectorPresented: isInspectorPresented,
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

struct PDFSearchView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: PaperSession
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search in PDF", text: $session.pdfSearchQuery)
                    .textFieldStyle(.plain)
                    .focused($focused)
                if !session.pdfSearchQuery.isEmpty {
                    Text("\(session.pdfSearchResults.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            Divider()

            if !session.pdfSearchResults.isEmpty {
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
            } else if session.pdfSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "Search this PDF",
                    systemImage: "magnifyingglass",
                    description: Text("Enter a word or phrase to find it in this paper.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.platformBackground)
        .onAppear { focused = true }
        .onChange(of: session.pdfSearchFocusRequest) { _, _ in focused = true }
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
            Picker("Inspector", selection: sidebarModeBinding) {
                Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    .tag(PaperSidebarMode.chat)
                Label("Search", systemImage: "magnifyingglass")
                    .tag(PaperSidebarMode.search)
                Label("Navigate", systemImage: "list.bullet.indent")
                    .tag(PaperSidebarMode.navigate)
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
                case .search:
                    PDFSearchView(session: session)
                case .navigate:
                    NavigateView(session: session)
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
                    switch mode {
                    case .chat:
                        model.presentChat(in: session)
                    case .search:
                        model.presentSearch(in: session)
                    case .navigate:
                        model.presentNavigate(in: session)
                    case .bookmarks:
                        model.presentBookmarks(in: session)
                    }
                }
            }
        )
    }
}

private struct StructureHierarchyLabel {
    let number: String?
    let title: String
    let level: Int
}

private struct DocumentOutlineTreeNode: Identifiable {
    let node: DocumentOutlineNode
    let number: String?
    let title: String
    let level: Int
    let children: [DocumentOutlineTreeNode]

    var id: String { node.id }
}

private final class MutableDocumentOutlineTreeNode {
    let node: DocumentOutlineNode
    let number: String?
    let title: String
    let level: Int
    var children: [MutableDocumentOutlineTreeNode] = []

    init(node: DocumentOutlineNode, label: StructureHierarchyLabel) {
        self.node = node
        number = label.number
        title = label.title
        level = label.level
    }

    func freeze() -> DocumentOutlineTreeNode {
        DocumentOutlineTreeNode(
            node: node,
            number: number,
            title: title,
            level: level,
            children: children.map { $0.freeze() }
        )
    }
}

private enum StructureHierarchy {
    private static let decimalHeading = try! NSRegularExpression(
        pattern: #"^\s*(\d+(?:\.\d+)*)(?:[.)])?\s+(.+?)\s*$"#
    )
    private static let namedHeading = try! NSRegularExpression(
        pattern: #"^\s*([IVXLCDM]+|[A-Z])[.)]\s+(.+?)\s*$"#
    )
    private static let artifactPrefix = try! NSRegularExpression(
        pattern: #"(?i)^\s*(?:fig(?:ure)?\.?|table|equation|eq\.?)\s*\(?([0-9]+(?:\.[0-9]+)*(?:[a-z])?)\)?[.:]?\s*(.*?)\s*$"#
    )
    private static let bareArtifactNumber = try! NSRegularExpression(
        pattern: #"^\s*\(?([0-9]+(?:\.\d+)*(?:[a-z])?)\)?[.:]?\s*$"#
    )
    private static let artifactMention = try! NSRegularExpression(
        pattern: #"(?i)\b(?:fig(?:ure)?\.?|table|equation|eq\.?)\s*\(?([0-9]+(?:\.[0-9]+)*(?:[a-z])?)\)?"#
    )
    private static let trailingArtifactNumber = try! NSRegularExpression(
        pattern: #"\(([0-9]+(?:\.[0-9]+)*(?:[a-z])?)\)\s*$"#
    )
    private static let parenthesizedHierarchyNumber = try! NSRegularExpression(
        pattern: #"\(([0-9]+(?:\.[0-9]+)+(?:[a-z])?)\)"#
    )
    private static let subordinateHeading = try! NSRegularExpression(
        pattern: #"(?i)^\s*(?:corollary|lemma|proposition|theorem)\b"#
    )

    static func outlineTree(_ nodes: [DocumentOutlineNode]) -> [DocumentOutlineTreeNode] {
        var roots: [MutableDocumentOutlineTreeNode] = []
        var stack: [MutableDocumentOutlineTreeNode] = []

        for node in nodes {
            var label = heading(node)
            if node.parentID == nil,
               node.level <= 1,
               label.number == nil,
               matches(subordinateHeading, in: node.title),
               let previous = stack.last {
                label = StructureHierarchyLabel(
                    number: nil,
                    title: label.title,
                    level: min(previous.level + 1, 4)
                )
            }

            let effectiveLevel = min(label.level, (stack.last?.level ?? 0) + 1)
            let adjusted = StructureHierarchyLabel(
                number: label.number,
                title: label.title,
                level: max(1, effectiveLevel)
            )
            let item = MutableDocumentOutlineTreeNode(node: node, label: adjusted)

            while let last = stack.last, last.level >= adjusted.level {
                stack.removeLast()
            }
            if let explicitParent = node.parentID,
               let parentIndex = stack.lastIndex(where: { $0.node.id == explicitParent }) {
                stack[parentIndex].children.append(item)
                stack.removeSubrange((parentIndex + 1)..<stack.endIndex)
            } else if let parent = stack.last {
                parent.children.append(item)
            } else {
                roots.append(item)
            }
            stack.append(item)
        }
        return roots.map { $0.freeze() }
    }

    static func artifact(_ item: DocumentObject) -> StructureHierarchyLabel {
        let candidates: [String]
        if item.kind == "formula" {
            candidates = [item.label, item.text].compactMap { $0 }.filter { !$0.isEmpty }
        } else {
            candidates = [item.label, item.title, item.caption, item.text]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
        }
        var number: String?
        var title = item.title

        for candidate in candidates {
            if let groups = captures(artifactPrefix, in: candidate) {
                number = groups[0]
                if candidate == item.title, groups.count > 1, !groups[1].isEmpty {
                    title = groups[1]
                }
                break
            }
            if let groups = captures(bareArtifactNumber, in: candidate) {
                number = groups[0]
                break
            }
            if let groups = captures(artifactMention, in: candidate) {
                number = groups[0]
                break
            }
            if let groups = captures(trailingArtifactNumber, in: candidate) {
                number = groups[0]
                break
            }
            if let groups = captures(parenthesizedHierarchyNumber, in: candidate) {
                number = groups[0]
                break
            }
        }

        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || title == item.label
            || title.range(of: #"(?i)^\s*(?:fig(?:ure)?\.?|table|equation|eq\.?)\s*\(?[0-9]+(?:\.[0-9]+)*(?:[a-z])?\)?[.:]?\s*$"#, options: .regularExpression) != nil {
            title = item.kind == "table" ? "Table" : item.kind == "formula" ? "Equation" : "Figure"
        }

        return StructureHierarchyLabel(
            number: number,
            title: title,
            level: hierarchyLevel(number)
        )
    }

    private static func heading(_ node: DocumentOutlineNode) -> StructureHierarchyLabel {
        if let groups = captures(decimalHeading, in: node.title) {
            return StructureHierarchyLabel(
                number: groups[0],
                title: groups[1],
                level: node.level > 1 ? node.level : hierarchyLevel(groups[0])
            )
        }
        if let groups = captures(namedHeading, in: node.title) {
            let token = groups[0]
            let inferredLevel = token.count == 1 && !["I", "V", "X"].contains(token) ? 2 : 1
            return StructureHierarchyLabel(
                number: token,
                title: groups[1],
                level: node.level > 1 ? node.level : inferredLevel
            )
        }
        return StructureHierarchyLabel(number: nil, title: node.title, level: max(1, node.level))
    }

    private static func hierarchyLevel(_ number: String?) -> Int {
        guard let number else { return 1 }
        return max(1, number.split(separator: ".").count)
    }

    private static func matches(_ expression: NSRegularExpression, in text: String) -> Bool {
        expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ) != nil
    }

    private static func captures(
        _ expression: NSRegularExpression,
        in text: String
    ) -> [String]? {
        guard let match = expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }
}

private struct DocumentOutlineBranchView: View {
    let item: DocumentOutlineTreeNode
    let subtitle: String
    let action: (DocumentOutlineNode) -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 4) {
                expansionControl
                row
            }

            if isExpanded, !item.children.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(item.children) { child in
                        DocumentOutlineBranchView(
                            item: child,
                            subtitle: child.node.anchor.map { "Page \($0.pageIndex + 1)" }
                                ?? "Location unavailable",
                            action: action
                        )
                    }
                }
                .padding(.leading, 20)
            }
        }
    }

    @ViewBuilder
    private var expansionControl: some View {
        if item.children.isEmpty {
            Color.clear
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
        } else {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse section" : "Expand section")
            .accessibilityLabel(isExpanded ? "Collapse \(item.title)" : "Expand \(item.title)")
        }
    }

    private var row: some View {
        Button { action(item.node) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                hierarchyNumber(item.number)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.callout.weight(.medium)).lineLimit(3)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func hierarchyNumber(_ number: String?) -> some View {
        if let number {
            Text(number)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 28, alignment: .trailing)
        } else {
            Image(systemName: "text.alignleft")
                .foregroundStyle(.tertiary)
                .frame(width: 28)
        }
    }
}

private struct NavigateDisclosureSection<Content: View>: View {
    let title: String
    let systemImage: String
    @Binding var isExpanded: Bool
    private let content: () -> Content

    init(
        title: String,
        systemImage: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self._isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    Label(title, systemImage: systemImage)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")

            if isExpanded {
                content()
            }
        }
    }
}

struct NavigateView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: PaperSession
    @State private var isOutlineExpanded = true
    @State private var isFiguresExpanded = false
    @State private var isReferencesExpanded = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                NavigateDisclosureSection(
                    title: "Outline",
                    systemImage: "list.bullet.indent",
                    isExpanded: $isOutlineExpanded
                ) {
                    if let mineru = session.mineruDocument {
                        outlineList(mineru.outline)
                    } else if session.isStructureLoading {
                        ProgressView("Loading document structure…")
                            .padding(12)
                    } else {
                        mineruUnavailable()
                    }
                }
                Divider()

                NavigateDisclosureSection(
                    title: "Figures",
                    systemImage: "photo.on.rectangle",
                    isExpanded: $isFiguresExpanded
                ) {
                    if let mineru = session.mineruDocument {
                        mineruFigureList(mineru.figures)
                    } else if session.isStructureLoading {
                        ProgressView("Loading document structure…")
                            .padding(12)
                    } else {
                        mineruUnavailable()
                    }
                }
                Divider()

                NavigateDisclosureSection(
                    title: "References",
                    systemImage: "books.vertical",
                    isExpanded: $isReferencesExpanded
                ) {
                    if let structure = session.documentStructure {
                        referenceContent(structure)
                    } else if session.isStructureLoading {
                        ProgressView("Loading references…")
                            .padding(12)
                    } else {
                        unavailable(
                            title: "References Not Available",
                            systemImage: "books.vertical",
                            description: "GROBID has not processed the references yet."
                        )
                    }
                }
            }
        }
        .background(Color.platformBackground)
    }

    private func mineruUnavailable() -> some View {
        unavailable(
            title: "MinerU Data Not Available",
            systemImage: "doc.text.magnifyingglass",
            description: "This paper has no MinerU outline or figures yet."
        )
    }

    @ViewBuilder
    private func referenceContent(_ structure: DocumentStructure) -> some View {
        if structure.status == "processing" || structure.status == "pending" {
            unavailable(
                title: "Analysis in Progress",
                systemImage: "hourglass",
                description: "This paper is queued for reference extraction."
            )
        } else if structure.status == "failed" {
            unavailable(
                title: "Analysis Failed",
                systemImage: "exclamationmark.triangle",
                description: structure.error ?? "GROBID could not analyze this PDF."
            )
        } else {
            referenceList(structure.references)
        }
    }

    private func mineruFigureList(_ figures: [MinerUFigure]) -> some View {
        Group {
            if figures.isEmpty {
                ContentUnavailableView("No Figures Found", systemImage: "photo")
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(figures) { figure in
                        Button {
                            model.openStructureAnchor(figure.anchor, in: session)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                if let url = figure.thumbnailURL,
                                   let image = mineruThumbnail(at: url) {
                                    image
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 94, height: 76)
                                        .background(.white, in: RoundedRectangle(cornerRadius: 5))
                                } else {
                                    Image(systemName: figure.kind == "table" ? "tablecells" : "photo")
                                        .frame(width: 94, height: 76)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(figure.title).font(.callout.weight(.medium)).lineLimit(4)
                                    Text("Page \(figure.anchor.pageIndex + 1)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
            }
        }
    }

    private func mineruThumbnail(at url: URL) -> Image? {
        #if os(iOS)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: image)
        #else
        guard let image = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: image)
        #endif
    }

    private func outlineList(_ outline: [DocumentOutlineNode]) -> some View {
        Group {
            if outline.isEmpty {
                ContentUnavailableView("No Items Found", systemImage: "list.bullet")
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(StructureHierarchy.outlineTree(outline)) { item in
                        DocumentOutlineBranchView(
                            item: item,
                            subtitle: item.node.anchor.map { "Page \($0.pageIndex + 1)" }
                                ?? "Location unavailable"
                        ) { node in
                            model.openStructureAnchor(node.anchor, in: session)
                        }
                    }
                }
                .padding(.vertical, 10)
                .padding(.leading, 16)
                .padding(.trailing, 10)
                .id(session.id)
            }
        }
    }

    private func itemList<Item: Identifiable, Row: View>(
        _ items: [Item],
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("No Items Found", systemImage: "list.bullet")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(items) { item in row(item) }
                    }
                    .padding(10)
                }
            }
        }
    }

    private func referenceList(_ references: [DocumentReference]) -> some View {
        Group {
            if references.isEmpty {
                ContentUnavailableView("No References Found", systemImage: "books.vertical")
            } else {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(references) { reference in
                        HStack(alignment: .top, spacing: 8) {
                            Button {
                                model.openStructureAnchor(reference.anchor, in: session)
                            } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    Text(reference.label)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(minWidth: 22, alignment: .trailing)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(reference.title)
                                            .font(.callout.weight(.medium))
                                            .lineLimit(3)
                                        Text(referenceSubtitle(reference))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if reference.matchedAttachmentKey != nil {
                                Button("Open Library Paper", systemImage: "arrow.up.right.square") {
                                    Task { await model.openMatchedReference(reference) }
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("Open matching paper from your library")
                            }
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.34), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(10)
            }
        }
    }

    private func structureRow(
        title: String,
        subtitle: String,
        icon: String,
        number: String? = nil,
        indentation: Int = 0,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                if let number {
                    Text(number)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 32, alignment: .trailing)
                } else {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 32)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium)).lineLimit(3)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(indentation) * 14)
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func unavailable(title: String, systemImage: String, description: String) -> some View {
        VStack(spacing: 10) {
            ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
            Button("Refresh") { Task { await model.loadStructure(in: session) } }
                .disabled(session.isStructureLoading)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func pageLabel(_ anchor: DocumentAnchor?) -> String {
        anchor.map { "Page \($0.pageIndex + 1)" } ?? "Location unavailable"
    }

    private func compactSubtitle(_ text: String?, anchor: DocumentAnchor?) -> String {
        [text, pageLabel(anchor)].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " · ")
    }

    private func referenceSubtitle(_ reference: DocumentReference) -> String {
        let authors = reference.authors.prefix(2).joined(separator: ", ")
        return [authors.isEmpty ? nil : authors, reference.year, pageLabel(reference.anchor)]
            .compactMap { $0 }
            .joined(separator: " · ")
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
    @ObservedObject var session: ChatSession

    var body: some View {
        ChatKitConversation(session: session)
            .id(session.id)
    }
}

struct NativeConversationView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: ChatSession

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
                            Text(session.isManagement
                                ? "Manage skills, tools, and your Codex workspace."
                                : "Ask a question about this paper.")
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
                + "\(model.isConversationVisible(session))"
        ) {
            guard model.isConversationVisible(session) else { return }
            await model.refreshConversation(in: session)
        }
    }
}

struct ChatComposer: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: ChatSession
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
                        Text(session.isManagement ? "Ask Codex…" : "Ask about page \(session.pageIndex + 1)…")
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
                            || session.isSending
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
    @ObservedObject var session: ChatSession
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
                    isStreaming: message.status == "streaming",
                    onOpenPaper: { url in Task { await model.openURL(url) } }
                ) { page in
                    if let paper = session as? PaperSession {
                        model.pageChanged(page - 1, in: paper)
                    }
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
    @ObservedObject var session: ChatSession
    let onContentUpdate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.progressItems.isEmpty {
                AgentProgressView(items: message.progressItems)
            }
            if !message.content.isEmpty || message.progressItems.isEmpty {
                MessageBubble(message: message.snapshot, session: session)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: onContentUpdate)
        .onChange(of: message.content) { _, _ in
            onContentUpdate()
        }
        .onChange(of: message.progressItems) { _, _ in
            onContentUpdate()
        }
    }
}

private struct AgentProgressView: View {
    let items: [ChatProgressItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("Working…")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.platformPrimaryLabel)
            }

            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    statusIcon(for: item)
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.platformSecondaryLabel)
                        if !item.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(item.detail)
                                .font(item.kind == "command" ? .caption.monospaced() : .caption)
                                .foregroundStyle(Color.platformSecondaryLabel)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func statusIcon(for item: ChatProgressItem) -> some View {
        if item.status == "running" {
            ProgressView()
                .controlSize(.mini)
        } else if item.status == "failed" {
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        } else {
            Image(systemName: iconName(for: item.kind))
                .font(.caption)
                .foregroundStyle(Color.platformTertiaryLabel)
        }
    }

    private func iconName(for kind: String) -> String {
        switch kind {
        case "commentary": "text.bubble"
        case "reasoning": "sparkles"
        case "tool": "wrench.and.screwdriver"
        case "command": "terminal"
        case "web_search": "globe"
        default: "checkmark.circle"
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
