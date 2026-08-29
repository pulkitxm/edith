import AppKit
import EdithCore
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
    private(set) var searchingFiles = false
    private(set) var copiedAnswer = false

    @ObservationIgnored weak var services: AppServices?
    @ObservationIgnored var dismiss: () -> Void = {}
    @ObservationIgnored var shortcutsChanged: () -> Void = {}
    @ObservationIgnored private var applications: [CommandBarApplication] = []
    @ObservationIgnored private var selection: CommandBarSelection?
    @ObservationIgnored private var applicationTask: Task<Void, Never>?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
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

    var hasFileScopes: Bool { !fileScopes.isEmpty }

    func prepare(frontmostPID: pid_t? = nil) {
        query = ""
        copiedAnswer = false
        selection = nil
        loadApplications()
        loadSelection(frontmostPID)
        refresh()
    }

    func close() {
        query = ""
        copiedAnswer = false
        applicationTask?.cancel()
        applicationTask = nil
        selectionTask?.cancel()
        selectionTask = nil
        searchWork?.cancel()
        searchWork = nil
        searchGeneration += 1
        loadingApplications = false
        searchingFiles = false
        selection = nil
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
            guard
                operationExists(
                    answer.kind == .calculation ? .calculate : .convert)
            else { return }
            copy(answer.formatted)
        case .action(let action):
            dismiss()
            DispatchQueue.main.async { [weak self] in self?.perform(action) }
        case .application(let application, let action):
            let chosen = reveal && action == .open ? CommandBarApplicationAction.reveal : action
            perform(application: application, action: chosen)
        case .file(let url):
            guard operationExists(AppInspectionOperation.openPath.descriptor) else { return }
            dismiss()
            if reveal {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(url)
            }
        case .systemSettings(let url):
            guard operationExists(AppInspectionOperation.openLink.descriptor) else { return }
            dismiss()
            NSWorkspace.shared.open(url)
        case .clipboard(let entry):
            guard UserOperationCatalog.descriptor(id: ClipboardOperation.copy.descriptor.id) != nil
            else { return }
            dismiss()
            services?.clipboard?.activate(entry)
        case .emoji(let emoji):
            guard operationExists(ColorSwatchOperation.copy.descriptor) else { return }
            copy(emoji)
        case .textUtility(let utility, let selection):
            guard operationExists(ClipboardOperation.copy.descriptor) else { return }
            let transformed = utility.transform(selection.text)
            if utility == .countWords {
                copy(transformed)
            } else {
                dismiss()
                NSRunningApplication(processIdentifier: selection.processIdentifier)?.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if !CommandBarSelectionAccess.replace(selection, with: transformed) {
                        NSSound.beep()
                    }
                }
            }
        }
    }

    func togglePin(_ item: CommandBarItem) {
        guard operationExists(ConfigurationOperation.set.descriptor) else { return }
        let next = CommandBarPreferences.togglingPin(item.id, in: pins)
        guard
            persist(
                CommandBarPreferences.encodeList(next),
                forKey: AppStorageKeys.CommandBar.pinnedResults)
        else { return }
        refresh()
    }

    func hide(_ item: CommandBarItem) {
        guard operationExists(ConfigurationOperation.set.descriptor) else { return }
        let next = CommandBarPreferences.togglingHidden(item.id, in: hidden)
        guard
            persist(
                CommandBarPreferences.encodeList(next.sorted()),
                forKey: AppStorageKeys.CommandBar.hiddenResults)
        else { return }
        refresh()
    }

    func assignShortcut(_ shortcut: CommandBarResultShortcut?, to item: CommandBarItem) {
        guard canAssignShortcut(item), operationExists(ConfigurationOperation.set.descriptor)
        else { return }
        let next = CommandBarPreferences.assigning(shortcut, to: item.id, in: shortcuts)
        guard let encoded = CommandBarPreferences.encodeShortcuts(next),
            persist(encoded, forKey: AppStorageKeys.CommandBar.resultShortcuts)
        else { return }
        shortcutsChanged()
        refresh()
    }

    func canAssignShortcut(_ item: CommandBarItem) -> Bool {
        switch item.kind {
        case .action, .application, .systemSettings, .emoji: true
        case .answer, .file, .clipboard, .textUtility: false
        }
    }

    func executeShortcut(id: String) {
        Task { [weak self] in
            guard let self else { return }
            guard !self.hidden.contains(id) else { return }
            if let current = self.items.first(where: { $0.id == id }) {
                self.execute(current)
                return
            }
            let applications = await Task.detached(priority: .userInitiated) {
                CommandBarApplicationCatalog.load()
            }.value
            let context = CommandBarProviderContext(
                query: "", applications: applications, clipboardEntries: [], selection: nil,
                fileScopes: [])
            var candidates = self.actionItems()
            candidates += await CommandBarApplicationProvider().results(for: context)
            candidates += await CommandBarSystemSettingsProvider().results(for: context)
            candidates += await CommandBarEmojiProvider().results(for: context)
            guard let item = candidates.first(where: { $0.id == id }) else { return }
            self.execute(item)
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

    private func loadSelection(_ processIdentifier: pid_t?) {
        selectionTask?.cancel()
        selectionTask = Task.detached(priority: .userInitiated) {
            let selection = CommandBarSelectionAccess.read(processIdentifier: processIdentifier)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.selection = selection
                self?.selectionTask = nil
                self?.refresh()
            }
        }
    }

    private func refresh() {
        searchWork?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let answer = answerItem()
        let query = query
        let providers = activeProviders
        let context = CommandBarProviderContext(
            query: query, applications: showsApplications ? applications : [],
            clipboardEntries: services?.clipboard?.entries ?? [], selection: selection,
            fileScopes: fileScopes)
        let actions = actionItems()
        let usage = learnsRanking ? usage : CommandBarUsage()
        let pins = pins
        let hidden = hidden
        let shortcuts = shortcuts
        searchingFiles =
            !fileScopes.isEmpty
            && CommandBarFileSearchSupport.expression(for: query) != nil
        var immediate = actions.filter { !hidden.contains($0.id) }
        for index in immediate.indices {
            immediate[index].pinned = pins.contains(immediate[index].id)
            immediate[index].shortcutLabel = shortcuts[immediate[index].id]?.label
        }
        let immediateByID = Dictionary(
            immediate.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var immediateRanked = CommandBarSearch.rank(
            immediate.map(\.candidate), query: query, usage: usage, limit: 16
        ).compactMap { immediateByID[$0.id] }
        if let answer { immediateRanked.insert(answer, at: 0) }
        items = immediateRanked
        selectedIndex = 0
        searchWork = Task { [weak self] in
            var provided: [CommandBarItem] = []
            await withTaskGroup(of: [CommandBarItem].self) { group in
                for provider in providers {
                    group.addTask { await provider.results(for: context) }
                }
                for await result in group where !Task.isCancelled {
                    provided.append(contentsOf: result)
                }
            }
            guard !Task.isCancelled else { return }
            var all = actions + provided
            if let answer { all.append(answer) }
            all = all.filter { !hidden.contains($0.id) }
            for index in all.indices {
                all[index].pinned = pins.contains(all[index].id)
                all[index].shortcutLabel = shortcuts[all[index].id]?.label
            }
            let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let candidates = all.map(\.candidate)
            let rankedIDs = await Task.detached(priority: .userInitiated) {
                CommandBarSearch.rank(candidates, query: query, usage: usage, limit: 20).map(\.id)
            }.value
            guard let self, generation == self.searchGeneration, !Task.isCancelled else { return }
            var ranked = rankedIDs.compactMap { byID[$0] }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let leading = pins.compactMap { byID[$0] }
                let leadingIDs = Set(leading.map(\.id))
                ranked = leading + ranked.filter { !leadingIDs.contains($0.id) }
            }
            if let answer {
                ranked.removeAll { $0.id == answer.id }
                ranked.insert(answer, at: 0)
            }
            if ranked.count > 16 { ranked.removeSubrange(16...) }
            self.items = ranked
            self.selectedIndex = min(self.selectedIndex, max(0, ranked.count - 1))
            self.searchingFiles = false
            self.searchWork = nil
        }
    }

    private var activeProviders: [any CommandBarProvider] {
        var providers: [any CommandBarProvider] = [
            CommandBarSystemSettingsProvider(), CommandBarEmojiProvider(), CommandBarFileProvider(),
        ]
        if showsApplications { providers.append(CommandBarApplicationProvider()) }
        if services?.clipboard != nil { providers.append(CommandBarClipboardProvider()) }
        if selection != nil { providers.append(CommandBarTextUtilityProvider()) }
        return providers
    }

    private func answerItem() -> CommandBarItem? {
        guard let answer = CommandBarEvaluator.evaluate(query) else { return nil }
        return CommandBarItem(
            id: "answer.\(answer.kind.rawValue)", title: answer.formatted,
            subtitle: answer.kind == .calculation
                ? "Calculation, Return copies" : "Conversion, Return copies",
            symbolName: answer.kind == .calculation
                ? "equal.square.fill" : "arrow.left.arrow.right.square.fill",
            keywords: ["calculate", "convert", "copy"], sourceBias: 100,
            kind: .answer(answer))
    }

    private func actionItems() -> [CommandBarItem] {
        var items = [
            action(.openHome, "Open Edith", "Home", "house.fill", ["dashboard", "edith"]),
            action(
                .openExtensions, "Open Extensions", "Manage Edith features",
                "puzzlepiece.extension.fill", ["features", "plugins", "manage"]),
            action(
                .openGeneralSettings, "Open Settings", "General settings", "gearshape.fill",
                ["preferences", "configure"]),
            action(
                .openShortcuts, "Open Shortcuts", "Record global shortcuts", "keyboard.fill",
                ["hotkey", "keyboard", "keys"]),
            action(
                .openPermissions, "Open Permissions", "Review macOS access", "hand.raised.fill",
                ["privacy", "access", "macos"]),
            action(
                .openCommandBarSettings, "Command Bar Settings",
                "Folders, shortcuts, results, and ranking", "command",
                ["palette", "configure", "ranking", "files"]),
        ]
        let destinations: [(String, CommandBarActionID, String, String, String, [String])] = [
            (
                AppStorageKeys.Tabs.attentionEnabled, .openAttention, "Open Attention",
                "Activity and focus", "hourglass", ["focus", "activity", "time"]
            ),
            (
                AppStorageKeys.Tabs.usageEnabled, .openUsage, "Open Agent Usage",
                "Limits, tokens, and cost", "chart.bar.fill", ["limits", "tokens", "cost"]
            ),
            (
                AppStorageKeys.Tabs.herdrEnabled, .openHerdr, "Open Herdr", "Live agent sessions",
                "rectangle.split.3x1.fill", ["agents", "sessions"]
            ),
            (
                AppStorageKeys.Tabs.quinjetEnabled, .openQuinjet, "Open Quinjet",
                "Review workspaces", "arrow.triangle.branch", ["review", "pull request"]
            ),
            (
                AppStorageKeys.Tabs.musicEnabled, .openMusic, "Open Music", "Local music library",
                "music.note", ["songs", "player", "library"]
            ),
            (
                AppStorageKeys.Tabs.calendarEnabled, .openCalendar, "Open Calendar",
                "Schedule and events", "calendar", ["events", "schedule", "agenda"]
            ),
            (
                AppStorageKeys.Tabs.systemEnabled, .openSystem, "Open System",
                "Apps, sleep, and controls", "cpu", ["apps", "sleep", "clean keyboard"]
            ),
            (
                AppStorageKeys.Tabs.machinesEnabled, .openMachines, "Open Machines",
                "SSH computers and files", "server.rack", ["ssh", "servers", "remote"]
            ),
            (
                AppStorageKeys.Tabs.companionEnabled, .openCompanion, "Open Companion",
                "Notes, voice, and memory", "brain.head.profile", ["memory", "notes", "voice"]
            ),
        ]
        for destination in destinations where enabled(destination.0) {
            items.append(
                action(
                    destination.1, destination.2, destination.3, destination.4, destination.5))
        }
        if services?.clipboard != nil {
            items.append(
                action(
                    .clipboard, "Open Clipboard History", "Search recent copies",
                    "doc.on.clipboard.fill", ["history", "paste", "copied"]))
        }
        if services?.colorPicker != nil {
            items.append(
                action(
                    .colorPicker, "Pick a Color", "Copy the sampled color", "eyedropper",
                    ["sample", "hex"]))
        }
        if services?.micMute != nil {
            let subtitle =
                services?.micMute?.muted == true ? "Microphone is muted" : "Microphone is live"
            items.append(
                action(
                    .micMute, "Toggle Microphone Mute", subtitle, "mic.slash.fill",
                    ["microphone", "audio", "toggle"]))
        }
        if services?.focusDim != nil {
            items.append(
                action(
                    .focusDim, "Toggle Focus Dim", "Dim background windows",
                    "circle.lefthalf.filled", ["dimming", "focus", "toggle"]))
        }
        return items
    }

    private func action(
        _ id: CommandBarActionID, _ title: String, _ subtitle: String, _ symbol: String,
        _ keywords: [String]
    ) -> CommandBarItem {
        CommandBarItem(
            id: "action.\(id.rawValue)", title: title, subtitle: subtitle,
            symbolName: symbol, keywords: keywords, sourceBias: 10, kind: .action(id))
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

    private func perform(
        application: CommandBarApplication, action: CommandBarApplicationAction
    ) {
        switch action {
        case .open:
            dismiss()
            NSWorkspace.shared.openApplication(
                at: application.url, configuration: NSWorkspace.OpenConfiguration())
        case .reveal:
            guard operationExists(AppInspectionOperation.openPath.descriptor) else { return }
            dismiss()
            NSWorkspace.shared.activateFileViewerSelecting([application.url])
        case .quit, .relaunch:
            guard let pid = application.runningPID,
                UserOperationCatalog.descriptor(id: RunningAppOperation.quit.descriptor.id) != nil,
                confirm("\(action == .quit ? "Quit" : "Relaunch") \(application.title)?")
            else { return }
            let running = NSRunningApplication(processIdentifier: pid)
            let center = RunningAppOperationCenter()
            guard let plan = try? center.plan(.pid(pid)) else { return }
            dismiss()
            _ = center.apply(plan, confirmed: true)
            if action == .relaunch { relaunch(application, after: running) }
        }
    }

    private func relaunch(
        _ application: CommandBarApplication, after running: NSRunningApplication?
    ) {
        Task { @MainActor in
            for _ in 0..<20 where running?.isTerminated == false {
                try? await Task.sleep(for: .milliseconds(150))
            }
            _ = try? await NSWorkspace.shared.openApplication(
                at: application.url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func confirm(_ title: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "The application can still ask to save unsaved work."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        copiedAnswer = NSPasteboard.general.setString(value, forType: .string)
        dismiss()
    }

    private func operationExists(_ operation: CommandBarOperation) -> Bool {
        operationExists(operation.descriptor)
    }

    private func operationExists(_ descriptor: UserOperationDescriptor) -> Bool {
        UserOperationCatalog.descriptor(id: descriptor.id) != nil
    }

    private func persist(_ value: String, forKey key: String) -> Bool {
        do {
            try ConfigurationExecutor.application.set(.string(value), forKey: key)
            return true
        } catch {
            NSSound.beep()
            return false
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

    private var pins: [String] {
        CommandBarPreferences.decodeList(
            SharedDefaults.store.string(forKey: AppStorageKeys.CommandBar.pinnedResults))
    }

    private var hidden: Set<String> {
        CommandBarPreferences.decodeSet(
            SharedDefaults.store.string(forKey: AppStorageKeys.CommandBar.hiddenResults))
    }

    private var shortcuts: [String: CommandBarResultShortcut] {
        CommandBarPreferences.decodeShortcuts(
            SharedDefaults.store.string(forKey: AppStorageKeys.CommandBar.resultShortcuts))
    }

    private var fileScopes: [String] {
        CommandBarFileSearchSupport.resolvedScopes(
            CommandBarPreferences.decodeList(
                SharedDefaults.store.string(forKey: AppStorageKeys.CommandBar.fileScopes)),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            isSearchableDirectory: { path in
                var directory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                    && directory.boolValue
            })
    }
}
