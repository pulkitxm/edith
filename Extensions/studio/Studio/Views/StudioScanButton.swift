import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithStudio
import SwiftUI

struct StudioScanButton: View {
    let onImport: ([URL]) -> Void
    @Environment(\.studioFacade) private var facade
    @StateObject private var control = StudioScanControl()

    var body: some View {
        Button {
            control.host?.showMenu()
        } label: {
            Image(systemName: "iphone.gen3")
                .font(.system(size: UIScale.pt(14), weight: .medium))
                .frame(width: UIScale.pt(16), height: UIScale.pt(16))
        }
        .buttonStyle(.edith(.secondary))
        .accessibilityLabel("Import from iPhone or iPad")
        .background {
            StudioScanAnchor(onImport: onImport, control: control, facade: facade)
                .allowsHitTesting(false)
        }
    }
}

@MainActor
private final class StudioScanControl: ObservableObject {
    weak var host: StudioScanHostView?
}

private struct StudioScanAnchor: NSViewRepresentable {
    let onImport: ([URL]) -> Void
    let control: StudioScanControl
    let facade: StudioUIFacade?

    func makeNSView(context: Context) -> StudioScanHostView {
        let view = StudioScanHostView()
        view.facade = facade
        view.onImport = onImport
        control.host = view
        return view
    }

    func updateNSView(_ view: StudioScanHostView, context: Context) {
        view.facade = facade
        view.onImport = onImport
        control.host = view
    }
}

final class StudioScanHostView: NSView, NSServicesMenuRequestor {
    var onImport: (([URL]) -> Void)?
    var facade: StudioUIFacade?
    private var importTask: Task<Void, Never>?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { importTask?.cancel(); importTask = nil }
    }

    static let returnTypes: [NSPasteboard.PasteboardType] = [
        .pdf, .tiff, .png, NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
    ]

    override var acceptsFirstResponder: Bool { true }

    func showMenu() {
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        let item = NSMenuItem(title: "Import from iPhone or iPad", action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if let returnType, Self.returnTypes.contains(returnType) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        if let facade {
            guard let selection = StudioScanImport.selection(pasteboard),
                selection.data.count <= 128 * 1024 * 1024
            else { return false }
            importTask?.cancel()
            importTask = Task { [weak self] in
                do {
                    let handle = try await facade.uploadData(selection.data)
                    let urls: [URL] = try await facade.read(
                        "studio.ui.media.scan",
                        object: ["resource": try facade.object(handle), "type": selection.type])
                    guard !Task.isCancelled else { return }
                    self?.onImport?(urls)
                } catch { if !Task.isCancelled { facade.onFailure?(error.localizedDescription) } }
            }
            return true
        }
        guard let urls = try? StudioScanImport.save(pasteboard), !urls.isEmpty else { return false }
        onImport?(urls)
        return true
    }

    func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        false
    }
}

enum StudioScanImport {
    static func selection(_ pasteboard: NSPasteboard) -> (data: Data, type: String)? {
        for (type, suffix) in [
            (NSPasteboard.PasteboardType.pdf, "pdf"), (.init("public.jpeg"), "jpg"),
            (.init("public.heic"), "heic"), (.png, "png"), (.tiff, "tiff"),
        ] {
            if let data = pasteboard.data(forType: type) { return (data, suffix) }
        }
        return nil
    }

    static func save(_ pasteboard: NSPasteboard) throws -> [URL] {
        let stamp = DateFormatter.localizedString(
            from: Date(), dateStyle: .short, timeStyle: .medium
        )
        .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        if let pdf = pasteboard.data(forType: .pdf) {
            return [try StudioLibraryStore.saveToInbox(pdf, name: "Scan \(stamp).pdf")]
        }
        for type in [
            NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
            .png,
        ] {
            if let data = pasteboard.data(forType: type) {
                let ext = type == .png ? "png" : type.rawValue == "public.heic" ? "heic" : "jpg"
                return [try StudioLibraryStore.saveToInbox(data, name: "Photo \(stamp).\(ext)")]
            }
        }
        if let tiff = pasteboard.data(forType: .tiff), let image = NSBitmapImageRep(data: tiff),
            let jpeg = image.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        {
            return [try StudioLibraryStore.saveToInbox(jpeg, name: "Photo \(stamp).jpg")]
        }
        return []
    }
}
