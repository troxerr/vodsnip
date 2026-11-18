import AppKit
import SwiftUI

@main
struct VodsnipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = DownloaderModel()

    var body: some Scene {
        Window("Vodsnip", id: "main") {
            ContentView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Fetch Link") { Task { await model.fetch() } }
                    .keyboardShortcut("r")
                    .disabled(!model.canFetch)
                Button("Download") { Task { await model.download() } }
                    .keyboardShortcut("d")
                    .disabled(!model.canDownload)
                Button("Cancel Download") { model.cancel() }
                    .keyboardShortcut(".")
                    .disabled(model.phase != .downloading)
                Divider()
                Button("Choose Save Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
