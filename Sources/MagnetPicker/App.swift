import SwiftUI

enum LaunchConfig {
    static var pendingFile: String?
    static var pendingURL: String?
    static var autoProbe = false
    static var ariaURL: String?
    static var ariaSecret: String?
    static var sendOnFinish = false

    static func parse(_ args: [String]) {
        if let index = args.firstIndex(of: "--load"), index + 1 < args.count {
            pendingFile = args[index + 1]
        }
        if let index = args.firstIndex(of: "--load-url"), index + 1 < args.count {
            pendingURL = args[index + 1]
        }
        autoProbe = args.contains("--autoprobe")
        if let index = args.firstIndex(of: "--aria-url"), index + 1 < args.count {
            ariaURL = args[index + 1]
        }
        if let index = args.firstIndex(of: "--aria-secret"), index + 1 < args.count {
            ariaSecret = args[index + 1]
        }
        sendOnFinish = args.contains("--send-top3")
    }
}

struct MagnetPickerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("磁力筛选器") {
            ContentView(model: model)
        }
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .saveItem) {
                Button("导出优选 txt") { model.exportTxt() }
                    .keyboardShortcut("s", modifiers: [.command])
                Button("复制全部优选") { model.copy(scope: .all) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            CommandMenu("探测") {
                Button("开始 / 重新探测") { model.startProbe() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("停止探测") { model.stopProbe() }
                    .keyboardShortcut(".", modifiers: [.command])
                Divider()
                Button("发送全部优选到 Aria") { model.sendToAria(.all) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}

@main
struct Launcher {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
            exit(0)
        }
        LaunchConfig.parse(CommandLine.arguments)
        MagnetPickerApp.main()
    }
}
