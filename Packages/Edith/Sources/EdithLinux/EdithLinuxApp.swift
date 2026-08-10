import Adwaita
import EdithCore
import Foundation

@main
struct EdithLinuxApp: App {
    let id = "com.pulkit.Edith"
    var app: GTUIApp!

    static func main() {
        let directories = AppDirectories.current
        do {
            try directories.prepare()
            if CommandLine.arguments.contains("--diagnose") {
                try LinuxDiagnostics.write(directories: directories)
                return
            }
        } catch {
            FileHandle.standardError.write(Data("edith-linux: \(error)\n".utf8))
            exit(1)
        }
        setupApp().run()
    }

    var scene: Scene {
        Window(id: "main") { _ in
            MainWindowView()
        }
        .defaultSize(width: 1_040, height: 700)
        .title("Edith")
    }
}
