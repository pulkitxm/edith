import EdithKit
import SwiftUI

struct MachineProcessesTab: View {
    @ObservedObject var session: MachineSession
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @State private var query = ""
    @State private var sortByMemory = false
    @State private var pendingKill: MachineProcess?
    @State private var message: String?

    private var dark: Bool { scheme == .dark }

    private var rows: [MachineProcess] {
        let all = session.sample?.procs ?? []
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let filtered =
            trimmed.isEmpty
            ? all
            : all.filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
                    || $0.cmd.localizedCaseInsensitiveContains(trimmed)
                    || String($0.pid).contains(trimmed)
            }
        return filtered.sorted { sortByMemory ? $0.rssKB > $1.rssKB : $0.cpu > $1.cpu }
    }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            controls
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    if let message {
                        Text(message)
                            .font(.system(size: UIScale.pt(11.5)))
                            .foregroundStyle(DashSkin.inkSoft(dark))
                            .padding(UIScale.pt(10))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                DashSkin.warn.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
                    }
                    SkinCard(
                        title: "Top processes",
                        note: session.sample.map {
                            "\($0.tasks.total > 0 ? "\($0.tasks.total) tasks · " : "")"
                                + "sampled every 2s"
                        }, dark: dark
                    ) {
                        table
                    }
                }
                .pageContent(compact)
            }
        }
        .confirmationDialog(
            "End \(pendingKill?.name ?? "process")?",
            isPresented: Binding(
                get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
            titleVisibility: .visible
        ) {
            Button("Terminate (SIGTERM)") { kill(signal: "TERM") }
            Button("Force kill (SIGKILL)", role: .destructive) { kill(signal: "KILL") }
            Button("Cancel", role: .cancel) { pendingKill = nil }
        } message: {
            Text("PID \(pendingKill.map { String($0.pid) } ?? "")")
        }
    }

    private var controls: some View {
        HStack(spacing: UIScale.pt(10)) {
            SearchField(placeholder: "Filter processes", text: $query)
                .frame(maxWidth: UIScale.pt(280))
            Picker("", selection: $sortByMemory) {
                Text("CPU").tag(false)
                Text("Memory").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: UIScale.pt(160))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PageMetrics.gutter(compact))
        .padding(.bottom, UIScale.pt(12))
    }

    private var table: some View {
        VStack(spacing: UIScale.pt(0)) {
            HStack(spacing: UIScale.pt(10)) {
                columnHeader("PROCESS", width: nil, alignment: .leading)
                columnHeader("USER", width: UIScale.pt(80), alignment: .leading)
                columnHeader("CPU", width: UIScale.pt(56), alignment: .trailing)
                columnHeader("MEMORY", width: UIScale.pt(80), alignment: .trailing)
                Color.clear.frame(width: UIScale.pt(20))
            }
            .padding(.bottom, UIScale.pt(6))
            Divider().opacity(0.4)
            if rows.isEmpty, session.sample == nil {
                ListRowsSkeleton(rows: 8, showsLeadingDot: false, dark: dark)
            } else if rows.isEmpty {
                Text("Nothing matches that filter.")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, UIScale.pt(24))
            }
            ForEach(rows) { process in
                ProcessRow(
                    process: process, dark: dark, canKill: !session.isLocal
                ) {
                    pendingKill = process
                }
                if process.id != rows.last?.id { Divider().opacity(0.25) }
            }
        }
    }

    private func columnHeader(_ title: String, width: CGFloat?, alignment: Alignment) -> some View {
        Text(title)
            .font(.system(size: UIScale.pt(9.5), weight: .semibold))
            .tracking(UIScale.pt(0.5))
            .foregroundStyle(DashSkin.inkFaint(dark))
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
    }

    private func kill(signal: String) {
        guard let process = pendingKill else { return }
        pendingKill = nil
        Task {
            let result = await session.runCommand(
                ProcessCommands.kill(pid: process.pid, signal: signal))
            switch result {
            case let .success(output):
                message =
                    ProcessCommands.hadAlreadyExited(output)
                    ? "\(process.name) had already exited." : nil
            case let .failure(error):
                message = "Could not end \(process.name): \(error.localizedDescription)"
            }
        }
    }
}

private struct ProcessRow: View {
    let process: MachineProcess
    let dark: Bool
    let canKill: Bool
    let onKill: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                Text(process.name.isEmpty ? process.cmd : process.name)
                    .font(.system(size: UIScale.pt(12.5)))
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineLimit(1)
                Text(process.cmd)
                    .font(DashSkin.mono(10))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(process.user)
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(80), alignment: .leading)
                .lineLimit(1)
            Text(String(format: "%.1f%%", process.cpu))
                .font(DashSkin.mono(11))
                .foregroundStyle(process.cpu > 50 ? DashSkin.warn : DashSkin.inkSoft(dark))
                .frame(width: UIScale.pt(56), alignment: .trailing)
            Text(ByteFormatter.string(process.rssKB * 1024))
                .font(DashSkin.mono(11))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .frame(width: UIScale.pt(80), alignment: .trailing)
            Group {
                if canKill, hovering {
                    Button(action: onKill) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("End this process")
                } else {
                    Color.clear
                }
            }
            .frame(width: UIScale.pt(20))
        }
        .padding(.vertical, UIScale.pt(6))
        .padding(.horizontal, UIScale.pt(4))
        .background(
            RoundedRectangle(cornerRadius: UIScale.pt(7))
                .fill(hovering ? DashSkin.inkFaint(dark).opacity(0.08) : .clear)
        )
        .onHover { hovering = $0 }
    }
}
