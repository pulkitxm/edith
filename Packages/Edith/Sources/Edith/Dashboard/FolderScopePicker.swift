import AppKit
import EdithKit
import SwiftUI

struct FolderScopePicker: View {
    let model: DashboardModel
    let dark: Bool
    let dismiss: () -> Void

    @State private var query = ""

    private var matches: [ProjectPath] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.allProjectPaths }
        return model.allProjectPaths.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.path.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            SearchField(placeholder: "Search folders…", text: $query, compact: true)
            row(label: "All folders", detail: nil, selected: model.selectedPaths.isEmpty) {
                model.selectedPaths = []
            }
            if model.allProjectPaths.isEmpty {
                Text("Usage data has no folder paths yet. Hit refresh to rebuild it.")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, UIScale.pt(6))
            } else {
                row(label: "Choose folder…", detail: nil, selected: false, tint: true) {
                    chooseFolder()
                }
            }
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: UIScale.pt(1)) {
                    ForEach(matches) { entry in
                        row(
                            label: entry.name, detail: entry.path,
                            selected: model.selectedPaths.contains(entry.path)
                        ) {
                            toggle(entry.path)
                        }
                    }
                    if matches.isEmpty {
                        Text("No folders match")
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .padding(UIScale.pt(8))
                    }
                }
            }
            .frame(maxHeight: UIScale.pt(280))
            HStack {
                Text(scopeSummary)
                    .font(DashSkin.mono(10))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Spacer(minLength: 0)
                Button("Done") { dismiss() }
                    .buttonStyle(.plain).pointerCursor()
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(DashSkin.accent(dark))
            }
            .padding(.horizontal, UIScale.pt(6))
        }
        .padding(UIScale.pt(12))
        .frame(width: UIScale.pt(380))
    }

    private var scopeSummary: String {
        let n = model.selectedPaths.count
        if n == 0 { return "All folders" }
        return n == 1 ? "1 folder selected" : "\(n) folders selected"
    }

    private func toggle(_ path: String) {
        if model.selectedPaths.contains(path) {
            model.selectedPaths.remove(path)
        } else {
            model.selectedPaths.insert(path)
        }
    }

    private func row(
        label: String, detail: String?, selected: Bool, tint: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: selected ? "checkmark.circle.fill" : "folder")
                    .font(.system(size: UIScale.pt(10)))
                    .foregroundStyle(
                        selected || tint ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
                VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                    Text(label)
                        .font(
                            .system(
                                size: UIScale.pt(11.5), weight: selected ? .semibold : .regular)
                        )
                        .foregroundStyle(DashSkin.ink(dark))
                    if let detail {
                        Text(detail)
                            .font(DashSkin.mono(9.5))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UIScale.pt(6))
            .padding(.vertical, UIScale.pt(4))
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle(dark: dark))
        .pointerCursor()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Scope"
        if panel.runModal() == .OK {
            model.selectedPaths.formUnion(panel.urls.map(\.path))
        }
    }
}

private struct HoverRowStyle: ButtonStyle {
    let dark: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                hovering ? DashSkin.inkFaint(dark).opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: UIScale.pt(6))
            )
            .onHover { hovering = $0 }
    }
}
