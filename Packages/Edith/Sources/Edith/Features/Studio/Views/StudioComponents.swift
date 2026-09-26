import AppKit
import EdithKit
import EdithStudio
import SwiftUI

enum StudioPalette {
    static func tint(for kind: StudioKind) -> Color {
        switch kind {
        case .pdf: Color(red: 0.86, green: 0.27, blue: 0.24)
        case .image: Color(red: 0.23, green: 0.52, blue: 0.93)
        case .video: Color(red: 0.55, green: 0.36, blue: 0.9)
        case .audio: Color(red: 0.94, green: 0.56, blue: 0.18)
        case .document: Color(red: 0.2, green: 0.47, blue: 0.83)
        case .presentation: Color(red: 0.93, green: 0.42, blue: 0.2)
        case .spreadsheet: Color(red: 0.16, green: 0.6, blue: 0.36)
        case .archive: Color(red: 0.55, green: 0.5, blue: 0.42)
        case .other: Color.gray
        }
    }

    static func tint(for tool: StudioTool) -> Color {
        tool.group == .intelligence
            ? Color(red: 0.62, green: 0.34, blue: 0.86) : tint(for: tool.family)
    }
}

struct StudioThumbnail: View {
    let url: URL
    var side: CGFloat = 160
    var corner: CGFloat = 10
    @State private var image: NSImage?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: UIScale.pt(corner))
                .fill(DashSkin.grid(scheme == .dark))
            if let image = image ?? StudioThumbnails.shared.cached(url, side: side) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(UIScale.pt(6))
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            } else {
                Image(systemName: url.studioKind.symbolName)
                    .font(.system(size: UIScale.pt(side * 0.22), weight: .light))
                    .foregroundStyle(StudioPalette.tint(for: url.studioKind).opacity(0.7))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(corner)))
        .task(id: url) {
            image = StudioThumbnails.shared.cached(url, side: side)
            if image == nil {
                image = await StudioThumbnails.shared.thumbnail(for: url, side: side)
            }
        }
    }
}

struct StudioKindBadge: View {
    let kind: StudioKind
    var label: String?

    var body: some View {
        Text(label ?? kind.title.uppercased())
            .font(DashSkin.mono(9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, UIScale.pt(5))
            .padding(.vertical, UIScale.pt(2))
            .background(
                StudioPalette.tint(for: kind), in: RoundedRectangle(cornerRadius: UIScale.pt(4)))
    }
}

struct StudioToolIcon: View {
    let tool: StudioTool
    var size: CGFloat = 34

    var body: some View {
        let tint = StudioPalette.tint(for: tool)
        Image(systemName: tool.symbolName)
            .font(.system(size: UIScale.pt(size * 0.46), weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: UIScale.pt(size), height: UIScale.pt(size))
            .background(
                tint.opacity(0.13), in: RoundedRectangle(cornerRadius: UIScale.pt(size * 0.28)))
    }
}

struct StudioChip: View {
    let title: String
    var count: Int?
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: UIScale.pt(5)) {
                Text(title)
                if let count {
                    Text("\(count)")
                        .font(DashSkin.mono(10, weight: .medium))
                        .foregroundStyle(
                            selected
                                ? Color.white.opacity(0.85) : DashSkin.inkFaint(scheme == .dark))
                }
            }
            .font(.system(size: UIScale.pt(12), weight: .medium))
            .padding(.horizontal, UIScale.pt(11))
            .padding(.vertical, UIScale.pt(5))
            .foregroundStyle(selected ? Color.white : DashSkin.ink(scheme == .dark))
            .background(
                selected ? DashSkin.accent(scheme == .dark) : DashSkin.paper2(scheme == .dark),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(selected ? Color.clear : DashSkin.line(scheme == .dark))
            )
            .edithButtonTarget(.borderless)
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct StudioCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content()
            .padding(UIScale.pt(padding))
            .background(
                DashSkin.paper2(scheme == .dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(
                    DashSkin.line(scheme == .dark)))
    }
}

struct StudioBackBar<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    let back: () -> Void
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            Button(action: back) {
                Label("Studio", systemImage: "chevron.left")
                    .font(.system(size: UIScale.pt(12.5), weight: .medium))
            }
            .buttonStyle(.edith(.secondary))
            .help("Back to Studio")
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(DashSkin.accent(scheme == .dark))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: UIScale.pt(15), weight: .semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: UIScale.pt(8))
            trailing()
        }
        .padding(.horizontal, UIScale.pt(16))
        .frame(height: UIScale.pt(54))
    }
}

struct StudioEngineBanner: View {
    let model: StudioModel
    let tool: StudioTool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let missing = model.environment.missing(for: tool)
        if !missing.isEmpty {
            HStack(alignment: .top, spacing: UIScale.pt(10)) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DashSkin.warn)
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text(StudioEngineText.title(missing))
                        .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                    Text(StudioEngineText.detail(missing))
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let log = model.installLog, model.installing != nil {
                        Text(log)
                            .font(DashSkin.mono(10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                ForEach(StudioEngineText.engines(missing), id: \.self) { engine in
                    Button {
                        model.install(engine)
                    } label: {
                        if model.installing == engine {
                            HStack(spacing: UIScale.pt(6)) {
                                ProgressView().controlSize(.small)
                                Text("Installing…")
                            }
                        } else {
                            Text("Install \(engine.title)")
                        }
                    }
                    .buttonStyle(.edith(.primary))
                    .disabled(model.installing != nil)
                }
            }
            .padding(UIScale.pt(12))
            .background(
                DashSkin.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
        }
    }
}

enum StudioEngineText {
    static func engines(_ missing: [StudioRequirement]) -> [StudioEngine] {
        missing.compactMap {
            if case let .engine(engine) = $0 { return engine }
            return nil
        }
    }

    static func title(_ missing: [StudioRequirement]) -> String {
        "Needs " + missing.map(\.title).joined(separator: " and ")
    }

    static func detail(_ missing: [StudioRequirement]) -> String {
        missing.map { requirement -> String in
            switch requirement {
            case .engine(.ffmpeg):
                return "FFmpeg does the video and audio work. Studio installs it with Homebrew."
            case .engine(.qpdf):
                return "qpdf rewrites PDF internals. Studio installs it with Homebrew."
            case .appleIntelligence:
                return "Turn on Apple Intelligence in System Settings to use on-device summaries."
            case .translation:
                return "Translation needs macOS 26 and the language pack from System Settings."
            }
        }.joined(separator: " ")
    }
}

struct StudioDestinationPicker: View {
    @AppStorage(AppStorageKeys.Studio.destination, store: SharedDefaults.store) private var mode =
        StudioDestinationMode.original.rawValue
    @AppStorage(AppStorageKeys.Studio.folder, store: SharedDefaults.store) private var folder = ""

    var body: some View {
        HStack(spacing: UIScale.pt(8)) {
            Picker("Save results", selection: $mode) {
                ForEach(StudioDestinationMode.allCases, id: \.rawValue) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .fixedSize()
            if mode == StudioDestinationMode.folder.rawValue {
                Button(
                    folder.isEmpty
                        ? "Choose folder…" : URL(fileURLWithPath: folder).lastPathComponent
                ) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.prompt = "Use folder"
                    if panel.runModal() == .OK, let url = panel.url { folder = url.path }
                }
                .buttonStyle(.edith(.secondary))
                .help(folder.isEmpty ? "Pick where results go" : folder)
            }
        }
    }
}

struct StudioToast: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(.system(size: UIScale.pt(12), weight: .medium))
            .padding(.horizontal, UIScale.pt(14))
            .padding(.vertical, UIScale.pt(8))
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(DashSkin.line(scheme == .dark)))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

enum StudioFileActions {
    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { await StudioFinderReveal.reveal(urls) }
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func describe(_ facts: StudioFileFacts?, kind: StudioKind) -> String {
        guard let facts else { return kind.title }
        guard facts.exists else { return "Missing" }
        var parts = [StudioInspector.size(facts.bytes)]
        if let detail = facts.detail { parts.insert(detail, at: 0) }
        return parts.joined(separator: " · ")
    }
}

enum StudioFinderReveal {
    static func script(for urls: [URL]) -> String {
        let targets = urls.map { "POSIX file \"\(escaped($0.path))\" as alias" }
        return """
            set targets to {\(targets.joined(separator: ", "))}
            tell application "Finder"
                reveal targets
                activate
            end tell
            """
    }

    static func escaped(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func folders(of urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        var folders: [URL] = []
        for url in urls {
            let folder = url.deletingLastPathComponent().standardizedFileURL
            if seen.insert(folder).inserted { folders.append(folder) }
        }
        return folders
    }

    @MainActor
    static func reveal(_ urls: [URL]) async {
        let source = script(for: urls)
        let revealed = await Task.detached(priority: .userInitiated) {
            guard let script = NSAppleScript(source: source) else { return false }
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            return error == nil
        }.value
        guard !revealed else { return }
        for folder in folders(of: urls) { NSWorkspace.shared.open(folder) }
    }
}
