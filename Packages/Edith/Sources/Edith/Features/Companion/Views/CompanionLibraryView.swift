import AVFoundation
import AppKit
import EdithKit
import Observation
import PDFKit
import SwiftUI

@MainActor
@Observable
final class CompanionLibraryModel: CompanionRefreshable {
    var dropTargeted = false
    var query = ""
    private(set) var episodes: [CompanionEpisode] = []
    private(set) var hits: [CompanionSearchHit] = []
    private(set) var ingesting = false
    private(set) var ingestSummary: String?
    private(set) var indexing = false
    private(set) var selectedId: String?
    private(set) var detail: CompanionEpisodeDetail?
    private(set) var signals: [CompanionSignal] = []
    private(set) var media: Data?
    private(set) var loadingDetail = false
    private(set) var error: String?
    let playback = AudioPlayback()
    private var searchTask: Task<Void, Never>?

    private var client: CompanionClient {
        CompanionClient(baseURL: CompanionClient.endpoint(override: nil))
    }

    func refresh() async {
        do {
            episodes = try await client.episodes(limit: 60)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func searchChanged() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hits = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                let found = try await client.search(query: trimmed, k: 12)
                guard !Task.isCancelled else { return }
                hits = found
                error = nil
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func select(_ id: String) async {
        guard selectedId != id else { return }
        playback.stop()
        selectedId = id
        detail = nil
        signals = []
        media = nil
        loadingDetail = true
        defer { loadingDetail = false }
        do {
            let client = client
            detail = try await client.episodeDetail(id: id)
            let kind = detail?.kind ?? ""
            if kind == "voice" {
                signals = (try? await client.signals(episodeId: id)) ?? []
            }
            if kind == "voice" || kind == "pdf" {
                let (data, _) = try await client.media(episodeId: id)
                media = data
                if kind == "voice" { playback.load(data) }
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func closeDetail() {
        playback.stop()
        selectedId = nil
        detail = nil
        signals = []
        media = nil
    }

    func openExternally() async {
        guard let detail else { return }
        do {
            let (data, contentType) = try await client.media(episodeId: detail.id)
            let url = try CompanionMedia.temporaryFile(
                title: detail.title, contentType: contentType, data: data)
            NSWorkspace.shared.open(url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func indexNow() async {
        indexing = true
        defer { indexing = false }
        do {
            _ = try await client.index()
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func ingest(urls: [URL]) async {
        guard !urls.isEmpty, !ingesting else { return }
        ingesting = true
        defer { ingesting = false }
        var ingested = 0
        var duplicates = 0
        var skipped = 0
        var failed: [String] = []
        let client = client
        for url in urls {
            guard let scanned = scan(url, skipped: &skipped, failed: &failed) else { continue }
            if !scanned.markdown.isEmpty {
                do {
                    let outcomes = try await client.ingest(files: scanned.markdown)
                    ingested += outcomes.filter { $0.status == "ingested" }.count
                    duplicates += outcomes.filter { $0.status == "duplicate" }.count
                } catch {
                    failed.append(url.lastPathComponent)
                }
            }
            for file in scanned.binaries {
                do {
                    let outcome = try await file.send(client)
                    if outcome.status == "ingested" { ingested += 1 } else { duplicates += 1 }
                } catch {
                    failed.append(file.name)
                }
            }
        }
        ingestSummary = summary(
            ingested: ingested, duplicates: duplicates, skipped: skipped, failed: failed)
        error = failed.isEmpty ? nil : "Could not ingest \(failed.joined(separator: ", "))"
        await refresh()
    }

    private struct BinaryIngest {
        let name: String
        let data: Data
        let mtime: String?
        let kind: Kind

        enum Kind { case audio, pdf, image, video }

        func send(_ client: CompanionClient) async throws -> CompanionIngestOutcome {
            switch kind {
            case .audio: try await client.ingestAudio(name: name, data: data, mtime: mtime)
            case .pdf: try await client.ingestPdf(name: name, data: data, mtime: mtime)
            case .image: try await client.ingestImage(name: name, data: data, mtime: mtime)
            case .video: try await client.ingestVideo(name: name, data: data, mtime: mtime)
            }
        }
    }

    private func scan(
        _ url: URL, skipped: inout Int, failed: inout [String]
    ) -> (markdown: [CompanionIngestFile], binaries: [BinaryIngest])? {
        do {
            let markdown = try CompanionScan.markdownFiles(at: url)
            let audio = try CompanionScan.audioFiles(at: url)
            let pdfs = try CompanionScan.pdfFiles(at: url)
            let images = try CompanionScan.imageFiles(at: url)
            let videos = try CompanionScan.videoFiles(at: url)
            skipped +=
                markdown.skipped.count + audio.skipped.count + pdfs.skipped.count
                + images.skipped.count + videos.skipped.count
            var binaries = audio.files.map {
                BinaryIngest(name: $0.name, data: $0.data, mtime: $0.mtime, kind: .audio)
            }
            binaries += pdfs.files.map {
                BinaryIngest(name: $0.name, data: $0.data, mtime: $0.mtime, kind: .pdf)
            }
            binaries += images.files.map {
                BinaryIngest(name: $0.name, data: $0.data, mtime: $0.mtime, kind: .image)
            }
            binaries += videos.files.map {
                BinaryIngest(name: $0.name, data: $0.data, mtime: $0.mtime, kind: .video)
            }
            return (markdown.files, binaries)
        } catch {
            failed.append(url.lastPathComponent)
            return nil
        }
    }

    private func summary(ingested: Int, duplicates: Int, skipped: Int, failed: [String]) -> String {
        var parts = ["\(ingested) ingested", "\(duplicates) duplicates", "\(skipped) skipped"]
        if !failed.isEmpty { parts.append("\(failed.count) failed") }
        return parts.joined(separator: ", ")
    }
}

@MainActor
@Observable
final class AudioPlayback {
    private(set) var playing = false
    private(set) var progress: Double = 0
    private(set) var currentTime: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    var duration: TimeInterval { player?.duration ?? 0 }
    var loaded: Bool { player != nil }

    func load(_ data: Data) {
        stop()
        player = try? AVAudioPlayer(data: data)
    }

    func toggle() {
        guard let player else { return }
        if playing {
            player.pause()
            playing = false
            timer?.invalidate()
        } else {
            player.play()
            playing = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = false
        progress = 0
        currentTime = 0
        timer?.invalidate()
    }

    private func refresh() {
        guard let player else { return }
        currentTime = player.currentTime
        progress = player.duration > 0 ? player.currentTime / player.duration : 0
        if playing, !player.isPlaying {
            playing = false
            progress = 0
            currentTime = 0
            timer?.invalidate()
        }
    }
}

struct CompanionLibraryScreen: View {
    @Bindable var model: CompanionLibraryModel
    let home: CompanionHomeModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionRequestsEnabled) private var requestsEnabled
    @Environment(\.companionGeneration) private var generation

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            stats
            HStack(alignment: .top, spacing: UIScale.pt(12)) {
                listColumn
                if model.selectedId != nil {
                    detailColumn
                }
            }
            if let error = model.error {
                Text(error)
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(.orange)
            }
        }
        .pageContent(compact)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: generation) {
            if requestsEnabled { await model.refresh() }
        }
        .onChange(of: model.query) {
            model.searchChanged()
        }
    }

    private var stats: some View {
        HStack(spacing: UIScale.pt(10)) {
            statTile(value: "\(home.status?.episodes ?? 0)", label: "episodes")
            statTile(value: "\(home.status?.chunks ?? 0)", label: "chunks")
            pendingTile
            Button {
                pickAndIngest()
            } label: {
                statTile(
                    value: model.ingesting ? "ingesting…" : (model.ingestSummary ?? "browse…"),
                    label: model.ingesting ? "hold on" : "add to memory")
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(model.ingesting)
            .help(
                "Pick Markdown notes, voice recordings, or PDFs; dropping files anywhere works too")
        }
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(1)) {
            Text(value)
                .font(DashSkin.serif(UIScale.pt(17), weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
                .lineLimit(1)
            Text(label.uppercased())
                .font(.system(size: UIScale.pt(9.5), weight: .medium))
                .tracking(0.6)
                .foregroundStyle(DashSkin.inkFaint(dark))
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(10)).strokeBorder(DashSkin.line(dark))
        }
    }

    private var pendingTile: some View {
        let pending = home.status?.pendingEpisodes ?? 0
        return VStack(alignment: .leading, spacing: UIScale.pt(1)) {
            Text("\(pending)")
                .font(DashSkin.serif(UIScale.pt(17), weight: .semibold))
                .foregroundStyle(pending > 0 ? .orange : DashSkin.ink(dark))
            HStack(spacing: UIScale.pt(5)) {
                Text("PENDING")
                    .font(.system(size: UIScale.pt(9.5), weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(DashSkin.inkFaint(dark))
                if pending > 0 {
                    Button(model.indexing ? "indexing…" : "index now") {
                        Task { await model.indexNow() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: UIScale.pt(9.5), weight: .bold))
                    .foregroundStyle(DashSkin.accent(dark))
                    .pointerCursor()
                    .disabled(model.indexing)
                }
            }
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(10))
                .strokeBorder(pending > 0 ? Color.orange.opacity(0.6) : DashSkin.line(dark))
        }
    }

    private func pickAndIngest() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Pick Markdown notes, voice recordings, PDFs, or folders of them"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            await model.ingest(urls: urls)
            await home.refresh()
        }
    }

    private var listColumn: some View {
        VStack(spacing: UIScale.pt(6)) {
            SearchField(placeholder: "Search your memory", text: $model.query)
            ScrollView {
                VStack(spacing: UIScale.pt(6)) {
                    if !model.hits.isEmpty {
                        ForEach(model.hits, id: \.chunkId) { hit in
                            hitRow(hit)
                        }
                    } else if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ForEach(model.episodes, id: \.id) { episode in
                            episodeRow(episode)
                        }
                        if model.episodes.isEmpty {
                            Text("Nothing ingested yet. Drop files above to give it memory.")
                                .font(.system(size: UIScale.pt(12)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .padding(.top, UIScale.pt(12))
                        }
                    } else {
                        Text("Nothing in the memory matches that.")
                            .font(.system(size: UIScale.pt(12)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .padding(.top, UIScale.pt(12))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func episodeRow(_ episode: CompanionEpisode) -> some View {
        Button {
            Task { await model.select(episode.id) }
        } label: {
            HStack(spacing: UIScale.pt(9)) {
                kindChip(episode.kind)
                Text(episode.title)
                    .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(String(episode.occurredAt.prefix(10)))
                    .font(.system(size: UIScale.pt(11)))
                    .monospacedDigit()
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            .padding(.horizontal, UIScale.pt(11))
            .padding(.vertical, UIScale.pt(7))
            .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(10))
                    .strokeBorder(
                        model.selectedId == episode.id
                            ? DashSkin.accent(dark) : DashSkin.line(dark))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func hitRow(_ hit: CompanionSearchHit) -> some View {
        Button {
            Task { await model.select(hit.episodeId) }
        } label: {
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                HStack(spacing: UIScale.pt(8)) {
                    kindChip(hit.kind)
                    Text(hit.title)
                        .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                        .foregroundStyle(DashSkin.ink(dark))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(String(hit.occurredAt.prefix(10)))
                        .font(.system(size: UIScale.pt(11)))
                        .monospacedDigit()
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                Text(hit.snippet)
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(2)
            }
            .padding(.horizontal, UIScale.pt(11))
            .padding(.vertical, UIScale.pt(7))
            .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(10))
                    .strokeBorder(
                        model.selectedId == hit.episodeId
                            ? DashSkin.accent(dark) : DashSkin.line(dark))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func kindChip(_ kind: String) -> some View {
        Text(kind.uppercased())
            .font(.system(size: UIScale.pt(9), weight: .bold))
            .tracking(0.8)
            .foregroundStyle(DashSkin.inkFaint(dark))
            .padding(.horizontal, UIScale.pt(6))
            .padding(.vertical, UIScale.pt(2))
            .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(5)))
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(5)).strokeBorder(DashSkin.line(dark))
            }
    }

    private var detailColumn: some View {
        SkinCard(title: model.detail?.title ?? "Episode", dark: dark) {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                HStack {
                    if let detail = model.detail {
                        Text(detailMeta(detail))
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                    Spacer()
                    Button {
                        Task { await model.openExternally() }
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: UIScale.pt(12.5)))
                            .foregroundStyle(DashSkin.inkSoft(dark))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Open with the default app")
                    Button {
                        model.closeDetail()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: UIScale.pt(13)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Close")
                }
                if model.loadingDetail {
                    ProgressView().controlSize(.small)
                } else if let detail = model.detail {
                    preview(detail)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func detailMeta(_ detail: CompanionEpisodeDetail) -> String {
        var parts = [detail.kind, String(detail.occurredAt.prefix(10))]
        if let duration = detail.durationS, duration > 0 {
            parts.append(durationLabel(duration))
        }
        if !detail.langs.isEmpty {
            parts.append(detail.langs.joined(separator: " + "))
        }
        parts.append("\(detail.chunks) chunks")
        return parts.joined(separator: " · ")
    }

    private func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @ViewBuilder
    private func preview(_ detail: CompanionEpisodeDetail) -> some View {
        switch detail.kind {
        case "voice":
            voicePreview(detail)
        case "pdf":
            pdfPreview(detail)
        default:
            ScrollView {
                MarkdownBody(text: detail.body ?? "", dark: dark)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: UIScale.pt(340))
        }
    }

    @ViewBuilder
    private func voicePreview(_ detail: CompanionEpisodeDetail) -> some View {
        VoicePlayerBar(playback: model.playback, dark: dark)
        ScrollView {
            Text(detail.body ?? "")
                .font(.system(size: UIScale.pt(12.5)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: UIScale.pt(220))
        signalBars
    }

    @ViewBuilder
    private func pdfPreview(_ detail: CompanionEpisodeDetail) -> some View {
        if let media = model.media {
            PdfPreview(data: media)
                .frame(height: UIScale.pt(320))
                .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(8)))
                .overlay {
                    RoundedRectangle(cornerRadius: UIScale.pt(8))
                        .strokeBorder(DashSkin.line(dark))
                }
        } else {
            ScrollView {
                Text(detail.body ?? "")
                    .font(.system(size: UIScale.pt(12.5)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: UIScale.pt(320))
        }
    }

    private var signalBars: some View {
        let pauses = model.signals.filter { $0.kind == "pause_s" }
        let wpm = model.signals.filter { $0.kind == "wpm" }.map(\.value)
        let ratio = model.signals.filter { $0.kind == "speech_ratio" }.map(\.value)
        return VStack(alignment: .leading, spacing: UIScale.pt(5)) {
            if !pauses.isEmpty {
                signalBar(
                    label: "pauses",
                    detail:
                        "\(pauses.count) over \(durationLabel(pauses.map(\.value).reduce(0, +)))",
                    fraction: min(Double(pauses.count) / 12, 1))
            }
            if !wpm.isEmpty {
                let mean = wpm.reduce(0, +) / Double(wpm.count)
                signalBar(
                    label: "pace", detail: "\(Int(mean)) wpm", fraction: min(mean / 200, 1))
            }
            if !ratio.isEmpty {
                let mean = ratio.reduce(0, +) / Double(ratio.count)
                signalBar(
                    label: "speech", detail: "\(Int(mean * 100))%", fraction: min(mean, 1))
            }
        }
    }

    private func signalBar(label: String, detail: String, fraction: Double) -> some View {
        HStack(spacing: UIScale.pt(8)) {
            Text(label)
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(44), alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(DashSkin.line(dark))
                    Capsule()
                        .fill(DashSkin.accent(dark))
                        .frame(width: max(UIScale.pt(3), geometry.size.width * fraction))
                }
            }
            .frame(height: UIScale.pt(6))
            Text(detail)
                .font(.system(size: UIScale.pt(10.5)))
                .monospacedDigit()
                .foregroundStyle(DashSkin.inkSoft(dark))
        }
    }
}

struct VoicePlayerBar: View {
    let playback: AudioPlayback
    let dark: Bool

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: UIScale.pt(24)))
                    .foregroundStyle(
                        playback.loaded ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(!playback.loaded)
            .help(playback.playing ? "Pause" : "Play")
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(DashSkin.line(dark))
                    Capsule()
                        .fill(DashSkin.accent(dark))
                        .frame(width: max(0, geometry.size.width * playback.progress))
                }
            }
            .frame(height: UIScale.pt(5))
            Text("\(timeLabel(playback.currentTime)) / \(timeLabel(playback.duration))")
                .font(.system(size: UIScale.pt(10.5)))
                .monospacedDigit()
                .foregroundStyle(DashSkin.inkFaint(dark))
        }
        .padding(.horizontal, UIScale.pt(10))
        .padding(.vertical, UIScale.pt(7))
        .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(10)).strokeBorder(DashSkin.line(dark))
        }
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct PdfPreview: NSViewRepresentable {
    let data: Data

    final class Coordinator {
        var loaded: Int = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: data)
        context.coordinator.loaded = data.hashValue
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.loaded != data.hashValue else { return }
        view.document = PDFDocument(data: data)
        context.coordinator.loaded = data.hashValue
    }
}
