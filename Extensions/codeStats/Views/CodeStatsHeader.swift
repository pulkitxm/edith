import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct CodeStatsHeader: View {
    let model: CodeStatsModel
    @Environment(\.colorScheme) private var scheme
    @State private var sharePresentation: ExportCardPresentation<CodeStatsExportDeck>?
    @State private var settingsPresented = false

    private var dark: Bool { scheme == .dark }

    private var shareSnapshot: CodeStatsExportSnapshot? {
        guard let report = model.report else { return nil }
        let snapshot = CodeStatsExportSnapshot(report: report)
        return snapshot.hasActivity ? snapshot : nil
    }

    private var runSummary: String? {
        guard model.phase != .setup, let status = model.status else { return nil }
        return status.runSummary(now: Date())
    }

    var body: some View {
        PageHeader("Code Stats", subtitle: runSummary) {
            HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                if model.phase != .setup {
                    ExportCardButton(
                        isEnabled: shareSnapshot != nil, help: "Share code stats as images"
                    ) {
                        guard let shareSnapshot else { return }
                        sharePresentation = ExportCardPresentation(
                            deck: CodeStatsExportDeck(
                                snapshot: shareSnapshot, remote: model.remote),
                            title: "Share code stats")
                    }
                    Button {
                        settingsPresented = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .help("Code Stats settings")
                    Button {
                        Task { await model.start() }
                    } label: {
                        Label(
                            model.isRunning ? "Refreshing" : "Refresh",
                            systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.edith(.primary))
                    .disabled(!model.canStart)
                    .help(model.startBlocker ?? "Fetch new commits and update your stats")
                }
            }
        } accessory: {
            if model.phase != .setup, let profiles = model.status?.state.profiles,
                !profiles.isEmpty
            {
                HStack(spacing: UIScale.pt(12)) {
                    ForEach(profiles, id: \.id) { profile in
                        CodeStatsProfileBadge(profile: profile, dark: dark)
                    }
                }
            }
        }
        .exportCardPresentation(item: $sharePresentation)
        .edithSheet(isPresented: $settingsPresented) {
            CodeStatsSettingsSheet(model: model)
        }
    }
}

struct CodeStatsProfileBadge: View {
    let profile: CodeStatsProfile
    let dark: Bool

    var body: some View {
        HStack(spacing: UIScale.pt(8)) {
            AsyncImage(url: profile.avatarURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            .frame(width: UIScale.pt(28), height: UIScale.pt(28))
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                Text(profile.name ?? profile.login)
                    .font(.edithText(.callout).weight(.semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text("@" + profile.login)
                    .font(.edithText(.caption))
                    .foregroundStyle(DashSkin.inkSoft(dark))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct CodeStatsBannerView: View {
    let banner: CodeStatsBanner
    let choose: () -> Void
    let retry: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        PageNotice(
            banner.message, title: banner.title,
            tone: banner.tone == .danger ? .error : .warning, symbol: banner.symbol
        ) {
            if let command = banner.command {
                CodeStatsCommandHint(command: command, dark: dark)
            }
        } actions: {
            if banner.choosesFolder {
                Button("Choose folder...", action: choose)
            }
            if banner.retriesReport {
                Button("Retry", action: retry)
            }
        }
    }
}

struct CodeStatsCommandHint: View {
    let command: String
    let dark: Bool

    var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            Text(command)
                .font(DashSkin.mono(11.5, weight: .medium))
                .foregroundStyle(DashSkin.ink(dark))
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.edith(.borderless))
            .help("Copy")
        }
        .padding(.horizontal, UIScale.pt(8))
        .padding(.vertical, UIScale.pt(4))
        .widgetBar(cornerRadius: 6, fill: DashSkin.paper2(dark), stroke: DashSkin.line(dark))
    }
}
