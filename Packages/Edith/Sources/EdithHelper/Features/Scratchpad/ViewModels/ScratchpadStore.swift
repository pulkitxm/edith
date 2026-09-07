import AppKit
import EdithKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class ScratchpadStore {
    private(set) var document = ScratchpadDocument.initial()
    private(set) var savePending = false
    private(set) var outcome: String?
    private(set) var failure: String?
    private(set) var remembering = false
    var previewing = false
    var query = ""

    private var saveTask: Task<Void, Never>?
    private var retentionTimer: Timer?
    private var operationTail: Task<Void, Never>?
    private var operationID = UUID()
    private var editRevision = 0
    private var stopped = false
    private(set) var ready = false
    private(set) var selectionChanges = 0

    init() {
        reload()
    }

    init(document: ScratchpadDocument) {
        self.document = document
        ready = true
    }

    var selectedPad: ScratchpadPad? {
        document.selectedPad
    }

    var selectedText: String {
        get { selectedPad?.text ?? "" }
        set {
            guard let index = document.pads.firstIndex(where: { $0.id == document.selectedID }),
                document.pads[index].text != newValue
            else { return }
            editRevision += 1
            document.pads[index].text = newValue
            document.pads[index].modifiedAt = newValue.isEmpty ? nil : Date()
            scheduleSave()
        }
    }

    var searchResults: [ScratchpadSearchResult] {
        ScratchpadRepository.search(query, in: document)
    }

    var companionEnabled: Bool {
        SharedDefaults.store.bool(forKey: AppStorageKeys.Tabs.companionEnabled)
    }

    func reload() {
        flushSave()
        let retention = retention
        enqueue { try await AgentScratchpadClient.load(retention: retention) }
    }

    func select(_ id: UUID) {
        flushSave()
        previewing = false
        enqueue(changesSelection: true) { try await AgentScratchpadClient.select(id.uuidString) }
    }

    func create() {
        flushSave()
        query = ""
        previewing = false
        enqueue(changesSelection: true) { try await AgentScratchpadClient.create() }
    }

    func renameSelected(to name: String) {
        guard let selectedPad else { return }
        flushSave()
        enqueue { try await AgentScratchpadClient.rename(selectedPad.id.uuidString, to: name) }
    }

    func duplicateSelected() {
        guard let selectedPad else { return }
        flushSave()
        query = ""
        previewing = false
        enqueue(changesSelection: true) {
            try await AgentScratchpadClient.duplicate(selectedPad.id.uuidString)
        }
    }

    func removeSelected() {
        guard let selectedPad else { return }
        flushSave()
        previewing = false
        enqueue(changesSelection: true) {
            try await AgentScratchpadClient.remove(selectedPad.id.uuidString)
        }
    }

    func clearSelected() {
        guard let selectedPad else { return }
        saveTask?.cancel()
        saveTask = nil
        savePending = false
        editRevision += 1
        if let index = document.pads.firstIndex(where: { $0.id == selectedPad.id }) {
            document.pads[index].text = ""
            document.pads[index].modifiedAt = nil
        }
        enqueue { try await AgentScratchpadClient.clear(selectedPad.id.uuidString) }
    }

    private func enqueue(
        changesSelection: Bool = false,
        _ operation: @escaping @MainActor () async throws -> ScratchpadDocument
    ) {
        if changesSelection { selectionChanges += 1 }
        let previous = operationTail
        let id = UUID()
        operationID = id
        let revision = editRevision
        operationTail = Task { [self] in
            await previous?.value
            defer {
                if changesSelection { selectionChanges -= 1 }
                if operationID == id { operationTail = nil }
            }
            do {
                var updated = try await operation()
                if revision != editRevision, let current = selectedPad,
                    let index = updated.pads.firstIndex(where: { $0.id == current.id })
                {
                    updated.pads[index].text = current.text
                    updated.pads[index].modifiedAt = current.modifiedAt
                    if savePending { updated.selectedID = current.id }
                }
                document = updated
                ready = true
                failure = nil
                scheduleRetention()
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    func copyAll() {
        guard let selectedPad else { return }
        do {
            let text = try ScratchpadRepository.copyAllText(selectedPad)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            outcome = "Copied"
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    func exportSelected() {
        guard let selectedPad else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(safeFileName(selectedPad.name)).md"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ScratchpadRepository.export(selectedPad, to: url)
            outcome = "Exported \(url.lastPathComponent)"
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    func rememberSelected() async {
        guard companionEnabled, let selectedPad, !remembering else { return }
        let text = selectedPad.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            failure = ScratchpadError.emptyPad.localizedDescription
            return
        }
        remembering = true
        defer { remembering = false }
        do {
            let mtime = ISO8601DateFormatter().string(from: selectedPad.modifiedAt ?? Date())
            let file = CompanionIngestFile(
                name: "scratchpad-\(safeFileName(selectedPad.name)).md", text: text,
                mtime: mtime)
            let response = try await CompanionClient(
                baseURL: CompanionClient.endpoint(override: nil)
            ).ingest(files: [file])
            outcome =
                response.first?.status == "ingested"
                ? "Remembered in Companion" : "Already remembered"
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    func flushSave() {
        guard savePending, let selectedPad else { return }
        saveTask?.cancel()
        saveTask = nil
        savePending = false
        enqueue {
            do {
                return try await AgentScratchpadClient.update(
                    selectedPad.id.uuidString, text: selectedPad.text,
                    now: selectedPad.modifiedAt ?? Date())
            } catch {
                self.savePending = true
                throw error
            }
        }
    }

    func shutdown() {
        stopped = true
        flushSave()
        retentionTimer?.invalidate()
        retentionTimer = nil
    }

    func waitForWrites() async {
        await operationTail?.value
    }

    func clearMessage() {
        outcome = nil
        failure = nil
    }

    private var retention: ScratchpadRetention {
        ScratchpadRetention.resolved(
            SharedDefaults.store.string(forKey: AppStorageKeys.Scratchpad.retention))
    }

    private func scheduleSave() {
        savePending = true
        outcome = nil
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            self?.flushSave()
        }
    }

    private func scheduleRetention() {
        retentionTimer?.invalidate()
        guard !stopped, let expiry = document.nextExpiry(for: retention) else { return }
        retentionTimer = Timer.scheduledTimer(
            withTimeInterval: max(1, expiry.timeIntervalSinceNow + 0.1), repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    private func safeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        return String(mapped).replacingOccurrences(of: "--", with: "-").lowercased()
    }
}
