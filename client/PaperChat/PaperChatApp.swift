import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct PaperChatApp: App {
    init() {
        #if os(macOS)
        NSWindow.allowsAutomaticWindowTabbing = false
        #endif
    }

    var body: some Scene {
        WindowGroup {
            PaperChatWindow()
        }
        .defaultSize(width: 1120, height: 760)
    }
}

struct PaperChatWindow: View {
    @StateObject private var model = AppModel()

    var body: some View {
        RootView()
            .environmentObject(model)
            .task { await model.restoreSession() }
    }
}
