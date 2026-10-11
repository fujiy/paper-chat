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
        #if os(macOS)
        Window("PaperChat", id: "main") {
            PaperChatWindow()
        }
        .defaultSize(width: 1120, height: 760)
        #else
        WindowGroup {
            PaperChatWindow()
        }
        .defaultSize(width: 1120, height: 760)
        #endif
    }
}

struct PaperChatWindow: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RootView()
            .environmentObject(model)
            .task { await model.restoreSession() }
            .onOpenURL { url in
                Task { await model.openURL(url) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await model.appDidBecomeActive() }
                } else {
                    model.appDidResignActive()
                }
            }
    }
}
