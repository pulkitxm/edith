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

    private var theme: Color { themeColor(themeName) }
    private var dark: Bool { scheme == .dark }
    private var canStart: Bool {
        !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !downloader.isRunning
            && downloader.unavailableReason == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            bodyContent
            footer
        }
        .frame(width: 500, height: 520)
        .background(DashSkin.paper(dark))
    }

    private var header: some View {
        HStack {
            Text("Download YouTube Audio")
                .font(DashSkin.serif(20))
                .foregroundStyle(DashSkin.ink(dark))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(HoverButtonStyle())
            .disabled(downloader.isRunning)
            .pointerCursor()
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var bodyContent: some View {
        if let reason = downloader.unavailableReason {
            unavailableView(reason)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                inputSection
                if !downloader.items.isEmpty {
                    queueSection
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func unavailableView(_ reason: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text(reason)
                .font(.system(size: 12.5))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VIDEO URLS")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .tracking(0.5)
            TextEditor(text: $urlText)
                .font(.system(size: 12.5))
                .foregroundStyle(DashSkin.ink(dark))
                .frame(minHeight: 80, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9).strokeBorder(DashSkin.line(dark), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if urlText.isEmpty {
                        Text("youtube.com/watch?v=...\nyoutu.be/...")
                            .font(.system(size: 12.5))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(downloader.isRunning)

            Text("Separate multiple URLs with commas or new lines.")
                .font(.system(size: 10.5))
                .foregroundStyle(DashSkin.inkFaint(dark))

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FILENAME PREFIX")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .tracking(0.5)
                    TextField("Optional — e.g. roadtrip_", text: $filenamePrefix)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(DashSkin.ink(dark))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8).strokeBorder(
                                DashSkin.line(dark), lineWidth: 1)
                        )
                        .disabled(downloader.isRunning)
                }
                if !filenamePrefix.isEmpty, let first = previewFilename {
                    Text(first)
                        .font(.system(size: 11))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .lineLimit(1)
                        .padding(.top, 16)
                }
            }
        }
    }

    private var previewFilename: String? {
        guard !filenamePrefix.isEmpty else { return nil }
        return "\(filenamePrefix)Title.m4a"
    }

    @ViewBuilder private var queueSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("QUEUE")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .tracking(0.5)
                Spacer()
                let done = downloader.items.filter {
                    if case .done = $0.status { return true }
                    return false
                }.count
                if done > 0 {
                    Text("\(done)/\(downloader.items.count) done")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(downloader.items) { item in
                        queueRow(item)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 200)
        }
    }

    private func queueRow(_ item: YoutubeDownloader.DownloadItem) -> some View {
        HStack(spacing: 8) {
            statusIcon(item.status)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayURL(item.url))
                    .font(.system(size: 11.5))
                    .foregroundStyle(
                        statusColor(item.status).map { AnyShapeStyle($0) }
                            ?? AnyShapeStyle(DashSkin.ink(dark))
                    )
                    .lineLimit(1)
                if case let .done(output) = item.status {
                    Text(output)
                        .font(.system(size: 10))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .lineLimit(1)
                }
                if case let .error(msg) = item.status {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if case let .downloading(progress) = item.status {
                Text(progress)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 7))
    }

    private func displayURL(_ url: URL) -> String {
        let id: String
        if url.host?.contains("youtu.be") == true {
            id = url.lastPathComponent
        } else {
            id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value ?? url.lastPathComponent
        }
        return "youtube.com/watch?v=\(id.prefix(11))"
    }

    @ViewBuilder
    private func statusIcon(_ status: DownloadStatus) -> some View {
        switch status {
        case .queued:
            Circle()
                .stroke(DashSkin.lineStrong(dark), lineWidth: 2)
        case .downloading:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.5)
                .frame(width: 16, height: 16)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.red)
        }
    }

    private func statusColor(_ status: DownloadStatus) -> Color? {
        switch status {
        case .downloading: theme
        case .done: .green
        case .error: .red
        default: nil
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            if downloader.isRunning {
                Button("Cancel") {
                    downloader.cancelAll()
                    dismiss()
                }
                .buttonStyle(HoverButtonStyle())
                .pointerCursor()
            } else {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(HoverButtonStyle())
                .pointerCursor()
            }
            Button(action: startDownload) {
                Text("Start Download")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(canStart ? theme : Color.gray.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
            .pointerCursor()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DashSkin.line(dark))
                .frame(height: 1)
        }
    }

    private func startDownload() {
        let urls = downloader.parseURLs(from: urlText)
        guard !urls.isEmpty else { return }
        downloader.enqueue(urls: urls, prefix: filenamePrefix)
        urlText = ""
    }
}
