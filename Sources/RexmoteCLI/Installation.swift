import Foundation

enum Installation {
    static var app: URL {
        let executable = URL(fileURLWithPath: PaneCommands.executable)
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if bundle.pathExtension == "app" { return bundle }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Rexmote.app")
    }
    static var host: URL { app.appendingPathComponent("Contents/Helpers/Rexmote Host.app") }
    static var holder: URL { app.appendingPathComponent("Contents/Resources/rexmote-pane") }
}
