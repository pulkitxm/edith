import AppKit
import EdithHostCore
import EdithExtensionUI
import EdithExtensionSupport
import SwiftUI

@main
enum HostEntry {
    @MainActor static func main() { runHost() }

    @MainActor static func runHost() {
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if ProcessInfo.processInfo.environment["EDITH_CLI"] == "1"
            || (!arguments.isEmpty && !arguments[0].hasPrefix("--extension-")
                && !arguments[0].hasPrefix("--contained-extension-"))
        {
            HostCommandCLI.main(arguments: arguments)
        }
        do { if try HostContainedRole.run(arguments: arguments) { return } } catch {
            FileHandle.standardError.write(
                Data("The contained extension could not start: \(error).\n".utf8))
            exit(1)
        }
        guard
            HostContract.permitsLaunching(
                identifier: Bundle.main.bundleIdentifier, bundleURL: Bundle.main.bundleURL)
        else {
            FileHandle.standardError.write(
                Data("Install Edith in /Applications before starting the release app.\n".utf8))
            let interactive =
                !(arguments.first?.hasPrefix("--") ?? false)
                && ProcessInfo.processInfo.environment["EDITH_CLI"] != "1"
            if interactive {
                MainActor.assumeIsolated { HostInstallLocationAlert.refuse() }
            }
            exit(1)
        }
        if arguments.count == 2,
            ["--extension-carrier-worker", "--extension-privileged-fixture"].contains(arguments[0])
        {
            do {
                try HostPrivilegedWorker(
                    bundle: URL(fileURLWithPath: arguments[1]),
                    fixture: arguments[0] == "--extension-privileged-fixture"
                ).run()
            } catch { exit(1) }
            return
        }
        if arguments == ["--extension-carrier"] {
            do { try HostPrivilegedCarrier(approved: true).run() } catch { exit(1) }
            return
        }
        if arguments.count == 2, arguments[0] == "--extension-native-task" {
            do { exit(try HostNativeTask.run(encoded: arguments[1])) } catch {
                FileHandle.standardError.write(
                    Data("The installed extension task could not start.\n".utf8))
                exit(1)
            }
        }
        if arguments == ["--extension-command"] {
            do { try ExtensionCommandSpecification.runWrapper() } catch { exit(1) }
        }
        guard arguments.isEmpty else { HostCommandCLI.main(arguments: arguments) }
        HostApplication.main()
    }
}
