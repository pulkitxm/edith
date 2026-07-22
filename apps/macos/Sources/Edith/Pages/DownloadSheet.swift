import AppKit
import EdithKit
import SwiftUI

struct DownloadSheet: View {
    @ObservedObject private var downloader = YoutubeDownloader.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"
    @Environment(\.colorScheme) private var scheme
    @State private var urlText = ""
    @State private var filenamePrefix = ""
    @State private var logItem: YoutubeDownloader.DownloadItem?
    @State private var confirmClearHistory = false

    private var theme: Color { themeColor(themeName) }
    private var dark: Bool { scheme == .dark }
    private var parsedCount: Int {
        guard downloader.unavailableReason == nil else { return 0 }
        return YoutubeDownloader.parseURLs(from: urlText).count
    }
    private var canStart: Bool {
        parsedCount > 0
    }

    private var activeItems: [YoutubeDownloader.DownloadItem] {
        downloader.items.filter {
            switch $0.status {
            case .queued, .resolving, .downloading, .error: true
            default: false
            }
        }
    }
    private var historyItems: [YoutubeDownloader.DownloadItem] {
        downloader.items.filter {
            switch $0.status {
            case .queued, .resolving, .downloading, .error: false
            default: true
            }
        }
    }
    private var progressFraction: Double {
        let total = downloader.items.count
        guard total > 0 else { return 0 }
        let done = downloader.items.filter {
            if case .done = $0.status { return true }; return false
        }.count
        return Double(done) / Double(total)
    }
    private var summaryText: String {
        let active = downloader.items.filter {
            switch $0.status {
            case .queued, .resolving, .downloading: true
            default: false
            }
        }.count
        let done = downloader.items.filter {
            if case .done = $0.status { return true }; return false
        }.count
        let errors = downloader.items.filter {
            if case .error = $0.status { return true }; return false
        }.count
        let interrupted = downloader.items.filter {
            if case .interrupted = $0.status { return true }; return false
        }.count
        var parts: [String] = []
        if done > 0 { parts.append("\(done) done") }
        if active > 0 { parts.append("\(active) active") }
        if interrupted > 0 { parts.append("\(interrupted) paused") }
        if errors > 0 { parts.append("\(errors) failed") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            header
            Divider().overlay(DashSkin.line(dark))
            if let reason = downloader.unavailableReason {
                unavailableView(reason)
            } else {
                content
            }
        }
        .frame(width: UIScale.pt(560), height: UIScale.pt(580))
        .background(DashSkin.paper(dark))
    }

    private var header: some View {
        HStack(spacing: UIScale.pt(10)) {
            Text("Download YouTube Audio")
                .font(DashSkin.serif(20))
                .foregroundStyle(DashSkin.ink(dark))
            Spacer()
            Button {
                downloader.updateYTDLP()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: UIScale.pt(12), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: UIScale.pt(22), height: UIScale.pt(22))
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle())
            .disabled(downloader.isRunning || downloader.isUpdatingYTDLP)
            .pointerCursor()
            .help("Update yt-dlp")
            if let result = downloader.updateResult {
                switch result {
                case .success(let msg):
                    Text(msg)
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                case .failure(let error):
                    Text(error.localizedDescription)
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: UIScale.pt(12), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: UIScale.pt(22), height: UIScale.pt(22))
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle())
            .disabled(downloader.isRunning)
            .pointerCursor()
        }
        .padding(.horizontal, UIScale.pt(22))
        .padding(.vertical, UIScale.pt(14))
    }

    private func unavailableView(_ reason: String) -> some View {
        VStack(spacing: UIScale.pt(14)) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: UIScale.pt(30)))
                .foregroundStyle(.orange)
            Text(reason)
                .font(.system(size: UIScale.pt(12.5)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            Spacer()
        }
        .padding(.horizontal, UIScale.pt(40))
    }

    @ViewBuilder
    private var content: some View {
        if downloader.items.isEmpty {
            VStack(spacing: UIScale.pt(16)) {
                urlInput
                optionsRow
                Spacer()
                startRow
            }
            .padding(.horizontal, UIScale.pt(22))
            .padding(.top, UIScale.pt(16))
            .padding(.bottom, UIScale.pt(14))
        } else {
            VStack(spacing: UIScale.pt(0)) {
                urlBar
                Divider().overlay(DashSkin.line(dark))
                if !activeItems.isEmpty {
                    progressHeader
                    activeQueue
                        .frame(maxHeight: UIScale.pt(200))
                    Divider().overlay(DashSkin.line(dark))
                }
                if !historyItems.isEmpty {
                    historyHeader
                    historyList
                }
                if activeItems.isEmpty && historyItems.isEmpty {
                    emptyState
                }
                Spacer(minLength: 0)
                Divider().overlay(DashSkin.line(dark))
                controlsRow
            }
            .sheet(item: $logItem) { item in
                logSheet(item)
            }
        }
    }

    private var urlInput: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            label("VIDEO URLS")
            ZStack(alignment: .topLeading) {
                TextEditor(text: $urlText)
                    .font(.system(size: UIScale.pt(13), design: .monospaced))
                    .foregroundStyle(DashSkin.ink(dark))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(height: downloader.isRunning ? 46 : 104)
                    .padding(.horizontal, UIScale.pt(10))
                    .padding(.vertical, UIScale.pt(8))
                if urlText.isEmpty {
                    Text("Paste one or more YouTube links, one per line")
                        .font(.system(size: UIScale.pt(12.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark).opacity(0.45))
                        .padding(.horizontal, UIScale.pt(14))
                        .padding(.vertical, UIScale.pt(10))
                        .allowsHitTesting(false)
                }
            }
            .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(10))
                    .strokeBorder(
                        urlText.isEmpty ? DashSkin.line(dark) : DashSkin.lineStrong(dark),
                        lineWidth: UIScale.pt(1))
            )

            HStack(spacing: UIScale.pt(10)) {
                if parsedCount > 0 {
                    HStack(spacing: UIScale.pt(4)) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: UIScale.pt(10)))
                            .foregroundStyle(.green)
                        Text("\(parsedCount) valid URL\(parsedCount == 1 ? "" : "s")")
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(.secondary)
                    }
                } else if !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No YouTube URLs found")
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button {
                    urlText = NSPasteboard.general.string(forType: .string) ?? urlText
                } label: {
                    Label("Paste", systemImage: "clipboard")
                        .font(.system(size: UIScale.pt(11)))
                }
                .buttonStyle(HoverButtonStyle())
                .pointerCursor()
            }
            .frame(height: UIScale.pt(16))
        }
    }

    private var optionsRow: some View {
        HStack(spacing: UIScale.pt(12)) {
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                label("FILENAME PREFIX")
                TextField("Optional — e.g. roadtrip_", text: $filenamePrefix)
                    .textFieldStyle(.plain)
                    .font(.system(size: UIScale.pt(12.5)))
                    .foregroundStyle(DashSkin.ink(dark))
                    .padding(.horizontal, UIScale.pt(10))
                    .padding(.vertical, UIScale.pt(7))
                    .background(
                        DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(8))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: UIScale.pt(8))
                            .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(1))
                    )
            }
            if !filenamePrefix.isEmpty {
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    label("PREVIEW")
                    Text("\(filenamePrefix)Title.m4a")
                        .font(.system(size: UIScale.pt(11), design: .monospaced))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .lineLimit(1)
                        .padding(.top, UIScale.pt(7))
                }
                .frame(maxWidth: UIScale.pt(140), alignment: .leading)
            }
        }
    }

    private var startRow: some View {
        HStack {
            Spacer()
            Button(action: startDownload) {
                HStack(spacing: UIScale.pt(6)) {
                    Image(systemName: "arrow.down.circle")
                    Text("Start Download")
                        .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, UIScale.pt(18))
                .padding(.vertical, UIScale.pt(9))
                .background(canStart ? theme : Color.gray.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(9)))
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
            .pointerCursor()
        }
    }

    private var urlBar: some View {
        HStack(spacing: UIScale.pt(8)) {
            TextField("Add more YouTube URLs...", text: $urlText)
                .textFieldStyle(.plain)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.ink(dark))
                .padding(.horizontal, UIScale.pt(10))
                .padding(.vertical, UIScale.pt(6))
                .background(
                    DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(8))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: UIScale.pt(8))
                        .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(1))
                )
                .disabled(downloader.isRunning)
            Button(action: addMore) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: UIScale.pt(20)))
                    .foregroundStyle(canStart ? theme : Color.gray.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
            .pointerCursor()
            .help("Add to queue")
        }
        .padding(.horizontal, UIScale.pt(22))
        .padding(.vertical, UIScale.pt(8))
    }

    private var progressHeader: some View {
        VStack(spacing: UIScale.pt(6)) {
            HStack {
                Text("ACTIVE")
                    .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .tracking(UIScale.pt(0.5))
                Spacer()
                if !summaryText.isEmpty {
                    Text(summaryText)
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                }
            }
            let pct = progressFraction
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DashSkin.line(dark))
                        .frame(height: UIScale.pt(5))
                    Capsule()
                        .fill(theme)
                        .frame(width: max(5, geo.size.width * pct), height: UIScale.pt(5))
                }
            }
            .frame(height: UIScale.pt(5))
        }
        .padding(.horizontal, UIScale.pt(22))
        .padding(.vertical, UIScale.pt(10))
    }

    private var activeQueue: some View {
        ScrollView {
            LazyVStack(spacing: UIScale.pt(4)) {
                ForEach(activeItems) { item in
                    queueCard(item)
                }
            }
            .padding(.horizontal, UIScale.pt(16))
            .padding(.vertical, UIScale.pt(8))
        }
        .scrollIndicators(.hidden)
    }

    private var historyHeader: some View {
        HStack {
            Text("HISTORY")
                .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .tracking(UIScale.pt(0.5))
            Spacer()
            let failedCount = downloader.items.filter {
                if case .error = $0.status { return true }; return false
            }.count
            let interruptedCount = downloader.items.filter {
                if case .interrupted = $0.status { return true }; return false
            }.count
            if failedCount + interruptedCount > 0 {
                Button("Retry All") {
                    downloader.retryAll()
                }
                .buttonStyle(HoverButtonStyle())
                .font(.system(size: UIScale.pt(10.5), weight: .medium))
                .pointerCursor()
                .disabled(downloader.isRunning)
            }
        }
        .padding(.horizontal, UIScale.pt(22))
        .padding(.vertical, UIScale.pt(8))
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(spacing: UIScale.pt(2)) {
                ForEach(historyItems) { item in
                    historyRow(item)
                }
            }
            .padding(.horizontal, UIScale.pt(16))
            .padding(.vertical, UIScale.pt(4))
        }
        .scrollIndicators(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: UIScale.pt(6)) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: UIScale.pt(24)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text("No downloads yet")
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkSoft(dark))
            Spacer()
        }
    }

    private func queueCard(_ item: YoutubeDownloader.DownloadItem) -> some View {
        let isActive: Bool
        let tint: Color
        switch item.status {
        case .downloading: isActive = true; tint = theme
        case .done: isActive = false; tint = .green
        case .error: isActive = false; tint = .red
        case .interrupted: isActive = false; tint = .orange
        default: isActive = false; tint = DashSkin.inkFaint(dark)
        }

        return HStack(spacing: UIScale.pt(10)) {
            Group {
                switch item.status {
                case .queued:
                    Image(systemName: "clock")
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                case .resolving:
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.55)
                case .downloading:
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.55)
                        .tint(theme)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: UIScale.pt(15)))
                        .foregroundStyle(.green)
                case .error:
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: UIScale.pt(15)))
                        .foregroundStyle(.red)
                case .interrupted:
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: UIScale.pt(16)))
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: UIScale.pt(20))

            DownloadThumb(url: item.url, dark: dark, height: UIScale.pt(34))

            VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                Text(item.resolvedTitle ?? displayURL(item.url))
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(
                        isActive ? AnyShapeStyle(tint) : AnyShapeStyle(DashSkin.ink(dark))
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)

                switch item.status {
                case .queued:
                    EmptyView()
                case .resolving:
                    EmptyView()
                case let .downloading(progress, videoIndex, videoCount):
                    HStack(spacing: UIScale.pt(4)) {
                        if videoIndex > 0, videoCount > 0 {
                            Text("\(videoIndex)/\(videoCount)")
                                .font(.system(size: UIScale.pt(10.5), weight: .medium))
                                .foregroundStyle(theme)
                        }
                        if !progress.isEmpty {
                            Text(progress)
                                .font(
                                    .system(
                                        size: UIScale.pt(11), weight: .medium, design: .monospaced)
                                )
                                .foregroundStyle(theme)
                        }
                    }
                case let .done(output):
                    Text(output)
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .lineLimit(1)
                case let .error(msg):
                    Text(msg)
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                case .interrupted:
                    EmptyView()
                }
            }

            Spacer(minLength: 4)

            switch item.status {
            case .error, .interrupted:
                Button("Retry") {
                    downloader.retry(item)
                }
                .buttonStyle(HoverButtonStyle())
                .font(.system(size: UIScale.pt(10), weight: .medium))
                .foregroundStyle(theme)
                .pointerCursor()
                .disabled(downloader.isRunning)
            default:
                EmptyView()
            }
        }
        .padding(.vertical, UIScale.pt(8))
        .padding(.horizontal, UIScale.pt(10))
        .background(
            isActive
                ? DashSkin.paper2(dark) : Color.clear,
            in: RoundedRectangle(cornerRadius: UIScale.pt(9))
        )
        .overlay(
            isActive
                ? RoundedRectangle(cornerRadius: UIScale.pt(9)).strokeBorder(
                    theme.opacity(0.3), lineWidth: UIScale.pt(1))
                : nil
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if case .done = item.status {
            } else {
                logItem = item
            }
        }
    }

    private func historyRow(_ item: YoutubeDownloader.DownloadItem) -> some View {
        HStack(spacing: UIScale.pt(10)) {
            Group {
                switch item.status {
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: UIScale.pt(14)))
                        .foregroundStyle(.green)
                case .error:
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: UIScale.pt(14)))
                        .foregroundStyle(.red)
                case .interrupted:
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: UIScale.pt(14)))
                        .foregroundStyle(.orange)
                default:
                    EmptyView()
                }
            }
            .frame(width: UIScale.pt(18))

            DownloadThumb(url: item.url, dark: dark, height: UIScale.pt(30))

            VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                Text(item.resolvedTitle ?? displayURL(item.url))
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineLimit(1)
                    .truncationMode(.middle)

                switch item.status {
                case .done:
                    Text(displayURL(item.url))
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .lineLimit(1)
                case let .error(msg):
                    Text(msg)
                        .font(.system(size: UIScale.pt(9.5)))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                case let .interrupted(reason):
                    Text(reason ?? "Paused")
                        .font(.system(size: UIScale.pt(9.5)))
                        .foregroundStyle(.orange)
                default:
                    EmptyView()
                }
            }

            Spacer(minLength: 4)

            switch item.status {
            case .error, .interrupted:
                Button("Retry") {
                    downloader.retry(item)
                }
                .buttonStyle(HoverButtonStyle())
                .font(.system(size: UIScale.pt(10), weight: .medium))
                .foregroundStyle(theme)
                .pointerCursor()
                .disabled(downloader.isRunning)
            default:
                EmptyView()
            }
        }
        .padding(.vertical, UIScale.pt(5))
        .padding(.horizontal, UIScale.pt(8))
        .background(Color.clear, in: RoundedRectangle(cornerRadius: UIScale.pt(6)))
    }

    private func logSheet(_ item: YoutubeDownloader.DownloadItem) -> some View {
        let live = downloader.items.first(where: { $0.id == item.id }) ?? item
        return VStack(spacing: UIScale.pt(0)) {
            HStack {
                Text("Download Log")
                    .font(DashSkin.serif(16))
                    .foregroundStyle(DashSkin.ink(dark))
                Spacer()
                Button {
                    logItem = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: UIScale.pt(12), weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: UIScale.pt(22), height: UIScale.pt(22))
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverButtonStyle())
                .pointerCursor()
            }
            .padding(.horizontal, UIScale.pt(20))
            .padding(.vertical, UIScale.pt(12))

            Divider().overlay(DashSkin.line(dark))

            ScrollViewReader { proxy in
                ScrollView {
                    Text(live.logs.isEmpty ? "Waiting for output…" : live.logs)
                        .font(.system(size: UIScale.pt(11), design: .monospaced))
                        .foregroundStyle(DashSkin.ink(dark))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(UIScale.pt(14))
                    Color.clear.frame(height: UIScale.pt(1)).id("logBottom")
                }
                .scrollIndicators(.hidden)
                .onChange(of: live.logs) { proxy.scrollTo("logBottom", anchor: .bottom) }
                .onAppear { proxy.scrollTo("logBottom", anchor: .bottom) }
            }
        }
        .frame(width: UIScale.pt(480), height: UIScale.pt(360))
        .background(DashSkin.paper(dark))
    }

    private var controlsRow: some View {
        HStack(spacing: UIScale.pt(8)) {
            if !downloader.items.isEmpty {
                Button("Clear History") {
                    confirmClearHistory = true
                }
                .buttonStyle(HoverButtonStyle())
                .font(.system(size: UIScale.pt(11)))
                .pointerCursor()
                .disabled(downloader.isRunning)
                .confirmationDialog(
                    "Clear download history?", isPresented: $confirmClearHistory,
                    titleVisibility: .visible
                ) {
                    Button("Clear \(downloader.items.count) entries", role: .destructive) {
                        downloader.clearHistory()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Downloaded files stay on disk; only the list is cleared.")
                }
            }
            if downloader.isRunning {
                Button {
                    downloader.cancelAll()
                } label: {
                    Label("Cancel All", systemImage: "xmark")
                        .font(.system(size: UIScale.pt(11)))
                }
                .buttonStyle(HoverButtonStyle())
                .pointerCursor()
            }
            Spacer()
            Button("Close") {
                dismiss()
            }
            .buttonStyle(HoverButtonStyle())
            .font(.system(size: UIScale.pt(11)))
            .pointerCursor()
        }
        .padding(.horizontal, UIScale.pt(22))
        .padding(.vertical, UIScale.pt(10))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: UIScale.pt(10), weight: .semibold))
            .foregroundStyle(DashSkin.inkFaint(dark))
            .tracking(UIScale.pt(0.6))
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: UIScale.pt(9.5), weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, UIScale.pt(5))
            .padding(.vertical, UIScale.pt(1))
            .background(color.opacity(0.12), in: Capsule())
    }

    private func displayURL(_ url: URL) -> String {
        let id: String
        if url.host?.contains("youtu.be") == true {
            id = url.lastPathComponent
        } else {
            id =
                URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value ?? url.lastPathComponent
        }
        return "youtube.com/watch?v=\(id.prefix(11))"
    }

    private func startDownload() {
        let urls = YoutubeDownloader.parseURLs(from: urlText)
        guard !urls.isEmpty else { return }
        downloader.enqueue(urls: urls, prefix: filenamePrefix)
        urlText = ""
    }

    private func addMore() {
        let urls = YoutubeDownloader.parseURLs(from: urlText)
        guard !urls.isEmpty else { return }
        downloader.enqueue(urls: urls, prefix: filenamePrefix)
        urlText = ""
    }
}

private struct DownloadThumb: View {
    let url: URL
    let dark: Bool
    var height: CGFloat = 32

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: UIScale.pt(5)).fill(DashSkin.paper2(dark))
            if let thumb = YoutubeDownloader.thumbnailURL(for: url) {
                AsyncImage(url: thumb) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: height * 16 / 9, height: height)
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(5)))
    }

    private var placeholder: some View {
        Image(systemName: "play.rectangle.fill")
            .font(.system(size: height * 0.4))
            .foregroundStyle(DashSkin.inkFaint(dark))
    }
}
