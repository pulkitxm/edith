import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct DownloadListRow: Identifiable, Equatable {
    let item: YoutubeDownloader.DownloadItem
    let first: Bool
    let last: Bool
    let running: Bool
    let appearance: String

    var id: String { item.id.uuidString }
}

enum DownloadRowMetrics {
    static let rowHeight = 56.0
    static let groupInset = 6.0

    static func height(of row: DownloadListRow) -> CGFloat {
        let insets =
            (row.first ? groupInset : 0) + (row.last ? groupInset + PageMetrics.bottom : 0)
        return CGFloat(UIScale.pt(rowHeight + insets))
    }

    static func fraction(from progress: String) -> Double? {
        guard let range = percentRange(in: progress),
            let value = Double(progress[range].dropLast())
        else { return nil }
        return min(1, max(0, value / 100))
    }

    static func detail(from progress: String) -> String {
        guard let range = percentRange(in: progress) else { return progress }
        let rest = progress[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.hasPrefix("of ") ? String(rest.dropFirst(3)) : rest
    }

    private static func percentRange(in progress: String) -> Range<String.Index>? {
        progress.range(of: #"[0-9]+(\.[0-9]+)?%"#, options: .regularExpression)
    }
}

private struct DownloadRowBackground: View {
    let first: Bool
    let last: Bool
    let dark: Bool

    var body: some View {
        let radius = UIScale.pt(PageMetrics.cardCornerRadius)
        UnevenRoundedRectangle(
            topLeadingRadius: first ? radius : 0, bottomLeadingRadius: last ? radius : 0,
            bottomTrailingRadius: last ? radius : 0, topTrailingRadius: first ? radius : 0,
            style: .continuous
        )
        .fill(DashSkin.paper2(dark))
    }
}

struct DownloadSheet: View {
    var isPage = false
    @State private var downloader: YoutubeDownloader
    init(isPage: Bool = false, downloader: YoutubeDownloader? = nil) {
        self.isPage = isPage
        _downloader = State(initialValue: downloader ?? .shared)
    }

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @State private var urlText = ""
    @State private var filenamePrefix = ""
    @State private var logItem: YoutubeDownloader.DownloadItem?
    @State private var settingsPresented = false
    @State private var confirmClearHistory = false
    @AppStorage(AppStorageKeys.Music.downloadKind, store: SharedDefaults.store) private
        var downloadKindRaw =
        DownloadKind.post.rawValue
    @State private var estimate: DownloadEstimate?
    @State private var estimateLoad = ContentLoad()
    private var estimating: Bool { estimateLoad.isRunning }
    @State private var outputDirectory: URL?
    @State private var browser = ""

    init(isPage: Bool = false, downloader: YoutubeDownloader) {
        self.isPage = isPage
        _downloader = State(initialValue: downloader)
    }

    private var downloadKind: DownloadKind {
        DownloadKind(rawValue: downloadKindRaw) ?? .post
    }

    private var theme: Color { themeColor(themeName) }
    private var dark: Bool { scheme == .dark }
    private var parsedCount: Int {
        guard downloader.unavailableReason == nil else { return 0 }
        return YoutubeDownloader.parseURLs(from: urlText).count
    }
    private var canStart: Bool {
        parsedCount > 0
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
        if active > 0 { parts.append("\(active) in progress") }
        if done > 0 { parts.append("\(done) done") }
        if interrupted > 0 { parts.append("\(interrupted) paused") }
        if errors > 0 { parts.append("\(errors) failed") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        PageWorkspace {
            header
            Divider().overlay(DashSkin.line(dark))
        } content: {
            if let reason = downloader.unavailableReason {
                unavailableView(reason)
            } else {
                content
            }
        }
        .frame(
            width: isPage ? nil : PresentationMetrics.width(680),
            height: isPage ? nil : PresentationMetrics.height(760)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pageTask { downloader.checkAvailability() }
        .onChange(of: downloadKindRaw) { _, value in
            if let kind = DownloadKind(rawValue: value) { downloader.setPreferredKind(kind) }
        }
        .alert(
            "Download request failed",
            isPresented: Binding(
                get: { downloader.errorMessage != nil },
                set: { if !$0 { downloader.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { downloader.errorMessage = nil }
        } message: {
            Text(downloader.errorMessage ?? "")
        }
    }

    private var header: some View {
        PageHeader(
            "Downloads",
            trailing: {
                HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                    if let result = downloader.updateResult {
                        switch result {
                        case .success(let message):
                            Label(message, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failure(let error):
                            Label(
                                error.localizedDescription,
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.red)
                        }
                    }
                    if downloader.unavailableReason == nil {
                        Button {
                            downloader.updateYTDLP()
                        } label: {
                            Label(
                                downloader.isUpdatingYTDLP ? "Updating…" : "Update tool",
                                systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.edith(.secondary))
                        .disabled(downloader.isRunning || downloader.isUpdatingYTDLP)
                        .help(
                            downloader.isRunning
                                ? "Wait for active downloads to finish before updating the download tool"
                                : "Update the download tool (yt-dlp) if a site stops working"
                        )
                        .accessibilityLabel("Update download tool")
                    }
                    if !isPage {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.edith(.iconOnly))
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Close")
                    }
                }
                .font(.edithText(.callout))
                .lineLimit(1)
            },
            accessory: {
                PageSubtitle("Save videos, photos, posts and audio from the web to your Mac.")
            })
    }

    private func unavailableView(_ reason: String) -> some View {
        let missingTool = reason.contains("yt-dlp")
        return ScrollView {
            PageEmptyState(
                symbolName: missingTool ? "arrow.down.circle" : "exclamationmark.triangle",
                title: missingTool
                    ? "Set up Downloads once to get started" : "Downloads can't start yet",
                message: missingTool
                    ? "Downloads uses yt-dlp, a free open source tool, to save media from YouTube, Instagram, TikTok, X and more. Install it once and you are ready."
                    : reason,
                steps: missingTool
                    ? [
                        PageGuideStep(
                            symbolName: "wrench.and.screwdriver", title: "Install yt-dlp",
                            detail: "Open setup and press Install. It takes under a minute."),
                        PageGuideStep(
                            symbolName: "link", title: "Paste a link",
                            detail: "Copy any video or post link and paste it here."),
                        PageGuideStep(
                            symbolName: "arrow.down.circle", title: "Download",
                            detail: "Files are saved to a folder you choose."),
                    ] : [],
                primary: PageAction(
                    missingTool ? "Set up Downloads" : "Open settings",
                    symbolName: "gearshape", identifier: "downloads.setup"
                ) { settingsPresented = true },
                secondary: PageAction("Check again", symbolName: "arrow.clockwise") {
                    downloader.checkAvailability()
                },
                footnote: "Nothing is downloaded until you paste a link and press Download."
            )
            .frame(maxWidth: .infinity)
            .padding(.top, UIScale.pt(PageMetrics.pinnedContentTop))
        }
        .scrollIndicators(.automatic)
        .edithSheet(isPresented: $settingsPresented) {
            DownloadsSettings(downloader: downloader)
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if downloader.items.isEmpty {
                ScrollView {
                    listHeader
                }
                .scrollIndicators(.automatic)
            } else {
                VirtualList(
                    listRows,
                    rowHeight: { DownloadRowMetrics.height(of: $0) },
                    header: { listHeader }
                ) { row in
                    downloadRow(row)
                }
            }
        }
        .edithSheet(item: $logItem) { item in
            logSheet(item)
        }
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

    private var listRows: [DownloadListRow] {
        let items = downloader.items
        let appearance = "\(dark)-\(themeName)"
        let running = downloader.isRunning
        return items.enumerated().map { index, item in
            DownloadListRow(
                item: item, first: index == 0, last: index == items.count - 1,
                running: running, appearance: appearance)
        }
    }

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(32)) {
            VStack(alignment: .leading, spacing: UIScale.pt(20)) {
                urlInput
                formatRow
                Divider().overlay(DashSkin.line(dark))
                destinationRow
                if downloadKind == .audio || downloadKind == .video { optionsRow }
                Divider().overlay(DashSkin.line(dark))
                startRow
            }
            .padding(UIScale.pt(20))
            .background(
                DashSkin.paper2(dark),
                in: RoundedRectangle(cornerRadius: UIScale.pt(PageMetrics.cardCornerRadius))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(PageMetrics.cardCornerRadius))
                    .strokeBorder(DashSkin.line(dark))
            )

            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                PageSectionHeader(
                    "Your downloads",
                    subtitle: downloader.items.isEmpty
                        ? "Nothing downloaded yet. Paste a link above to save your first file."
                        : summaryText
                ) {
                    listActions
                }
                if downloader.items.isEmpty {
                    PageGuideSteps(steps: Self.firstUseSteps, columns: compact ? 1 : 3)
                }
            }
            .padding(.bottom, UIScale.pt(downloader.items.isEmpty ? PageMetrics.bottom : 12))
        }
        .padding(.top, UIScale.pt(PageMetrics.pinnedContentTop))
        .frame(maxWidth: .infinity, alignment: .leading)
        .pageGutter(compact)
    }

    @ViewBuilder
    private var listActions: some View {
        if !downloader.items.isEmpty {
            HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                if downloader.items.contains(where: { $0.record.canRetry }) {
                    Button("Retry failed") { downloader.retryAll() }
                }
                if downloader.isRunning {
                    Button("Cancel all") { downloader.cancelAll() }
                } else {
                    Button("Clear history") { confirmClearHistory = true }
                        .help(
                            "Remove every entry from this list. Downloaded files stay on your Mac.")
                }
            }
            .buttonStyle(.edith(.toolbar))
            .font(.edithText(.callout))
        }
    }

    private func downloadRow(_ row: DownloadListRow) -> some View {
        itemRow(row.item)
            .padding(.horizontal, UIScale.pt(8))
            .padding(.top, UIScale.pt(row.first ? DownloadRowMetrics.groupInset : 0))
            .padding(.bottom, UIScale.pt(row.last ? DownloadRowMetrics.groupInset : 0))
            .frame(maxHeight: .infinity)
            .background(DownloadRowBackground(first: row.first, last: row.last, dark: dark))
            .padding(.bottom, row.last ? UIScale.pt(PageMetrics.bottom) : 0)
            .pageGutter(compact)
    }

    private var urlInput: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack(alignment: .center) {
                PageCapsLabel("Paste a link")
                Spacer()
                Button {
                    urlText = NSPasteboard.general.string(forType: .string) ?? urlText
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.edith(.toolbar))
                .font(.edithText(.callout))
                .help("Paste links from the clipboard")
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $urlText)
                    .font(.edithText(.body))
                    .foregroundStyle(DashSkin.ink(dark))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(height: UIScale.pt(56))
                    .accessibilityLabel("Media links")
                    .padding(.horizontal, UIScale.pt(8))
                    .padding(.vertical, UIScale.pt(8))
                if urlText.isEmpty {
                    Text("https://…  Add several links on separate lines.")
                        .font(.edithText(.body))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .padding(.horizontal, UIScale.pt(13))
                        .padding(.vertical, UIScale.pt(8))
                        .allowsHitTesting(false)
                }
            }
            .background(
                DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(10))
                    .strokeBorder(urlText.isEmpty ? DashSkin.line(dark) : DashSkin.lineStrong(dark))
            )
            Group {
                if parsedCount > 0 {
                    Label(
                        "\(parsedCount) link\(parsedCount == 1 ? "" : "s") ready",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.secondary)
                } else if !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(
                        "Enter a complete link that starts with http:// or https://",
                        systemImage: "exclamationmark.circle"
                    )
                    .foregroundStyle(.orange)
                } else {
                    Text("Works with YouTube, Instagram, TikTok, X, Reddit and many more sites.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.edithText(.caption))
            .lineLimit(1)
        }
    }

    private var formatRow: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            PageCapsLabel("Format")
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: UIScale.pt(8)),
                    count: compact ? 2 : 4),
                spacing: UIScale.pt(8)
            ) {
                ForEach(DownloadKind.allCases, id: \.rawValue) { kind in
                    formatButton(kind)
                }
            }
            if downloadKind == .video || downloadKind == .audio {
                HStack(spacing: UIScale.pt(8)) {
                    ForEach([DownloadKind.video, .audio], id: \.rawValue) { kind in
                        sizeChip(kind)
                    }
                    Spacer()
                }
            }
            Text(formatDescription)
                .font(.edithText(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pageTask(id: urlText + downloadKindRaw, cancel: { estimateLoad.cancel() }) {
            await refreshEstimate()
        }
    }

    private func formatButton(_ kind: DownloadKind) -> some View {
        let selected = downloadKind == kind
        return Button {
            downloadKindRaw = kind.rawValue
        } label: {
            Label(kind.title, systemImage: formatSymbol(kind))
                .font(.edithText(.callout).weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: UIScale.pt(36))
                .foregroundStyle(selected ? theme : DashSkin.inkSoft(dark))
                .background(
                    selected ? theme.opacity(dark ? 0.2 : 0.12) : DashSkin.paper(dark),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(8))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: UIScale.pt(8)).strokeBorder(
                        selected ? theme.opacity(0.55) : DashSkin.line(dark))
                )
                .contentShape(RoundedRectangle(cornerRadius: UIScale.pt(8)))
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var formatDescription: String {
        switch downloadKind {
        case .post: "Photos and videos together, including carousels. Up to 100 files per link."
        case .images: "Only images from a post or gallery, saved in their original format."
        case .audio: "Extract the audio track and save it as an M4A file."
        case .video: "Download the best available video with sound."
        }
    }

    private func formatSymbol(_ kind: DownloadKind) -> String {
        switch kind {
        case .post: "square.stack"
        case .images: "photo"
        case .audio: "waveform"
        case .video: "play.rectangle"
        }
    }

    private func sizeChip(_ kind: DownloadKind) -> some View {
        HStack(spacing: UIScale.pt(6)) {
            Image(systemName: kind == .audio ? "waveform" : "film")
            Text(kind.title)
            if estimating {
                SkeletonGroup {
                    SkeletonBlock(width: 36, height: 8, corner: 4)
                }
            } else {
                Text(sizeText(kind)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .pageChipChrome(active: kind == downloadKind, tint: theme)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func sizeText(_ kind: DownloadKind) -> String {
        guard let bytes = estimate?.bytes(for: kind) else {
            return estimating ? "…" : "Size unknown"
        }
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return (estimate?.approximate == true ? "~" : "") + formatted
    }

    private func refreshEstimate() async {
        guard downloadKind == .audio || downloadKind == .video else {
            estimate = nil
            estimateLoad.reset()
            return
        }
        do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
        let urls = YoutubeDownloader.parseURLs(from: urlText)
        guard !urls.isEmpty, downloader.unavailableReason == nil else {
            estimate = nil
            estimateLoad.reset()
            return
        }
        let request = estimateLoad.begin(preservingContent: false)
        defer {
            if Task.isCancelled {
                estimateLoad.cancel(request)
            } else {
                estimateLoad.complete(request)
            }
        }
        var total: DownloadEstimate?
        for url in urls.prefix(5) {
            guard estimateLoad.isCurrent(request) else { return }
            guard let one = await downloader.estimate(for: url) else { continue }
            guard estimateLoad.isCurrent(request) else { return }
            total = total.map { $0 + one } ?? one
            estimate = total
        }
        estimate = total
    }

    private var optionsRow: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            PageCapsLabel("Filename prefix")
            EdithTextField(placeholder: "Optional, for example roadtrip_", text: $filenamePrefix)
            Text(
                filenamePrefix.isEmpty
                    ? "Added to the start of every file name."
                    : "Saved as \(filenamePrefix)Title.\(downloadKind.fileExtension)"
            )
            .font(.edithText(.caption))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
    }

    private var startRow: some View {
        let layout =
            compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: UIScale.pt(12)))
            : AnyLayout(HStackLayout(alignment: .center, spacing: UIScale.pt(16)))
        return layout {
            Text(
                canStart
                    ? "Downloads keep going if you close this window."
                    : "Paste a link above to enable Download."
            )
            .font(.edithText(.caption))
            .foregroundStyle(.secondary)
            .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
            Button(action: startDownload) {
                Label(
                    parsedCount > 1 ? "Download \(parsedCount) links" : "Download",
                    systemImage: "arrow.down.circle"
                )
                .font(.edithText(.body).weight(.medium))
                .frame(maxWidth: compact ? .infinity : nil)
            }
            .buttonStyle(.edith(.primary))
            .disabled(!canStart)
            .keyboardShortcut(.defaultAction)
            .help(canStart ? "Start downloading" : "Paste a link above to enable Download")
        }
    }

    private var destinationRow: some View {
        let layout =
            compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: UIScale.pt(20)))
            : AnyLayout(HStackLayout(alignment: .top, spacing: UIScale.pt(16)))
        let folder = outputDirectory ?? downloader.defaultDirectory(for: downloadKind)
        return layout {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                PageCapsLabel("Save to")
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.directoryURL = folder
                    panel.begin { response in
                        if response == .OK { outputDirectory = panel.url }
                    }
                } label: {
                    HStack(spacing: UIScale.pt(8)) {
                        Image(systemName: "folder")
                        Text(folder.lastPathComponent).lineLimit(1)
                        Spacer(minLength: UIScale.pt(8))
                        Text("Change…").foregroundStyle(.secondary)
                    }
                    .font(.edithText(.callout))
                    .padding(.horizontal, UIScale.pt(10))
                    .frame(height: UIScale.pt(PageMetrics.controlHeight))
                    .background(
                        DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(8))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: UIScale.pt(8))
                            .strokeBorder(DashSkin.line(dark))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: UIScale.pt(8)))
                }
                .buttonStyle(.edith(.borderless))
                .help(folder.path)
                Text("Where finished files are saved.")
                    .font(.edithText(.caption))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                PageCapsLabel("Login cookies")
                Picker("Login cookies", selection: $browser) {
                    Text("None (public media)").tag("")
                    ForEach(DownloadBrowser.allCases, id: \.rawValue) { source in
                        Text(source.rawValue.capitalized).tag(source.rawValue)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: UIScale.pt(PageMetrics.controlHeight))
                Text("Only for private posts that need you to be signed in.")
                    .font(.edithText(.caption))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let firstUseSteps = [
        PageGuideStep(
            symbolName: "link", title: "Paste a link",
            detail: "Videos, photos or posts from YouTube, Instagram, TikTok, X and more."),
        PageGuideStep(
            symbolName: "square.stack", title: "Pick what to save",
            detail: "Everything in a post, just images, audio only, or video."),
        PageGuideStep(
            symbolName: "arrow.down.circle", title: "Press Download",
            detail: "Files are saved to the folder shown under Save to."),
    ]

    private func itemRow(_ item: YoutubeDownloader.DownloadItem) -> some View {
        HStack(spacing: UIScale.pt(12)) {
            Button {
                if case .done = item.status {
                    downloader.openResult(item)
                } else {
                    logItem = item
                }
            } label: {
                HStack(spacing: UIScale.pt(12)) {
                    statusIcon(item.status)
                        .frame(width: UIScale.pt(20), height: UIScale.pt(20))
                    DownloadThumb(url: item.url, dark: dark, height: UIScale.pt(32))
                    VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                        Text(item.resolvedTitle ?? displayURL(item.url))
                            .font(.edithText(.callout).weight(.medium))
                            .foregroundStyle(DashSkin.ink(dark))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        statusDetail(item)
                    }
                    Spacer(minLength: UIScale.pt(8))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .help(statusHelp(item))
            itemActions(item)
        }
        .padding(.horizontal, UIScale.pt(10))
        .frame(height: UIScale.pt(DownloadRowMetrics.rowHeight))
    }

    @ViewBuilder
    private func statusIcon(_ status: DownloadStatus) -> some View {
        switch status {
        case .queued:
            Image(systemName: "clock")
                .font(.system(size: UIScale.pt(14)))
                .foregroundStyle(DashSkin.inkFaint(dark))
        case .resolving, .downloading:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: UIScale.pt(16)))
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: UIScale.pt(16)))
                .foregroundStyle(.red)
        case .interrupted:
            Image(systemName: "pause.circle.fill")
                .font(.system(size: UIScale.pt(16)))
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func statusDetail(_ item: YoutubeDownloader.DownloadItem) -> some View {
        switch item.status {
        case .queued:
            detailText("Waiting to start", color: .secondary)
        case .resolving:
            detailText("Finding media…", color: .secondary)
        case let .downloading(progress, videoIndex, videoCount):
            HStack(spacing: UIScale.pt(8)) {
                if let fraction = DownloadRowMetrics.fraction(from: progress) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(theme)
                        .frame(width: UIScale.pt(compact ? 72 : 120))
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.edithText(.caption).weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(theme)
                }
                Text(
                    [
                        videoCount > 1 ? "\(videoIndex) of \(videoCount)" : nil,
                        DownloadRowMetrics.detail(from: progress),
                    ]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                )
                .font(.edithText(.caption))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        case .done:
            detailText(displayURL(item.url), color: .secondary)
        case let .error(message):
            detailText(message, color: .red)
        case let .interrupted(reason):
            detailText(reason ?? "Paused", color: .orange)
        }
    }

    private func detailText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.edithText(.caption))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func statusHelp(_ item: YoutubeDownloader.DownloadItem) -> String {
        switch item.status {
        case .done: "Open the downloaded file"
        case let .error(message): "\(message) Click to see the download log."
        default: "Show the download log"
        }
    }

    @ViewBuilder
    private func itemActions(_ item: YoutubeDownloader.DownloadItem) -> some View {
        HStack(spacing: UIScale.pt(4)) {
            switch item.status {
            case .queued, .resolving, .downloading:
                Button {
                    downloader.cancel(item)
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Cancel this download")
                .accessibilityLabel("Cancel download")
            case .error, .interrupted:
                Button("Retry") { downloader.retry(item) }
                    .font(.edithText(.callout).weight(.medium))
                    .foregroundStyle(theme)
                    .disabled(downloader.isRunning)
                    .help(
                        downloader.isRunning
                            ? "Wait for active downloads to finish" : "Try this download again")
                removeButton(item)
            case .done:
                Button {
                    downloader.openResult(item)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .help("Open downloaded file")
                .accessibilityLabel("Open downloaded file")
                Button {
                    downloader.revealResult(item)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
                removeButton(item)
            }
        }
        .buttonStyle(.edith(.iconOnly))
        .font(.edithText(.callout))
    }

    private func removeButton(_ item: YoutubeDownloader.DownloadItem) -> some View {
        Button {
            downloader.remove(item)
        } label: {
            Image(systemName: "trash")
        }
        .help("Remove from the list. The file stays on your Mac.")
        .accessibilityLabel("Remove from list")
    }

    private func logSheet(_ item: YoutubeDownloader.DownloadItem) -> some View {
        let live = downloader.items.first(where: { $0.id == item.id }) ?? item
        return VStack(spacing: UIScale.pt(0)) {
            HStack {
                Text("Download Log")
                    .font(DashSkin.heading(16))
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
                .buttonStyle(.edith(.toolbar))
            }
            .padding(.horizontal, UIScale.pt(20))
            .padding(.vertical, UIScale.pt(12))

            Divider().overlay(DashSkin.line(dark))

            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if !live.logs.isEmpty {
                            Text(live.logs)
                        } else if isActiveLog(live) {
                            SkeletonGroup {
                                VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                                    ForEach(0..<7, id: \.self) { index in
                                        SkeletonBlock(
                                            width: [286, 410, 344, 426, 238, 382, 304][index],
                                            height: 8,
                                            corner: 3)
                                    }
                                }
                            }
                            .accessibilityLabel("Waiting for download output")
                        } else {
                            Text("No output was captured.")
                        }
                    }
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
        .frame(width: PresentationMetrics.width(480), height: PresentationMetrics.height(360))
        .background(DashSkin.paper(dark))
    }

    private func isActiveLog(_ item: YoutubeDownloader.DownloadItem) -> Bool {
        switch item.status {
        case .queued, .resolving, .downloading: true
        case .done, .error, .interrupted: false
        }
    }

    private func displayURL(_ url: URL) -> String {
        (url.host ?? "") + (url.port.map { ":\($0)" } ?? "") + url.path
    }

    private func startDownload() {
        let urls = YoutubeDownloader.parseURLs(from: urlText)
        guard !urls.isEmpty else { return }
        downloader.enqueue(
            urls: urls, prefix: filenamePrefix, kind: downloadKind,
            outputDirectory: outputDirectory, browser: DownloadBrowser(rawValue: browser))
        urlText = ""
    }
}

private struct DownloadThumb: View {
    let url: URL
    let dark: Bool
    var height: CGFloat = 32

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: UIScale.pt(5)).fill(DashSkin.paper(dark))
            if let thumb = MediaDownloadInput.isDirectImage(url)
                ? url : YoutubeDownloader.thumbnailURL(for: url)
            {
                AsyncImage(url: thumb) { phase in
                    switch phase {
                    case .empty:
                        SkeletonGroup {
                            SkeletonBlock(
                                width: Double(height) * 16 / 9 / UIScale.current,
                                height: Double(height) / UIScale.current,
                                corner: 5)
                        }
                    case let .success(image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
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
