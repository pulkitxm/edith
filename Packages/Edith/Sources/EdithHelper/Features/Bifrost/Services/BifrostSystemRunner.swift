import AppKit
import EdithCore
import EdithKit
import Foundation

@MainActor
enum BifrostSystemRunner {
    static func perform(_ action: BifrostSystemAction) async -> Bool {
        switch action {
        case .quitAllApps: return quitEverything()
        case .toggleHiddenFiles: return await toggleHiddenFiles()
        default: break
        }
        if let script = appleScript(for: action) { return await runAppleScript(script) }
        guard let command = shellCommand(for: action) else { return false }
        let outcome = await LocalMachineCommandExecution.run(command, timeout: 20)
        switch outcome {
        case .success: return true
        case .failure: return false
        }
    }

    private static func shellCommand(for action: BifrostSystemAction) -> String? {
        switch action {
        case .lockScreen:
            "'/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession'"
                + " -suspend"
        case .sleepMac: "pmset sleepnow"
        case .sleepDisplays: "pmset displaysleepnow"
        case .startScreenSaver: "open -a ScreenSaverEngine"
        default: nil
        }
    }

    private static func appleScript(for action: BifrostSystemAction) -> String? {
        switch action {
        case .logOut: "tell application \"System Events\" to log out"
        case .restartMac: "tell application \"System Events\" to restart"
        case .shutDownMac: "tell application \"System Events\" to shut down"
        case .emptyTrash: "tell application \"Finder\" to empty trash"
        case .toggleAppearance:
            "tell application \"System Events\" to tell appearance preferences to set dark mode"
                + " to not dark mode"
        case .ejectAllDisks:
            "tell application \"Finder\" to eject (every disk whose ejectable is true)"
        default: nil
        }
    }

    private static func runAppleScript(_ source: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard let script = NSAppleScript(source: source) else { return false }
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            return error == nil
        }.value
    }

    private static func toggleHiddenFiles() async -> Bool {
        let command =
            "current=$(defaults read com.apple.finder AppleShowAllFiles 2>/dev/null || echo 0);"
            + " case \"$current\" in 1|YES|true) next=false;; *) next=true;; esac;"
            + " defaults write com.apple.finder AppleShowAllFiles -bool \"$next\";"
            + " killall Finder"
        let outcome = await LocalMachineCommandExecution.run(command, timeout: 20)
        switch outcome {
        case .success: return true
        case .failure: return false
        }
    }

    private static func quitEverything() -> Bool {
        let keep: Set<String> = [
            "com.apple.finder", Bundle.main.bundleIdentifier ?? "",
            AppBuildIdentity.application, AppBuildIdentity.helper,
        ]
        var quit = false
        for application in NSWorkspace.shared.runningApplications {
            guard application.activationPolicy == .regular,
                let identifier = application.bundleIdentifier, !keep.contains(identifier)
            else { continue }
            quit = application.terminate() || quit
        }
        return quit
    }
}
