import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct CodeStatsHeader: View {
    let model: CodeStatsModel
    @Environment(\.colorScheme) private var scheme
    @State private var sharePresentation: ExportCardPresentation<CodeStatsExportDeck>?

    private var dark: Bool { scheme == .dark }

    private var shareSnapshot: CodeStatsExportSnapshot? {
        guard let report = model.report else { return nil }
        let snapshot = CodeStatsExportSnapshot(report: report)
        return snapshot.hasActivity ? snapshot : nil
    }

    var body: some View {
        PageHeader("Code Stats") {
            HStack(spacing: UIScale.pt(8)) {
                ExportCardButton(
                    isEnabled: shareSnapshot != nil, help: "Share code stats as images"
                ) {
                    guard let shareSnapshot else { return }
                    sharePresentation = ExportCardPresentation(
                        deck: CodeStatsExportDeck(snapshot: shareSnapshot),
                        title: "Share code stats")
                }
                if model.isRunning {
                    Button {
                        Task { await model.cancel() }
                    } label: {
                        Label("Cancel", systemImage: "stop.circle")
                    }
                    .disabled(model.isCancelling)
                } else {
                    Button {
                        Task { await model.start() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.edith(.primary))
                    .disabled(!model.canStart)
                }
            }
        } accessory: {
            HStack(spacing: UIScale.pt(12)) {
                if let profile = model.status?.state.profile {
                    CodeStatsProfileBadge(profile: profile, dark: dark)
                }
                Spacer(minLength: UIScale.pt(8))
                if let status = model.status {
                    CodeStatsRunTimes(status: status, dark: dark)
                }
            }
        }
        .exportCardPresentation(item: $sharePresentation)
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
                    .font(.system(size: UIScale.pt(13), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text("@" + profile.login)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CodeStatsRunTimes: View {
    let status: CodeStatsStatus
    let dark: Bool

    var body: some View {
        HStack(spacing: UIScale.pt(14)) {
            label(
                "Last updated",
                status.state.reportedAt.map {
                    $0.formatted(.relative(presentation: .named))
                } ?? "Never")
            label("Next run", status.nextRunLabel(now: Date()))
        }
    }

    private func label(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: UIScale.pt(1)) {
            Text(title.uppercased())
                .font(DashSkin.mono(9)).tracking(UIScale.pt(1))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text(value)
                .font(.system(size: UIScale.pt(12), weight: .medium))
                .foregroundStyle(DashSkin.ink(dark))
        }
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
