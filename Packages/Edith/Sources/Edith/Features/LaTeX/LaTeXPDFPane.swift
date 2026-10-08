import AppKit
import EdithKit
import Observation
import PDFKit
import SwiftUI

@MainActor @Observable
final class LaTeXPDFControls {
    var page = 1
    var count = 0
    var percent = 100
    @ObservationIgnored weak var view: PDFView?
    func update() {
        guard let view else { return }
        count = view.document?.pageCount ?? 0
        if let current = view.currentPage { page = (view.document?.index(for: current) ?? 0) + 1 }
        percent = Int(view.scaleFactor * 100)
    }
}

struct LaTeXPDFPane: View {
    let url: URL?
    let data: Data?
    let generation: UUID
    @State private var controls = LaTeXPDFControls()
    init(url: URL, generation: UUID) {
        self.url = url; data = nil; self.generation = generation
    }
    init(data: Data, generation: UUID) {
        url = nil; self.data = data; self.generation = generation
    }
    var body: some View {
        VStack(spacing: UIScale.pt(10)) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    navigation; Spacer(); zoom
                }
                VStack {
                    navigation; zoom
                }
            }
            LaTeXPDFView(url: url, data: data, generation: generation, controls: controls)
            if let url {
                HStack {
                    Button("Open PDF") { NSWorkspace.shared.open(url) }
                    Spacer()
                    Button("Save PDF as…") {
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = url.lastPathComponent
                        if panel.runModal() == .OK, let destination = panel.url {
                            do {
                                try Data(contentsOf: url).write(to: destination, options: .atomic)
                            } catch { NSAlert(error: error).runModal() }
                        }
                    }
                }
            }
        }
    }
    private var navigation: some View {
        HStack {
            Button {
                controls.view?.goToPreviousPage(nil)
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("Previous page").disabled(controls.page <= 1)
            Text("\(controls.page) / \(controls.count)").font(.edithText(.caption))
                .monospacedDigit()
            Button {
                controls.view?.goToNextPage(nil)
            } label: {
                Image(systemName: "chevron.down")
            }
            .help("Next page").disabled(controls.page >= controls.count)
        }
    }
    private var zoom: some View {
        HStack {
            Button {
                controls.view?.zoomOut(nil)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom PDF out")
            Text("\(controls.percent)%").font(.edithText(.caption)).monospacedDigit()
            Button {
                controls.view?.zoomIn(nil)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom PDF in")
            Button("Fit") {
                controls.view?.autoScales = true; controls.update()
            }.help("Fit PDF to pane")
        }
    }
}

private struct LaTeXPDFView: NSViewRepresentable {
    let url: URL?
    let data: Data?
    let generation: UUID
    let controls: LaTeXPDFControls
    func makeCoordinator() -> Coordinator { Coordinator(controls) }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        controls.view = view
        context.coordinator.observe(view)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        let key = "\(url?.path ?? "github"):\(generation)"
        guard view.identifier?.rawValue != key else { return }
        view.identifier = NSUserInterfaceItemIdentifier(key)
        view.document = data.flatMap(PDFDocument.init(data:)) ?? url.flatMap(PDFDocument.init(url:))
        Task { @MainActor in controls.update() }
    }
    @MainActor final class Coordinator {
        let controls: LaTeXPDFControls
        var observers: [NSObjectProtocol] = []
        init(_ controls: LaTeXPDFControls) { self.controls = controls }
        func observe(_ view: PDFView) {
            for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged] {
                observers.append(
                    NotificationCenter.default.addObserver(
                        forName: name, object: view, queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor in self?.controls.update() }
                    })
            }
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
