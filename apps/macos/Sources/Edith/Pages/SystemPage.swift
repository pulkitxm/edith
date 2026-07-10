import EdithKit
import SwiftUI

struct SystemPage: View {
    @StateObject private var model = RunningAppsModel()
    @Environment(\.colorScheme) private var scheme
    @State private var confirmQuitAll = false

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                summary
                SkinCard(title: "Running apps", dark: dark) {
                    appList
                }
            }
            .padding(24)
        }
        .task {
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("System").font(.system(size: 30, weight: .bold))
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
                Button("Quit \(model.apps.count - 1) apps", role: .destructive) {
                    model.quitAll()
                }
            } message: {
                Text("Finder and Edith stay open. Apps with unsaved changes will ask first.")
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            summaryCard("Running apps", "\(model.apps.count)")
            summaryCard("App memory", String(format: "%.1f GB", model.totalMemoryMB / 1024))
        }
    }

    private func summaryCard(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 14))
    }

    private var appList: some View {
        VStack(spacing: 0) {
            ForEach(model.apps) { app in
                HStack(spacing: 10) {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                    }
                    Text(app.name).font(.system(size: 13)).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f%%", app.cpuPercent))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(app.cpuPercent > 25 ? .orange : DashSkin.inkFaint(dark))
                        .frame(width: 48, alignment: .trailing)
                    Text(String(format: "%.0f MB", app.memoryMB))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(width: 72, alignment: .trailing)
                    Button {
                        model.quit(app)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Quit \(app.name)")
                }
                .padding(.vertical, 7)
                if app.id != model.apps.last?.id {
                    Divider().opacity(0.3)
                }
            }
        }
    }
}
