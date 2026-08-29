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

    init() {
        reload()
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
        do {
            document = try ScratchpadRepository.load(retention: retention)
            failure = nil
            scheduleRetention()
        } catch {
            failure = error.localizedDescription
        }
    }

    func select(_ id: UUID) {
        flushSave()
        do {
            document = try ScratchpadRepository.select(id.uuidString)
            previewing = false
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    func create() {
        flushSave()
        do {
            document = try ScratchpadRepository.create()
            query = ""
            previewing = false
            failure = nil
            announceChange()
        } catch {
            failure = error.localizedDescription
        }
    }

    func renameSelected(to name: String) {
        guard let selectedPad else { return }
        flushSave()
        do {
            document = try ScratchpadRepository.rename(selectedPad.id.uuidString, to: name)
            failure = nil
            announceChange()
        } catch {
            failure = error.localizedDescription
        }
    }

    func duplicateSelected() {
        guard let selectedPad else { return }
        flushSave()
        do {
            document = try ScratchpadRepository.duplicate(selectedPad.id.uuidString)
            query = ""
            previewing = false
            failure = nil
            announceChange()
        } catch {
            failure = error.localizedDescription
        }
    }

    func removeSelected() {
        guard let selectedPad else { return }
        flushSave()
        do {
            document = try ScratchpadRepository.remove(selectedPad.id.uuidString)
            previewing = false
            failure = nil
            announceChange()
        } catch {
            failure = error.localizedDescription
        }
    }

    func clearSelected() {
        guard let selectedPad else { return }
        saveTask?.cancel()
        saveTask = nil
        do {
            document = try ScratchpadRepository.clear(selectedPad.id.uuidString)
            savePending = false
            outcome = "Cleared"
            failure = nil
            announceChange()
        } catch {
            failure = error.localizedDescription
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
        do {
            document = try ScratchpadRepository.update(
                selectedPad.id.uuidString, text: selectedPad.text,
                now: selectedPad.modifiedAt ?? Date())
            savePending = false
            failure = nil
            announceChange()
            scheduleRetention()
        } catch {
            failure = error.localizedDescription
        }
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
        guard let expiry = document.nextExpiry(for: retention) else { return }
        retentionTimer = Timer.scheduledTimer(
            withTimeInterval: max(1, expiry.timeIntervalSinceNow + 0.1), repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    private func announceChange() {
        IPC.post(IPC.Name.scratchpadChanged)
    }

    private func safeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        return String(mapped).replacingOccurrences(of: "--", with: "-").lowercased()
    }
}
