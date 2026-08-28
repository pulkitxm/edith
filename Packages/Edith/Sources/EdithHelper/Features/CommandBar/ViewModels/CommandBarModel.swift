import AppKit
import EdithKit
import Foundation
import Observation

@MainActor
@Observable
final class CommandBarModel {
    var query = "" {
        didSet {
            selectedIndex = 0
            refresh()
        }
    }
    private(set) var items: [CommandBarItem] = []
    var selectedIndex = 0
    private(set) var loadingApplications = false
    private(set) var copiedAnswer = false

    @ObservationIgnored weak var services: AppServices?
    @ObservationIgnored var dismiss: () -> Void = {}
    @ObservationIgnored private var applications: [CommandBarApplication] = []
    @ObservationIgnored private var applicationTask: Task<Void, Never>?
    @ObservationIgnored private var searchWork: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var usage = CommandBarUsage()

    init(services: AppServices) {
        self.services = services
        usage = Self.loadUsage()
        refresh()
    }

    var selectedItem: CommandBarItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    func prepare() {
        query = ""
        copiedAnswer = false
        loadApplications()
        refresh()
    }

    func close() {
        query = ""
        copiedAnswer = false
        applicationTask?.cancel()
        applicationTask = nil
        searchWork?.cancel()
        searchWork = nil
        searchGeneration += 1
        loadingApplications = false
    }

    func shutdown() {
        close()
        applications.removeAll()
        items.removeAll()
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), items.count - 1)
    }

    func select(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        selectedIndex = index
    }

    func executeSelected(reveal: Bool = false) {
        guard let item = selectedItem else { return }
        execute(item, reveal: reveal)
    }

    func execute(_ item: CommandBarItem, reveal: Bool = false) {
        remember(item.id)
        switch item.kind {
        case .answer(let answer):
            NSPasteboard.general.clearContents()
            copiedAnswer = NSPasteboard.general.setString(answer.formatted, forType: .string)
            dismiss()
        case .application(let application):
            dismiss()
            if reveal {
                NSWorkspace.shared.activateFileViewerSelecting([application.url])
            } else {
                NSWorkspace.shared.openApplication(
                    at: application.url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .action(let action):
            dismiss()
            DispatchQueue.main.async { [weak self] in self?.perform(action) }
        }
    }

    private func loadApplications() {
        guard applicationTask == nil else { return }
        loadingApplications = true
        applicationTask = Task.detached(priority: .utility) {
            let applications = CommandBarApplicationCatalog.load()
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.applications = applications
                self?.loadingApplications = false
                self?.applicationTask = nil
                self?.refresh()
            }
        }
    }

    private func refresh() {
        searchWork?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let base = actionItems() + applicationItems()
        let byID = Self.indexed(items: base)
        let candidates = Self.candidates(in: base)
        let ranking = learnsRanking ? usage : CommandBarUsage()
        let query = query
        let answerItem: CommandBarItem?
        if let answer = CommandBarEvaluator.evaluate(query) {
            answerItem = CommandBarItem(
                id: "answer.\(answer.kind.rawValue)", title: answer.formatted,
                subtitle: answer.kind == .calculation
                    ? "Calculation, Return copies" : "Conversion, Return copies",
                symbolName: answer.kind == .calculation
                    ? "equal.square.fill" : "arrow.left.arrow.right.square.fill",
                kind: .answer(answer))
        } else {
            answerItem = nil
        }
        if let answerItem {
            items = [answerItem]
        } else {
            items = []
        }
        selectedIndex = 0
        searchWork = Task { [weak self] in
            let rankingTask = Task.detached(priority: .userInitiated) {
                CommandBarSearch.rank(
                    candidates, query: query, usage: ranking, limit: 12
                ).map(\.id)
            }
            let rankedIDs = await withTaskCancellationHandler {
                await rankingTask.value
            } onCancel: {
                rankingTask.cancel()
            }
            guard let self, generation == self.searchGeneration, !Task.isCancelled else { return }
            var ranked: [CommandBarItem] = []
            for id in rankedIDs {
                guard let item = byID[id] else { continue }
                ranked.append(item)
            }
            if let answerItem { ranked.insert(answerItem, at: 0) }
            if ranked.count > 12 { ranked.removeLast() }
            self.items = ranked
            self.selectedIndex = min(self.selectedIndex, max(0, ranked.count - 1))
            self.searchWork = nil
        }
    }

    private nonisolated static func indexed(
        items: [CommandBarItem]
    ) -> [String: CommandBarItem] {
        var result: [String: CommandBarItem] = [:]
        for item in items { result[item.id] = item }
        return result
    }

    private nonisolated static func candidates(
        in items: [CommandBarItem]
    ) -> [CommandBarCandidate] {
        items.map(\.candidate)
    }

    private func applicationItems() -> [CommandBarItem] {
        guard showsApplications else { return [] }
        return applications.map { application in
            CommandBarItem(
                id: application.id, title: application.title, subtitle: application.subtitle,
                symbolName: "app.fill", kind: .application(application))
        }
    }

    private func actionItems() -> [CommandBarItem] {
        var items = [
            action(.openHome, "Open Edith", "Home", "house.fill"),
            action(
                .openExtensions, "Open Extensions", "Manage Edith features",
                "puzzlepiece.extension.fill"),
            action(.openGeneralSettings, "Open Settings", "General settings", "gearshape.fill"),
            action(.openShortcuts, "Open Shortcuts", "Record global shortcuts", "keyboard.fill"),
            action(.openPermissions, "Open Permissions", "Review macOS access", "hand.raised.fill"),
            action(
                .openCommandBarSettings, "Command Bar Settings",
                "Shortcut, app results, and ranking", "command"),
        ]
        let destinations: [(String, CommandBarActionID, String, String, String)] = [
            (
                AppStorageKeys.Tabs.attentionEnabled, .openAttention, "Open Attention",
                "Activity and focus", "hourglass"
            ),
            (
                AppStorageKeys.Tabs.usageEnabled, .openUsage, "Open Agent Usage",
                "Limits, tokens, and cost", "chart.bar.fill"
            ),
            (
                AppStorageKeys.Tabs.herdrEnabled, .openHerdr, "Open Herdr", "Live agent sessions",
                "rectangle.split.3x1.fill"
            ),
            (
                AppStorageKeys.Tabs.quinjetEnabled, .openQuinjet, "Open Quinjet",
                "Review workspaces", "arrow.triangle.branch"
            ),
            (
                AppStorageKeys.Tabs.musicEnabled, .openMusic, "Open Music", "Local music library",
                "music.note"
            ),
            (
                AppStorageKeys.Tabs.calendarEnabled, .openCalendar, "Open Calendar",
                "Schedule and events", "calendar"
            ),
            (
                AppStorageKeys.Tabs.systemEnabled, .openSystem, "Open System",
                "Apps, sleep, and controls", "cpu"
            ),
            (
                AppStorageKeys.Tabs.machinesEnabled, .openMachines, "Open Machines",
                "SSH computers and files", "server.rack"
            ),
            (
                AppStorageKeys.Tabs.companionEnabled, .openCompanion, "Open Companion",
                "Notes, voice, and memory", "brain.head.profile"
            ),
        ]
        for destination in destinations where enabled(destination.0) {
            items.append(action(destination.1, destination.2, destination.3, destination.4))
        }
        if services?.clipboard != nil {
            items.append(
                action(
                    .clipboard, "Open Clipboard History", "Search recent copies",
                    "doc.on.clipboard.fill"))
        }
        if services?.colorPicker != nil {
            items.append(
                action(.colorPicker, "Pick a Color", "Copy the sampled color", "eyedropper"))
        }
        if services?.micMute != nil {
            let subtitle =
                services?.micMute?.muted == true ? "Microphone is muted" : "Microphone is live"
            items.append(action(.micMute, "Toggle Microphone Mute", subtitle, "mic.slash.fill"))
        }
        if services?.focusDim != nil {
            items.append(
                action(
                    .focusDim, "Toggle Focus Dim", "Dim background windows",
                    "circle.lefthalf.filled"))
        }
        return items
    }

    private func action(
        _ id: CommandBarActionID, _ title: String, _ subtitle: String, _ symbol: String
    ) -> CommandBarItem {
        CommandBarItem(
            id: "action.\(id.rawValue)", title: title, subtitle: subtitle,
            symbolName: symbol, kind: .action(id))
    }

    private func perform(_ action: CommandBarActionID) {
        switch action {
        case .openHome: MainApp.open(section: "home")
        case .openExtensions: MainApp.open(section: "extensions")
        case .openGeneralSettings: MainApp.openSettings(tab: "general")
        case .openShortcuts: MainApp.openSettings(tab: "shortcuts")
        case .openPermissions: MainApp.openSettings(tab: "permissions")
        case .openAttention: MainApp.open(section: "attention")
        case .openUsage: MainApp.open(section: "dashboard")
        case .openHerdr: MainApp.open(section: "herdr")
        case .openQuinjet: MainApp.open(section: "quinjet")
        case .openMusic: MainApp.open(section: "music")
        case .openCalendar: MainApp.open(section: "calendar")
        case .openSystem: MainApp.open(section: "system")
        case .openMachines: MainApp.open(section: "machines")
        case .openCompanion: MainApp.open(section: "companion")
        case .openCommandBarSettings: openExtension("commandBar")
        case .clipboard: ClipboardPanel.shared.show()
        case .colorPicker: services?.colorPicker?.pick()
        case .micMute: services?.micMute?.toggle()
        case .focusDim: toggleFocusDim()
        }
    }

    private func openExtension(_ id: String) {
        SharedDefaults.store.set(id, forKey: AppStorageKeys.General.extensionsExpand)
        MainApp.open(section: "extensions")
    }

    private func remember(_ id: String) {
        guard learnsRanking else { return }
        usage.record(id)
        guard let data = try? JSONEncoder().encode(usage),
            let value = String(data: data, encoding: .utf8)
        else { return }
        SharedDefaults.store.set(value, forKey: AppStorageKeys.CommandBar.usage)
    }

    private static func loadUsage() -> CommandBarUsage {
        guard let raw = SharedDefaults.store.string(forKey: AppStorageKeys.CommandBar.usage),
            let data = raw.data(using: .utf8),
            let usage = try? JSONDecoder().decode(CommandBarUsage.self, from: data)
        else { return CommandBarUsage() }
        return usage
    }

    private func enabled(_ key: String) -> Bool {
        SharedDefaults.store.bool(forKey: key)
    }

    private var showsApplications: Bool {
        SharedDefaults.store.object(forKey: AppStorageKeys.CommandBar.showApplications) as? Bool
            ?? true
    }

    private var learnsRanking: Bool {
        SharedDefaults.store.object(forKey: AppStorageKeys.CommandBar.learnRanking) as? Bool ?? true
    }
}
