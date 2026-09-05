import AppKit
import EdithKit
import Observation
import SwiftUI

struct ClipboardHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @State private var model = ClipboardHistoryModel()
    @State private var filterText = ""
    private var entries: [ClipboardEntry] { model.entries }

    private var filtered: [ClipboardEntry] {
        ClipboardActions.arrange(entries, query: filterText)
    }

    private var summary: String {
        var parts = [entries.count == 1 ? "1 item" : "\(entries.count) items"]
        parts.append(
            Self.byteCountFormatter.string(fromByteCount: Int64(entries.reduce(0) { $0 + $1.size }))
        )
        let pinned = entries.filter(\.pinned).count
        if pinned > 0 { parts.append("\(pinned) pinned") }
        let shown = filtered.count
        if shown != entries.count { parts.append("\(shown) shown") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text("Clipboard History")
                        .font(.system(size: UIScale.pt(13), weight: .semibold))
                    Text(summary)
                        .settingsCaption()
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            if let error = model.error {
                Text(error).settingsCaption().foregroundStyle(.red).padding(.horizontal)
            }
            Divider()
            SearchField(placeholder: "Search…", text: $filterText, typeAhead: true)
                .padding(UIScale.pt(10))
            List(filtered) { entry in
                row(entry)
            }
            .listStyle(.inset)
        }
        .frame(width: UIScale.pt(480), height: UIScale.pt(520))
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        HStack(alignment: .top, spacing: UIScale.pt(10)) {
            ClipboardThumbnailView(entry: entry, maxHeight: entry.kind == .text ? 18 : 40) {
                Image(systemName: icon(for: entry.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: UIScale.pt(18))
            }
            .frame(minWidth: UIScale.pt(18))
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                if entry.kind != .image {
                    Text(entry.displayPreview).lineLimit(2)
                }
                HStack(spacing: UIScale.pt(4)) {
                    Text(entry.sourceApp ?? "Unknown")
                    Text("·")
                    Text(entry.createdAt.formatted(.relative(presentation: .named)))
                    Text("·")
                    Text(Self.byteCountFormatter.string(fromByteCount: Int64(entry.size)))
                }
                .settingsCaption()
            }
            Spacer()
            if model.copiedID == entry.id {
                Text("Copied").settingsCaption()
            }
            Button {
                model.copy(entry)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.edith(.borderless))
            Button {
                model.mutate(.init(entry.pinned ? .unpin : .pin, ids: [entry.id]))
            } label: {
                Image(systemName: entry.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(entry.pinned ? themeColor(themeName) : .secondary)
            }
            .buttonStyle(.edith(.borderless))
            Button(role: .destructive) {
                model.mutate(.init(.delete, ids: [entry.id]))
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.edith(.borderless))
        }
        .padding(.vertical, UIScale.pt(4))
    }

    private func icon(for kind: ClipboardEntry.Kind) -> String {
        switch kind {
        case .image: return "photo"
        case .file: return "doc"
        case .richText, .html: return "doc.richtext"
        case .text: return "doc.plaintext"
        case .document: return "doc.text"
        case .media: return "play.rectangle"
        case .data: return "externaldrive"
        }
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

@MainActor
@Observable
final class ClipboardHistoryModel {
    private(set) var entries: [ClipboardEntry] = []
    private(set) var error: String?
    private(set) var copiedID: String?
    var isSaving: Bool { !mutations.isEmpty }
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private nonisolated(unsafe) var refreshTask: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var mutations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private nonisolated(unsafe) var mutationTail: Task<Void, Never>?
    @ObservationIgnored private var mutationTailID: UUID?
    @ObservationIgnored private var pendingRefresh = false
    @ObservationIgnored private var generation = 0
    private let client: AgentClipboardClient
    @ObservationIgnored private var history = ClipboardHistoryProjection()

    init(client: AgentClipboardClient = .init()) { self.client = client }

    func start() {
        guard observer == nil else { return }
        generation += 1
        observer = IPC.observe(IPC.Name.clipboardChanged) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    func stop() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        for task in mutations.values { task.cancel() }
        mutations.removeAll()
        mutationTail?.cancel()
        mutationTail = nil
        mutationTailID = nil
        if let observer { IPC.stopObserving(observer) }
        observer = nil
    }

    func reload() {
        guard mutations.isEmpty else { pendingRefresh = true; return }
        guard refreshTask == nil else { pendingRefresh = true; return }
        let generation = generation
        refreshTask = Task { [weak self] in
            defer { if self?.generation == generation { self?.refreshTask = nil } }
            repeat {
                self?.pendingRefresh = false
                do {
                    guard let client = self?.client else { return }
                    let entries = try await client.entries()
                    guard !Task.isCancelled, self?.generation == generation else { return }
                    self?.history.replace(entries)
                    if let self, self.entries != self.history.entries {
                        self.entries = self.history.entries
                    }
                } catch {
                    guard !Task.isCancelled, self?.generation == generation else { return }
                    self?.error = error.localizedDescription
                }
            } while self?.pendingRefresh == true && !Task.isCancelled
        }
    }

    func mutate(_ mutation: ClipboardMutation) {
        guard mutations.count < 8 else {
            error = "Clipboard changes are still being saved."; return
        }
        run(mutation: mutation) { client in _ = try await client.mutate(mutation) }
    }

    func copy(_ entry: ClipboardEntry) {
        let plain = SharedDefaults.store.bool(forKey: AppStorageKeys.Clipboard.pastePlainText)
        run { [weak self] client in
            let payload = try await client.blob(id: entry.id)
            try Task.checkCancellation()
            ClipboardRepository.copyToPasteboard(
                payload.entry, data: payload.data, asPlainText: plain, pasteboard: .general)
            self?.copiedID = entry.id
            _ = try await client.mutate(.init(.copied, ids: [entry.id]))
        }
    }

    private func run(
        mutation: ClipboardMutation? = nil,
        _ action: @escaping @MainActor (AgentClipboardClient) async throws -> Void
    ) {
        guard mutations.count < 8 else {
            error = "Clipboard changes are still being saved."; return
        }
        let id = UUID()
        if let mutation { history.begin(id, mutation: mutation); entries = history.entries }
        let generation = generation
        let predecessor = mutationTail
        mutations[id] = Task { [weak self] in
            var succeeded = false
            defer {
                if let self {
                    self.history.finish(id, succeeded: succeeded)
                    self.entries = self.history.entries
                }
                self?.mutations[id] = nil
                if self?.mutationTailID == id {
                    self?.mutationTail = nil; self?.mutationTailID = nil
                }
                if self?.generation == generation, self?.mutations.isEmpty == true {
                    self?.reload()
                }
            }
            await predecessor?.value
            do {
                try Task.checkCancellation()
                guard let client = self?.client else { return }
                try await action(client)
                succeeded = true
                guard !Task.isCancelled, self?.generation == generation else { return }
                self?.error = nil
                self?.reload()
            } catch {
                if !Task.isCancelled, self?.generation == generation {
                    self?.error = error.localizedDescription; self?.reload()
                }
            }
        }
        mutationTail = mutations[id]
        mutationTailID = id
    }

    deinit {
        refreshTask?.cancel()
        mutationTail?.cancel()
        for task in mutations.values { task.cancel() }
    }
}
