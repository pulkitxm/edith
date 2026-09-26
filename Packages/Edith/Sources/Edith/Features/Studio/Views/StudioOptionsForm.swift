import AVFoundation
import AppKit
import EdithKit
import EdithStudio
import PDFKit
import SwiftUI

struct StudioOptionsForm: View {
    let job: StudioJob

    var body: some View {
        let visible = StudioOptionVisibility.visible(job.tool.options, in: job.settings)
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            ForEach(visible) { option in
                StudioOptionField(job: job, option: option)
            }
        }
        .disabled(job.isRunning)
    }
}

enum StudioOptionVisibility {
    static func visible(_ options: [StudioOption], in settings: StudioSettings) -> [StudioOption] {
        options.filter { $0.isVisible(in: settings) }
    }
}

struct StudioOptionField: View {
    let job: StudioJob
    let option: StudioOption

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            if showsLabel {
                Text(option.label)
                    .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            field
            if let help = option.help {
                Text(help)
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var showsLabel: Bool {
        if case .toggle = option.kind { return false }
        return true
    }

    @ViewBuilder private var field: some View {
        switch option.kind {
        case let .choice(choices):
            StudioChoiceField(choices: choices, selection: text)
        case .toggle:
            Toggle(option.label, isOn: bool)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: UIScale.pt(12)))
        case let .integer(range, unit):
            StudioIntegerField(value: number, range: range, unit: unit)
        case let .number(range, step, unit):
            StudioSliderField(
                value: number, range: range, step: step,
                format: { value in
                    StudioOptionText.number(value, step: step) + (unit.map { " \($0)" } ?? "")
                })
        case let .percent(range):
            StudioSliderField(
                value: number, range: range, step: 0.01,
                format: { value in
                    "\(Int((value * 100).rounded()))%"
                })
        case let .text(placeholder):
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        case let .longText(placeholder):
            ZStack(alignment: .topLeading) {
                TextEditor(text: text)
                    .font(.system(size: UIScale.pt(12)))
                    .frame(height: UIScale.pt(84))
                    .scrollContentBackground(.hidden)
                    .padding(UIScale.pt(4))
                    .background(
                        Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(.tertiary)
                        .padding(UIScale.pt(9))
                        .allowsHitTesting(false)
                }
            }
        case .password:
            SecureField("Password", text: text)
                .textFieldStyle(.roundedBorder)
        case .color:
            StudioColorField(hex: text)
        case .pages:
            StudioPagesField(job: job, text: text)
        case .time:
            StudioTimeField(value: number)
        case .span:
            StudioSpanField(job: job, span: span)
        case .rect:
            StudioRectField(job: job, rect: rect)
        case let .file(kinds):
            StudioFileField(path: text, kinds: kinds)
        case .font:
            StudioFontField(family: text)
        case .anchor:
            StudioAnchorField(value: text)
        }
    }

    private var text: Binding<String> {
        Binding(
            get: { job.binding(option.key).text ?? "" },
            set: { job.set(option.key, .text($0)) })
    }

    private var bool: Binding<Bool> {
        Binding(
            get: { job.binding(option.key).bool ?? false },
            set: { job.set(option.key, .bool($0)) })
    }

    private var number: Binding<Double> {
        Binding(
            get: { job.binding(option.key).number ?? 0 },
            set: { job.set(option.key, .number($0)) })
    }

    private var span: Binding<StudioSpan> {
        Binding(
            get: { job.binding(option.key).span ?? .whole },
            set: { job.set(option.key, .span($0)) })
    }

    private var rect: Binding<StudioRect> {
        Binding(
            get: { job.binding(option.key).rect ?? .full },
            set: { job.set(option.key, .rect($0)) })
    }
}

enum StudioOptionText {
    static func number(_ value: Double, step: Double) -> String {
        if step >= 1 { return String(Int(value.rounded())) }
        if step >= 0.1 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }
}

struct StudioChoiceField: View {
    let choices: [StudioChoice]
    @Binding var selection: String

    private var segmented: Bool {
        choices.count <= 3 && choices.allSatisfy { $0.label.count <= 14 }
    }

    var body: some View {
        if segmented {
            Picker("", selection: $selection) {
                ForEach(choices, id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } else {
            Picker("", selection: $selection) {
                ForEach(choices, id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct StudioIntegerField: View {
    @Binding var value: Double
    let range: ClosedRange<Int>
    let unit: String?

    var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            TextField(
                "",
                value: Binding(
                    get: { Int(value.rounded()) },
                    set: { value = Double(min(max($0, range.lowerBound), range.upperBound)) }),
                format: .number
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: UIScale.pt(80))
            Stepper(
                "", value: Binding(get: { Int(value.rounded()) }, set: { value = Double($0) }),
                in: range
            )
            .labelsHidden()
            if let unit {
                Text(unit).font(.system(size: UIScale.pt(11.5))).foregroundStyle(.secondary)
            }
        }
    }
}

struct StudioSliderField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
            Text(format(value))
                .font(DashSkin.mono(11))
                .foregroundStyle(.secondary)
                .frame(minWidth: UIScale.pt(52), alignment: .trailing)
        }
    }
}

struct StudioColorField: View {
    @Binding var hex: String

    var body: some View {
        HStack(spacing: UIScale.pt(8)) {
            ColorPicker(
                "",
                selection: Binding(
                    get: {
                        let color = StudioColor(hex: hex) ?? .black
                        return Color(
                            .sRGB, red: color.red, green: color.green, blue: color.blue,
                            opacity: color.alpha)
                    },
                    set: { newValue in
                        guard let converted = NSColor(newValue).usingColorSpace(.sRGB) else {
                            return
                        }
                        hex =
                            StudioColor(
                                red: converted.redComponent, green: converted.greenComponent,
                                blue: converted.blueComponent, alpha: converted.alphaComponent
                            ).hex
                    }), supportsOpacity: true
            )
            .labelsHidden()
            TextField("#000000", text: $hex)
                .textFieldStyle(.roundedBorder)
                .font(DashSkin.mono(11.5))
                .frame(width: UIScale.pt(96))
        }
    }
}

struct StudioPagesField: View {
    let job: StudioJob
    @Binding var text: String
    @State private var pageCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            TextField("all", text: $text)
                .textFieldStyle(.roundedBorder)
            if let pageCount {
                let problem = StudioPagesValidation.problem(text, pageCount: pageCount)
                Text(
                    problem
                        ?? "\(pageCount) pages in \(job.inputs.first?.lastPathComponent ?? "the PDF")"
                )
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(problem == nil ? Color.secondary : DashSkin.danger)
            }
        }
        .task(id: job.inputs.first) {
            guard let url = job.inputs.first(where: { $0.studioKind == .pdf }) else {
                pageCount = nil
                return
            }
            pageCount = await Task.detached(priority: .utility) { StudioPDF.pageCount(url) }.value
        }
    }
}

enum StudioPagesValidation {
    static func problem(_ text: String, pageCount: Int) -> String? {
        do {
            _ = try StudioPageSelection.pages(text, pageCount: pageCount)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

struct StudioTimeField: View {
    @Binding var value: Double
    @State private var draft = ""

    var body: some View {
        TextField("0:00", text: $draft)
            .textFieldStyle(.roundedBorder)
            .frame(width: UIScale.pt(110))
            .onAppear { draft = StudioTime.format(value) }
            .onSubmit { commit() }
            .onChange(of: draft) { _, _ in commit() }
    }

    private func commit() {
        if let parsed = StudioTime.parse(draft) { value = parsed }
    }
}

struct StudioSpanField: View {
    let job: StudioJob
    @Binding var span: StudioSpan
    @State private var start = ""
    @State private var end = ""
    @State private var duration: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            HStack(spacing: UIScale.pt(6)) {
                TextField("Start", text: $start)
                    .textFieldStyle(.roundedBorder)
                Text("to").foregroundStyle(.secondary)
                TextField("End", text: $end)
                    .textFieldStyle(.roundedBorder)
            }
            if let duration {
                Text(
                    "Clip is \(StudioTime.format(duration)) long. Leave End empty to keep going to the end."
                )
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(.secondary)
                if duration > 0 {
                    StudioSpanSlider(span: $span, duration: duration)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: span) { _, _ in load() }
        .onChange(of: start) { _, _ in commit() }
        .onChange(of: end) { _, _ in commit() }
        .task(id: job.inputs.first) {
            guard let url = job.inputs.first else {
                duration = nil
                return
            }
            duration = await StudioMediaDuration.seconds(url)
        }
    }

    private func load() {
        let formattedStart = StudioTime.format(span.start)
        let formattedEnd = span.end.map(StudioTime.format) ?? ""
        if StudioTime.parse(start) != span.start { start = formattedStart }
        if StudioTime.parse(end) != span.end { end = formattedEnd }
    }

    private func commit() {
        let startValue = StudioTime.parse(start) ?? 0
        let endValue =
            end.trimmingCharacters(in: .whitespaces).isEmpty ? nil : StudioTime.parse(end)
        let next = StudioSpan(
            start: startValue, end: endValue.flatMap { $0 > startValue ? $0 : nil })
        if next != span { span = next }
    }
}

struct StudioSpanSlider: View {
    @Binding var span: StudioSpan
    let duration: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let startX = CGFloat(span.start / duration) * width
            let endX = CGFloat((span.end ?? duration) / duration) * width
            ZStack(alignment: .leading) {
                Capsule().fill(DashSkin.grid(scheme == .dark)).frame(height: 6)
                Capsule().fill(DashSkin.accent(scheme == .dark))
                    .frame(width: max(2, endX - startX), height: 6)
                    .offset(x: startX)
                handle.offset(x: startX - 7)
                    .gesture(
                        DragGesture().onChanged { value in
                            let seconds =
                                Double(min(max(0, value.location.x), endX - 4) / width) * duration
                            span = StudioSpan(start: (seconds * 10).rounded() / 10, end: span.end)
                        })
                handle.offset(x: endX - 7)
                    .gesture(
                        DragGesture().onChanged { value in
                            let seconds =
                                Double(min(max(startX + 4, value.location.x), width) / width)
                                * duration
                            let rounded = (seconds * 10).rounded() / 10
                            span = StudioSpan(
                                start: span.start, end: rounded >= duration - 0.05 ? nil : rounded)
                        })
            }
        }
        .frame(height: UIScale.pt(16))
    }

    private var handle: some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(DashSkin.accent(scheme == .dark), lineWidth: 2))
            .frame(width: 14, height: 14)
            .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
    }
}

enum StudioMediaDuration {
    static func seconds(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite else {
            return nil
        }
        return duration.seconds
    }
}

struct StudioRectField: View {
    let job: StudioJob
    @Binding var rect: StudioRect
    @State private var image: NSImage?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(DashSkin.grid(scheme == .dark))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay {
                            GeometryReader { geometry in
                                StudioRectOverlay(rect: $rect, size: geometry.size)
                            }
                        }
                } else {
                    Text("Add a file to pick an area").font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: UIScale.pt(170))
            HStack {
                Text(StudioRectText.describe(rect))
                    .font(DashSkin.mono(10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { rect = .full }
                    .buttonStyle(.edith(.toolbar))
            }
        }
        .task(id: job.inputs.first) {
            guard let url = job.inputs.first else {
                image = nil
                return
            }
            image = await StudioThumbnails.shared.thumbnail(for: url, side: 320)
        }
    }
}

enum StudioRectText {
    static func describe(_ rect: StudioRect) -> String {
        rect.isFull
            ? "Whole frame"
            : String(
                format: "x %.0f%%  y %.0f%%  w %.0f%%  h %.0f%%", rect.x * 100, rect.y * 100,
                rect.width * 100, rect.height * 100)
    }
}

struct StudioRectOverlay: View {
    @Binding var rect: StudioRect
    let size: CGSize
    @State private var origin: StudioRect?

    var body: some View {
        let frame = CGRect(
            x: rect.x * size.width, y: rect.y * size.height, width: rect.width * size.width,
            height: rect.height * size.height)
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(frame)
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let base = origin ?? rect
                            if origin == nil { origin = rect }
                            rect = StudioRect(
                                x: min(
                                    max(0, base.x + value.translation.width / size.width),
                                    1 - base.width),
                                y: min(
                                    max(0, base.y + value.translation.height / size.height),
                                    1 - base.height),
                                width: base.width, height: base.height)
                        }
                        .onEnded { _ in origin = nil })
            Circle()
                .fill(Color.white)
                .frame(width: 12, height: 12)
                .offset(x: frame.maxX - 6, y: frame.maxY - 6)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let width = min(
                                max(0.05, value.location.x / size.width - rect.x), 1 - rect.x)
                            let height = min(
                                max(0.05, value.location.y / size.height - rect.y), 1 - rect.y)
                            rect = StudioRect(x: rect.x, y: rect.y, width: width, height: height)
                        })
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

struct StudioFileField: View {
    @Binding var path: String
    let kinds: [StudioKind]

    var body: some View {
        HStack(spacing: UIScale.pt(8)) {
            if !path.isEmpty {
                StudioThumbnail(url: URL(fileURLWithPath: path), side: 48, corner: 5)
                    .frame(width: UIScale.pt(30), height: UIScale.pt(30))
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: UIScale.pt(11.5)))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button(path.isEmpty ? "Choose…" : "Change…") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.message =
                    "Choose " + kinds.map { $0.title.lowercased() }.joined(separator: " or ")
                if panel.runModal() == .OK, let url = panel.url { path = url.path }
            }
            .buttonStyle(.edith(.secondary))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            path = url.path
            return true
        }
    }
}

struct StudioFontField: View {
    @Binding var family: String

    var body: some View {
        Picker("", selection: $family) {
            ForEach(StudioFonts.families, id: \.self) { name in
                Text(name).font(.custom(name, size: 13)).tag(name)
            }
        }
        .labelsHidden()
    }
}

enum StudioFonts {
    static let families: [String] = {
        let preferred = [
            "Helvetica Neue", "Helvetica", "Avenir Next", "Futura", "Gill Sans", "Georgia",
            "Times New Roman",
            "Baskerville", "Didot", "Menlo", "Courier New", "Impact", "Marker Felt", "Noteworthy",
            "Snell Roundhand", "Zapfino", "American Typewriter", "Rockwell", "Optima", "Palatino",
        ]
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return preferred.filter(installed.contains)
    }()
}

struct StudioAnchorField: View {
    @Binding var value: String
    @Environment(\.colorScheme) private var scheme

    private let grid: [[StudioAnchor]] = [
        [.topLeft, .top, .topRight], [.left, .center, .right],
        [.bottomLeft, .bottom, .bottomRight],
    ]

    var body: some View {
        HStack(alignment: .top, spacing: UIScale.pt(14)) {
            VStack(spacing: UIScale.pt(3)) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: UIScale.pt(3)) {
                        ForEach(grid[row], id: \.self) { anchor in
                            Button {
                                value = anchor.rawValue
                            } label: {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(
                                        value == anchor.rawValue
                                            ? DashSkin.accent(scheme == .dark)
                                            : DashSkin.grid(scheme == .dark)
                                    )
                                    .frame(width: UIScale.pt(22), height: UIScale.pt(16))
                                    .edithButtonTarget(.borderless)
                            }
                            .buttonStyle(.edith(.borderless))
                            .help(anchor.rawValue.replacingOccurrences(of: "-", with: " "))
                        }
                    }
                }
            }
            Toggle(
                "Tiled",
                isOn: Binding(
                    get: { value == StudioAnchor.tiled.rawValue },
                    set: { value = $0 ? StudioAnchor.tiled.rawValue : StudioAnchor.center.rawValue }
                )
            )
            .toggleStyle(.checkbox)
        }
    }
}
