import AppKit
import ApplicationServices
import EdithKit
import Foundation

@MainActor
enum BifrostActionRunner {
    static func perform(
        _ action: BifrostAction, argument: String = "",
        defaults: UserDefaults = SharedDefaults.store
    ) async -> Bool {
        switch action {
        case .quicklink(let id): return quicklink(id, argument: argument, defaults: defaults)
        case .snippet(let id): return snippet(id, argument: argument, defaults: defaults)
        case .shell(let id): return await shell(id, argument: argument, defaults: defaults)
        case .shortcut(let name): return await BifrostShortcutsIndex.run(name: name)
        case .window(let windowAction): return BifrostWindowManager.perform(windowAction)
        case .system(let systemAction): return await system(systemAction)
        case .activate(let bundleID):
            return BifrostRunningApps.application(bundleID: bundleID)?.activate() ?? false
        case .quit(let bundleID):
            return BifrostRunningApps.application(bundleID: bundleID)?.terminate() ?? false
        case .focusWindow(let processID, let title):
            return BifrostWindowManager.focus(processID: processID, title: title)
        case .launch, .run, .copy:
            return false
        }
    }

    static func context(argument: String) -> BifrostPlaceholderContext {
        BifrostPlaceholderContext(
            query: argument, clipboard: NSPasteboard.general.string(forType: .string) ?? "")
    }

    private static func quicklink(
        _ id: String, argument: String, defaults: UserDefaults
    ) -> Bool {
        guard let link = BifrostLibraryStore.quicklink(id: id, in: defaults) else { return false }
        let target = link.resolved(context: context(argument: argument))
        guard !target.isEmpty else { return false }
        if target.hasPrefix("/") || target.hasPrefix("~") {
            let path = (target as NSString).expandingTildeInPath
            return NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        guard let url = URL(string: target) else { return false }
        guard let bundleID = link.openWithBundleID,
            let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return NSWorkspace.shared.open(url) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration)
        return true
    }

    private static func snippet(
        _ id: String, argument: String, defaults: UserDefaults
    ) -> Bool {
        guard let snippet = BifrostLibraryStore.snippet(id: id, in: defaults) else { return false }
        let text = snippet.resolved(context: context(argument: argument))
        guard !text.isEmpty else { return false }
        BifrostLauncher.copy(text: text)
        guard pastesSnippets(defaults), AXIsProcessTrusted() else { return true }
        ClipboardPasteSynth.synthesizeCommandV()
        return true
    }

    static func pastesSnippets(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: AppStorageKeys.Bifrost.pasteSnippets) as? Bool ?? true
    }

    private static func shell(
        _ id: String, argument: String, defaults: UserDefaults
    ) async -> Bool {
        guard let entry = BifrostLibraryStore.shellCommand(id: id, in: defaults) else {
            return false
        }
        let invocation = entry.resolved(context: context(argument: argument))
        guard !invocation.script.isEmpty else { return false }
        let outcome = await LocalMachineCommandExecution.run(
            invocation.script, environment: invocation.environment, timeout: 120)
        switch outcome {
        case .success(let text):
            guard entry.showsOutput else { return true }
            present(title: entry.name, message: text)
            return true
        case .failure(let error):
            present(title: entry.name, message: error.localizedDescription)
            return false
        }
    }

    private static func system(_ action: BifrostSystemAction) async -> Bool {
        guard !action.needsConfirmation || confirm(action) else { return false }
        return await BifrostSystemRunner.perform(action)
    }

    private static func confirm(_ action: BifrostSystemAction) -> Bool {
        let alert = NSAlert()
        alert.messageText = action.title
        alert.informativeText = action.subtitle
        alert.alertStyle = .warning
        alert.addButton(withTitle: action.title)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func present(title: String, message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(trimmed.prefix(2000))
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Done")
        NSApp.activate()
        _ = alert.runModal()
    }
}
