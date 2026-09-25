import AppKit
import EdithKit
import EdithStudio
import PDFKit
import SwiftUI

@MainActor
@Observable
final class StudioCompareModel {
    let originalURL: URL
    let revisedURL: URL
    var original: PDFDocument?
    var revised: PDFDocument?
    var report: PDFComparison.Report?
    var failure: String?
    var focused: PDFComparison.Change?
    var visualPage = 0
    var visual: NSImage?
    var visualFraction = 0.0
    var showsVisual = false
    private var loadTask: Task<Void, Never>?
    private var visualTask: Task<Void, Never>?

    init(original: URL, revised: URL) {
        originalURL = original
        revisedURL = revised
    }

    func load() {
        loadTask?.cancel()
        let left = originalURL
        let right = revisedURL
        loadTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                StudioCompareLoader.load(left, right)
            }.value
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case let .success(loaded):
                self.original = loaded.original
                self.revised = loaded.revised
                self.report = loaded.report
                StudioCompareLoader.highlight(loaded.report, in: loaded.original, loaded.revised)
            case let .failure(error):
                self.failure = error.localizedDescription
            }
        }
    }

    func renderVisual() {
        visualTask?.cancel()
        let left = originalURL
        let right = revisedURL
        let page = visualPage
        visualTask = Task { [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) {
                StudioCompareLoader.visual(left, right, page: page)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.visual = rendered.map { NSImage(cgImage: $0.image, size: .zero) }
            self.visualFraction = rendered?.changedFraction ?? 0
        }
    }
}

enum StudioCompareLoader {
    struct Loaded: @unchecked Sendable {
        let original: PDFDocument
        let revised: PDFDocument
        let report: PDFComparison.Report
    }

    static func load(_ left: URL, _ right: URL) -> Result<Loaded, Error> {
        do {
            let original = try StudioPDF.open(left)
            let revised = try StudioPDF.open(right)
            return .success(
                Loaded(
                    original: original, revised: revised,
                    report: PDFComparison.compare(original, revised)))
        } catch {
            return .failure(error)
        }
    }

    static func highlight(
        _ report: PDFComparison.Report, in original: PDFDocument, _ revised: PDFDocument
    ) {
        for change in report.changes {
            let document = change.side == .original ? original : revised
            guard let page = document.page(at: change.page) else { continue }
            let rect = change.rect.applying(StudioPDF.displayFromPage(page).inverted())
            let annotation = PDFAnnotation(
                bounds: rect.insetBy(dx: -2, dy: -1), forType: .highlight, withProperties: nil)
            annotation.color =
                change.side == .original
                ? NSColor.systemRed.withAlphaComponent(0.35)
                : NSColor.systemGreen.withAlphaComponent(0.35)
            page.addAnnotation(annotation)
        }
    }

    static func visual(_ left: URL, _ right: URL, page: Int) -> (
        image: CGImage, changedFraction: Double
    )? {
        guard let original = try? StudioPDF.open(left).page(at: page),
            let revised = try? StudioPDF.open(right).page(at: page)
        else { return nil }
        return try? PDFComparison.visualDifference(original, revised, dpi: 110)
    }
}

struct StudioCompareView: View {
    let model: StudioModel
    @State private var compare: StudioCompareModel
    @Environment(\.colorScheme) private var scheme

    @MainActor init(model: StudioModel, original: URL, revised: URL) {
        self.init(model: model, compare: StudioCompareModel(original: original, revised: revised))
    }

    init(model: StudioModel, compare: StudioCompareModel) {
        self.model = model
        _compare = State(initialValue: compare)
    }

    var body: some View {
        VStack(spacing: 0) {
            StudioBackBar(
                title: "Compare PDF",
                subtitle:
                    "\(compare.originalURL.lastPathComponent) → \(compare.revisedURL.lastPathComponent)",
                symbol: "rectangle.split.2x1", back: model.goHome
            ) {
                Toggle("Visual difference", isOn: $compare.showsVisual)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button("Save report") {
                    model.open(
                        toolID: "pdf.compare", with: [compare.originalURL, compare.revisedURL])
                }
                .buttonStyle(.edith(.secondary))
            }
            Divider()
            if let failure = compare.failure {
                StudioEmptyNote(symbol: "exclamationmark.triangle", text: failure)
                    .padding(UIScale.pt(20))
                Spacer()
            } else if let original = compare.original, let revised = compare.revised,
                let report = compare.report
            {
                HStack(spacing: 0) {
                    if compare.showsVisual {
                        visualPane(pages: min(original.pageCount, revised.pageCount))
                    } else {
                        StudioCompareColumn(
                            title: "Original", document: original, focus: focusFor(.original))
                        Divider()
                        StudioCompareColumn(
                            title: "Revised", document: revised, focus: focusFor(.revised))
                    }
                    Divider()
                    changesList(report)
                        .frame(width: UIScale.pt(280))
                }
            } else {
                ProgressView("Comparing…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DashSkin.paper(scheme == .dark))
        .task { if compare.report == nil { compare.load() } }
    }

    private func focusFor(_ side: PDFComparison.Side) -> PDFComparison.Change? {
        guard let focused = compare.focused, focused.side == side else { return nil }
        return focused
    }

    private func changesList(_ report: PDFComparison.Report) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                Text(report.summary)
                    .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                Text("\(report.originalPages) → \(report.revisedPages) pages")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.secondary)
            }
            .padding(UIScale.pt(14))
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(report.changes) { change in
                        Button {
                            compare.focused = change
                        } label: {
                            HStack(alignment: .top, spacing: UIScale.pt(8)) {
                                Image(
                                    systemName: change.side == .original
                                        ? "minus.circle.fill" : "plus.circle.fill"
                                )
                                .foregroundStyle(
                                    change.side == .original ? DashSkin.danger : DashSkin.ok)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(change.text)
                                        .font(.system(size: UIScale.pt(11.5)))
                                        .lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                    Text("Page \(change.page + 1)")
                                        .font(.system(size: UIScale.pt(10)))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, UIScale.pt(12))
                            .padding(.vertical, UIScale.pt(7))
                            .background(
                                compare.focused == change
                                    ? DashSkin.accent(scheme == .dark).opacity(0.14) : .clear
                            )
                            .edithButtonTarget(.borderless)
                        }
                        .buttonStyle(.edith(.borderless))
                    }
                }
            }
        }
        .background(DashSkin.paper2(scheme == .dark).opacity(0.5))
    }

    private func visualPane(pages: Int) -> some View {
        VStack(spacing: UIScale.pt(10)) {
            HStack {
                Stepper(
                    "Page \(compare.visualPage + 1) of \(max(pages, 1))",
                    value: $compare.visualPage, in: 0...max(pages - 1, 0))
                Spacer()
                Text("\(String(format: "%.2f", compare.visualFraction * 100))% of pixels changed")
                    .font(DashSkin.mono(11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, UIScale.pt(16))
            .padding(.top, UIScale.pt(10))
            if let visual = compare.visual {
                Image(nsImage: visual)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(UIScale.pt(12))
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: compare.visualPage) { compare.renderVisual() }
    }
}

struct StudioCompareColumn: View {
    let title: String
    let document: PDFDocument
    let focus: PDFComparison.Change?

    var body: some View {
        VStack(spacing: 0) {
            Text(title.uppercased())
                .font(DashSkin.mono(10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, UIScale.pt(6))
            StudioReadOnlyPDFView(document: document, focus: focus)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StudioReadOnlyPDFView: NSViewRepresentable {
    let document: PDFDocument
    let focus: PDFComparison.Change?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .clear
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        guard let focus, let page = document.page(at: focus.page) else { return }
        let rect = focus.rect.applying(StudioPDF.displayFromPage(page).inverted())
        view.go(to: rect, on: page)
    }
}
