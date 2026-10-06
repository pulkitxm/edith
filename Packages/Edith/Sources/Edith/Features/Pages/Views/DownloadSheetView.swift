import AppKit
import EdithKit
import SwiftUI

struct DownloadSheet: View {
    var isPage = false
    @State private var downloader = YoutubeDownloader.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @Environment(\.colorScheme) private var scheme
    @State private var urlText = ""
    @State private var filenamePrefix = ""
    @State private var logItem: YoutubeDownloader.DownloadItem?
    @State private var confirmClearHistory = false
    @AppStorage(AppStorageKeys.Music.downloadKind, store: SharedDefaults.store) private
        var downloadKindRaw =
        DownloadKind.post.rawValue
    @State private var estimate: DownloadEstimate?
    @State private var estimateLoad = ContentLoad()
    private var estimating: Bool { estimateLoad.isRunning }
    @State private var outputDirectory: URL?
    @State private var browser = ""

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
        if done > 0 { parts.append("\(done) done") }
        if active > 0 { parts.append("\(active) active") }
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
        HStack(spacing: UIScale.pt(10)) {
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                Text("Downloads")
                    .font(DashSkin.heading(22))
                    .foregroundStyle(DashSkin.ink(dark))
                Text("Videos, photos and posts. Saved to your Mac.")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(.secondary)
            }
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
            .buttonStyle(.edith(.toolbar))
            .disabled(downloader.isRunning || downloader.isUpdatingYTDLP)
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
            if !isPage {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: UIScale.pt(12), weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: UIScale.pt(22), height: UIScale.pt(22))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.edith(.toolbar))
            }
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
            Button("Open extension settings") { SectionWindow.open(.extensions) }
                .buttonStyle(.edith(.toolbar))
            Button("Check again") { downloader.checkAvailability() }
                .buttonStyle(.edith(.toolbar))
            Spacer()
        }
        .padding(.horizontal, UIScale.pt(40))
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(22)) {
                VStack(alignment: .leading, spacing: UIScale.pt(18)) {
                    urlInput
                    formatRow
                    Divider().overlay(DashSkin.line(dark))
                    destinationRow
                    if downloadKind == .audio || downloadKind == .video { optionsRow }
                    startRow
                }
                .padding(UIScale.pt(20))
                .background(
                    DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: UIScale.pt(14)).strokeBorder(DashSkin.line(dark))
                )

                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    HStack {
                        Text("Your downloads")
                            .font(DashSkin.heading(15))
                        Text("\(downloader.items.count)")
                            .font(.system(size: UIScale.pt(11), weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, UIScale.pt(7))
                            .padding(.vertical, UIScale.pt(3))
                            .background(DashSkin.paper2(dark), in: Capsule())
                        Spacer()
                        if !summaryText.isEmpty {
                            Text(summaryText)
                                .font(.system(size: UIScale.pt(11)))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, UIScale.pt(6))
                    if downloader.items.isEmpty {
                        emptyState.frame(height: UIScale.pt(100))
                            .frame(maxWidth: .infinity)
                    } else {
                        LazyVStack(spacing: UIScale.pt(4)) {
                            ForEach(downloader.items) { item in
                                switch item.status {
                                case .queued, .resolving, .downloading, .error: queueCard(item)
                                case .done, .interrupted: historyRow(item)
                                }
                            }
                        }
                        .padding(UIScale.pt(8))
                        .background(
                            DashSkin.paper2(dark),
                            in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
                        controlsRow
                    }
                }
            }
            .frame(maxWidth: UIScale.pt(860), alignment: .leading)
            .padding(UIScale.pt(22))
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .edithSheet(item: $logItem) { item in
            logSheet(item)
        }
    }

    private var urlInput: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            HStack {
                label("PASTE A LINK")
                Spacer()
                Button {
                    urlText = NSPasteboard.general.string(forType: .string) ?? urlText
                } label: {
                    Label("Paste", systemImage: "clipboard")
                        .font(.system(size: UIScale.pt(11)))
                }
                .buttonStyle(.edith(.toolbar))
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $urlText)
                    .font(.system(size: UIScale.pt(13), design: .monospaced))
                    .foregroundStyle(DashSkin.ink(dark))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(height: UIScale.pt(54))
                    .accessibilityLabel("Media links")
                    .padding(.horizontal, UIScale.pt(10))
                    .padding(.vertical, UIScale.pt(8))
                if urlText.isEmpty {
                    Text("https://…\nAdd several links on separate lines")
                        .font(.system(size: UIScale.pt(12.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .padding(.horizontal, UIScale.pt(14))
                        .padding(.vertical, UIScale.pt(10))
                        .allowsHitTesting(false)
                }
            }
            .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
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
                        Text("\(parsedCount) web link\(parsedCount == 1 ? "" : "s")")
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(.secondary)
                    }
                } else if !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Enter a complete http:// or https:// link")
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(.orange)
                } else {
                    Text("YouTube · Instagram · TikTok · X · Reddit · and more")
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(height: UIScale.pt(16))
        }
    }

    private var formatRow: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            label("FORMAT")
            HStack(spacing: UIScale.pt(8)) {
                ForEach(DownloadKind.allCases, id: \.rawValue) { kind in
                    Button {
                        downloadKindRaw = kind.rawValue
                    } label: {
                        Label(kind.title, systemImage: formatSymbol(kind))
                            .font(.system(size: UIScale.pt(12), weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, UIScale.pt(10))
                            .foregroundStyle(downloadKind == kind ? theme : DashSkin.inkSoft(dark))
                            .background(
                                downloadKind == kind ? theme.opacity(0.12) : DashSkin.paper(dark),
                                in: RoundedRectangle(cornerRadius: UIScale.pt(8))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: UIScale.pt(8)).strokeBorder(
                                    downloadKind == kind ? theme.opacity(0.55) : DashSkin.line(dark)
                                ))
                    }
                    .buttonStyle(.edith(.borderless))
                    .accessibilityAddTraits(downloadKind == kind ? .isSelected : [])
                }
            }
            if downloadKind == .video || downloadKind == .audio {
                HStack(spacing: UIScale.pt(10)) {
                    ForEach([DownloadKind.video, .audio], id: \.rawValue) { kind in
                        sizeChip(kind)
                    }
                    Spacer()
                }
                .font(.system(size: UIScale.pt(11)))
            }
            Text(formatDescription)
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pageTask(id: urlText + downloadKindRaw, cancel: { estimateLoad.cancel() }) {
            await refreshEstimate()
        }
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
        let selected = kind == downloadKind
        return HStack(spacing: UIScale.pt(4)) {
            Image(systemName: kind == .audio ? "waveform" : "film")
            Text(kind.title)
            if estimating {
                SkeletonGroup {
                    SkeletonBlock(width: 34, height: 8, corner: 4)
                }
            } else {
                Text(sizeText(kind))
            }
        }
        .foregroundStyle(selected ? theme : Color.secondary)
        .padding(.horizontal, UIScale.pt(8))
        .padding(.vertical, UIScale.pt(4))
        .background(
            selected ? theme.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: UIScale.pt(6)))
    }

    private func sizeText(_ kind: DownloadKind) -> String {
        guard let bytes = estimate?.bytes(for: kind) else { return estimating ? "…" : "-" }
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return (estimate?.approximate == true ? "~" : "") + formatted
    }

    private func refreshEstimate() async {
        guard downloadKind == .audio || downloadKind == .video else {
            estimate = nil
            estimateLoad.reset()
            return
        }
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
        HStack(spacing: UIScale.pt(12)) {
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                label("FILENAME PREFIX")
                EdithTextField(
                    placeholder: "Optional, e.g. roadtrip_", text: $filenamePrefix)
            }
            if !filenamePrefix.isEmpty {
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    label("PREVIEW")
                    Text("\(filenamePrefix)Title.\(downloadKind.fileExtension)")
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
            Text(
                "Downloads continue when you close this window."
            )
            .font(.system(size: UIScale.pt(10.5)))
            .foregroundStyle(.secondary)
            Spacer()
            Button(action: startDownload) {
                HStack(spacing: UIScale.pt(6)) {
                    Image(systemName: "arrow.down.circle")
                    Text(parsedCount > 1 ? "Download \(parsedCount) links" : "Download")
                        .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, UIScale.pt(18))
                .padding(.vertical, UIScale.pt(9))
                .background(canStart ? theme : Color.gray.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(9)))
            }
            .buttonStyle(.edith(.borderless))
            .disabled(!canStart)
        }
    }

    private var destinationRow: some View {
        HStack(alignment: .top, spacing: UIScale.pt(16)) {
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                label("SAVE TO")
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.directoryURL =
                        outputDirectory ?? MediaDownloadInput.defaultDirectory(for: downloadKind)
                    panel.begin { response in
                        if response == .OK { outputDirectory = panel.url }
                    }
                } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text(
                            (outputDirectory
                                ?? MediaDownloadInput.defaultDirectory(for: downloadKind))
                                .lastPathComponent
                        )
                        .lineLimit(1)
                        Spacer()
                        Text("Change…").foregroundStyle(.secondary)
                    }
                    .font(.system(size: UIScale.pt(12)))
                    .padding(UIScale.pt(8))
                    .background(
                        DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(7)))
                }
                .buttonStyle(.edith(.borderless))
                .help(
                    (outputDirectory ?? MediaDownloadInput.defaultDirectory(for: downloadKind)).path
                )
                Text("Choose where completed files are saved.")
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                label("LOGIN COOKIES")
                Picker("Login cookies", selection: $browser) {
                    Text("None (public media)").tag("")
                    ForEach(DownloadBrowser.allCases, id: \.rawValue) { source in
                        Text(source.rawValue.capitalized).tag(source.rawValue)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, minHeight: UIScale.pt(32), alignment: .leading)
                Text("For posts that need a signed-in account.")
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        let actionInset: CGFloat
        switch item.status {
        case .done: actionInset = UIScale.pt(64)
        case .error, .interrupted: actionInset = UIScale.pt(48)
        default: actionInset = UIScale.pt(34)
        }

        return ZStack(alignment: .trailing) {
            Button {
                if case .done = item.status {
                    downloader.openResult(item)
                } else {
                    logItem = item
                }
            } label: {
                HStack(spacing: UIScale.pt(10)) {
                    Group {
                        switch item.status {
                        case .queued:
                            Image(systemName: "clock")
                                .font(.system(size: UIScale.pt(12)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                        case .resolving:
                            SkeletonGroup {
                                SkeletonBlock(width: 15, height: 15, corner: 8)
                            }
                        case .downloading:
                            SkeletonGroup {
                                SkeletonBlock(width: 15, height: 15, corner: 8)
                            }
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
                                                size: UIScale.pt(11), weight: .medium,
                                                design: .monospaced)
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, UIScale.pt(8))
                .padding(.leading, UIScale.pt(10))
                .padding(.trailing, UIScale.pt(10) + actionInset)
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
            }
            .buttonStyle(.edith(.borderless))

            Group {
                switch item.status {
                case .queued, .resolving, .downloading:
                    Button {
                        downloader.cancel(item)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.edith(.toolbar))
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.red)
                    .help("Cancel this download")
                case .error, .interrupted:
                    Button("Retry") {
                        downloader.retry(item)
                    }
                    .buttonStyle(.edith(.toolbar))
                    .font(.system(size: UIScale.pt(10), weight: .medium))
                    .foregroundStyle(theme)
                    .disabled(downloader.isRunning)
                case .done:
                    HStack(spacing: UIScale.pt(4)) {
                        Button {
                            downloader.openResult(item)
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .help("Open downloaded file")
                        Button {
                            downloader.revealResult(item)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Reveal downloaded file")
                    }
                    .buttonStyle(.edith(.toolbar))
                    .font(.system(size: UIScale.pt(11)))
                }
            }
            .padding(.trailing, UIScale.pt(10))
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
                .buttonStyle(.edith(.toolbar))
                .font(.system(size: UIScale.pt(10), weight: .medium))
                .foregroundStyle(theme)
                .disabled(downloader.isRunning)
            case .done:
                HStack(spacing: UIScale.pt(4)) {
                    Button {
                        downloader.openResult(item)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .help("Open downloaded file")
                    Button {
                        downloader.revealResult(item)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Reveal downloaded file")
                }
                .buttonStyle(.edith(.toolbar))
                .font(.system(size: UIScale.pt(11)))
            default:
                EmptyView()
            }

            Button {
                downloader.remove(item)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.edith(.toolbar))
            .font(.system(size: UIScale.pt(11)))
            .foregroundStyle(.red)
            .help("Remove from download history")
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

    private var controlsRow: some View {
        HStack(spacing: UIScale.pt(8)) {
            if downloader.items.contains(where: { $0.record.canRetry }) {
                Button("Retry failed") { downloader.retryAll() }
                    .buttonStyle(.edith(.toolbar))
                    .font(.system(size: UIScale.pt(11)))
            }
            if !downloader.items.isEmpty {
                Button("Clear History") {
                    confirmClearHistory = true
                }
                .buttonStyle(.edith(.toolbar))
                .font(.system(size: UIScale.pt(11)))
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
                .buttonStyle(.edith(.toolbar))
            }
            Spacer()
            if !isPage {
                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.edith(.toolbar))
                .font(.system(size: UIScale.pt(11)))
            }
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
            RoundedRectangle(cornerRadius: UIScale.pt(5)).fill(DashSkin.paper2(dark))
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
