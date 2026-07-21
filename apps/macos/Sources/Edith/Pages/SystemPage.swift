import EdithKit
import SwiftUI

struct SystemPage: View {
    @StateObject private var model = RunningAppsModel()
    @Environment(\.colorScheme) private var scheme
    @State private var confirmQuitAll = false
    @State private var pendingQuit: RunningAppRow?

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                header
                summary
                SkinCard(title: "Running apps", dark: dark) {
                    appList
                }
                CleanerCard(dark: dark)
            }
            .padding(UIScale.pt(24))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DashSkin.paper(dark))
        .confirmationDialog(
            "Quit \(pendingQuit?.name ?? "app")?",
            isPresented: Binding(
                get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } }),
            titleVisibility: .visible
        ) {
            Button("Quit \(pendingQuit?.name ?? "app")", role: .destructive) {
                if let app = pendingQuit { model.quit(app) }
                pendingQuit = nil
            }
            Button("Cancel", role: .cancel) { pendingQuit = nil }
        } message: {
            Text("The app will close. Unsaved changes will prompt you first.")
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("System").font(.system(size: UIScale.pt(30), weight: .bold))
            Spacer()
            Button(role: .destructive) {
                confirmQuitAll = true
            } label: {
                Label("Quit all apps", systemImage: "xmark.circle")
            }
            .pointerCursor()
            .confirmationDialog(
                "Quit all apps?", isPresented: $confirmQuitAll, titleVisibility: .visible
            ) {
                Button("Quit \(max(0, model.apps.count - 1)) apps", role: .destructive) {
                    model.quitAll()
                }
            } message: {
                Text("Finder and Edith stay open. Apps with unsaved changes will ask first.")
            }
        }
    }

    private var summary: some View {
        HStack(spacing: UIScale.pt(12)) {
            summaryCard("Running apps", "\(model.apps.count)")
            summaryCard("App memory", String(format: "%.1f GB", model.totalMemoryMB / 1024))
        }
    }

    private func summaryCard(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(label.uppercased())
                .font(.system(size: UIScale.pt(10), weight: .semibold)).tracking(UIScale.pt(0.6))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text(value).font(.system(size: UIScale.pt(22), weight: .semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UIScale.pt(16))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(14)))
    }

    private var columnHeaders: some View {
        HStack(spacing: UIScale.pt(10)) {
            headerButton("App", .name, width: nil, alignment: .leading)
                .padding(.leading, UIScale.pt(32))
            Spacer()
            headerButton("CPU", .cpu, width: UIScale.pt(48), alignment: .trailing)
            headerButton("Memory", .memory, width: UIScale.pt(72), alignment: .trailing)
            Color.clear.frame(width: UIScale.pt(16))
        }
        .padding(.bottom, UIScale.pt(6))
    }

    private func headerButton(
        _ label: String, _ key: AppSortKey, width: CGFloat?, alignment: Alignment
    ) -> some View {
        Button {
            model.sort(by: key)
        } label: {
            HStack(spacing: UIScale.pt(3)) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(label.uppercased())
                    .font(.system(size: UIScale.pt(10), weight: .semibold)).tracking(
                        UIScale.pt(0.5))
                if model.sortKey == key {
                    Image(systemName: model.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: UIScale.pt(7), weight: .bold))
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .foregroundStyle(model.sortKey == key ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
            .frame(width: width, alignment: alignment)
        }
        .buttonStyle(.plain).pointerCursor()
    }

    private var appList: some View {
        VStack(spacing: UIScale.pt(0)) {
            columnHeaders
            Divider().opacity(0.4)
            if model.apps.isEmpty {
                HStack(spacing: UIScale.pt(8)) {
                    ProgressView().controlSize(.small)
                    Text("Reading running apps…")
                        .font(.system(size: UIScale.pt(12))).foregroundStyle(
                            DashSkin.inkFaint(dark))
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, UIScale.pt(24))
            }
            ForEach(model.apps) { app in
                SystemAppRow(app: app, dark: dark) { pendingQuit = app }
                if app.id != model.apps.last?.id {
                    Divider().opacity(0.3)
                }
            }
        }
    }

    fileprivate static func cpuLabel(_ percent: Double) -> String {
        percent >= 10 || percent == 0
            ? String(format: "%.0f%%", percent) : String(format: "%.1f%%", percent)
    }

    fileprivate static func memoryLabel(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}

private struct SystemAppRow: View {
    let app: RunningAppRow
    let dark: Bool
    let onQuit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().frame(
                    width: UIScale.pt(22), height: UIScale.pt(22))
            }
            Text(app.name).font(.system(size: UIScale.pt(13))).lineLimit(1)
            Spacer()
            Text(SystemPage.cpuLabel(app.cpuPercent))
                .font(.system(size: UIScale.pt(12), design: .monospaced))
                .foregroundStyle(app.cpuPercent > 25 ? .orange : DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(48), alignment: .trailing)
            Text(SystemPage.memoryLabel(app.memoryMB))
                .font(.system(size: UIScale.pt(12), design: .monospaced))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(72), alignment: .trailing)
            Button {
                onQuit()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Quit \(app.name)")
        }
        .padding(.horizontal, UIScale.pt(6))
        .padding(.vertical, UIScale.pt(7))
        .background(
            RoundedRectangle(cornerRadius: UIScale.pt(7))
                .fill(hovering ? DashSkin.inkFaint(dark).opacity(0.1) : .clear)
        )
        .onHover { hovering = $0 }
    }
}
