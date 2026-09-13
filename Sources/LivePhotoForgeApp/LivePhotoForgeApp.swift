import SwiftUI

@main
struct LivePhotoForgeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("LivePhotoForge") {
            ContentView(model: model)
                .frame(minWidth: 460, idealWidth: 520, minHeight: 520, idealHeight: 580)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("打开视频…") { openPanel() }
                    .keyboardShortcut("o")
            }
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.load(url)
        }
    }
}
