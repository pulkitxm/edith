import SwiftUI

@MainActor
final class CleanerModel: ObservableObject {
    @Published private(set) var categories: [JunkCategory] = []
    @Published private(set) var scanning = false
    @Published private(set) var scanned = false
    @Published private(set) var lastReclaimed: Int64 = 0

    var selectedTotal: Int64 {
        categories.filter(\.selected).reduce(0) { $0 + $1.sizeBytes }
    }
    var reclaimableTotal: Int64 {
        categories.reduce(0) { $0 + $1.sizeBytes }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            let result = await Task.detached { JunkScanner.scan() }.value
            categories = result
            scanning = false
            scanned = true
        }
    }

    func toggle(_ id: String) {
        guard let index = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[index].selected.toggle()
    }

    func clean() {
        let selected = categories.filter(\.selected)
        guard !selected.isEmpty else { return }
        scanning = true
        Task {
            let reclaimed = await Task.detached { JunkScanner.clean(selected) }.value
            lastReclaimed = reclaimed
            let result = await Task.detached { JunkScanner.scan() }.value
            categories = result
            scanning = false
        }
    }
}

struct CleanerCard: View {
    let dark: Bool
    @StateObject private var model = CleanerModel()

    var body: some View {
        SkinCard(title: "Reclaim developer space", dark: dark) {
            VStack(alignment: .leading, spacing: 12) {
                if !model.scanned {
                    HStack {
                        Text("Scan build caches, package managers, and Claude Code logs.")
                            .font(.system(size: 12)).foregroundStyle(DashSkin.inkFaint(dark))
                        Spacer()
                        Button(model.scanning ? "Scanning…" : "Scan") { model.scan() }
                            .disabled(model.scanning).pointerCursor()
                    }
                } else if model.categories.isEmpty {
                    Text("Nothing to clean — you're already tidy.")
                        .font(.system(size: 12)).foregroundStyle(DashSkin.inkFaint(dark))
                } else {
                    header
                    ForEach(model.categories) { category in
                        row(category)
                        if category.id != model.categories.last?.id { Divider().opacity(0.3) }
                    }
                    footer
                }
                if model.lastReclaimed > 0 {
                    Text("Reclaimed \(JunkScanner.format(model.lastReclaimed)) last clean.")
                        .font(.system(size: 11)).foregroundStyle(DashSkin.sage)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("\(JunkScanner.format(model.reclaimableTotal)) reclaimable")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button("Rescan") { model.scan() }.disabled(model.scanning).pointerCursor()
        }
    }

    private func row(_ category: JunkCategory) -> some View {
        HStack(spacing: 10) {
            Button {
                model.toggle(category.id)
            } label: {
                Image(systemName: category.selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(category.selected ? DashSkin.accent(dark) : .secondary)
            }
            .buttonStyle(.plain).pointerCursor()
            VStack(alignment: .leading, spacing: 1) {
                Text(category.name).font(.system(size: 13, weight: .medium))
                Text(category.detail).font(.system(size: 10.5))
                    .foregroundStyle(DashSkin.inkFaint(dark)).lineLimit(1)
            }
            Spacer()
            Text(JunkScanner.format(category.sizeBytes))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DashSkin.inkFaint(dark))
        }
        .padding(.vertical, 5)
    }

    private var footer: some View {
        HStack {
            Text("Moves items to the Trash — nothing is permanently deleted.")
                .font(.system(size: 10.5)).foregroundStyle(DashSkin.inkFaint(dark))
            Spacer()
            Button(role: .destructive) {
                model.clean()
            } label: {
                Text("Clean \(JunkScanner.format(model.selectedTotal))")
            }
            .disabled(model.scanning || model.selectedTotal == 0).pointerCursor()
        }
    }
}
