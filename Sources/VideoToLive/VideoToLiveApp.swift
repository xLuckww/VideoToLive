import AppKit
import SwiftUI

@main
struct VideoToLiveApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("VideoToLive") {
            ContentView(model: model)
                .frame(minWidth: 900, idealWidth: 1080, minHeight: 640, idealHeight: 760)
                // 只做浅色主题，不跟随系统深色模式
                .preferredColorScheme(.light)
                .onAppear { NSApp.appearance = NSAppearance(named: .aqua) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("打开视频…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
        }
    }
}
