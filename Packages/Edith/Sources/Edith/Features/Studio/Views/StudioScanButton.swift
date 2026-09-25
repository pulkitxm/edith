import AppKit
import EdithStudio
import SwiftUI

struct StudioScanButton: NSViewRepresentable {
    let onImport: ([URL]) -> Void

    func makeNSView(context: Context) -> StudioScanHostView {
        let view = StudioScanHostView()
        view.onImport = onImport
        return view
    }

    func updateNSView(_ view: StudioScanHostView, context: Context) {
        view.onImport = onImport
    }
}

final class StudioScanHostView: NSView, NSServicesMenuRequestor {
    var onImport: (([URL]) -> Void)?
    private let button: NSButton

    static let returnTypes: [NSPasteboard.PasteboardType] = [
        .pdf, .tiff, .png, NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
    ]

    override init(frame: NSRect) {
        button = NSButton(
            image: NSImage(
                systemSymbolName: "iphone.gen3", accessibilityDescription: "Import from iPhone")
                ?? NSImage(), target: nil, action: nil)
        super.init(frame: frame)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = true
        button.target = self
        button.action = #selector(showMenu)
        button.setAccessibilityLabel("Import from iPhone or iPad")
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    @objc func showMenu() {
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
        guard let urls = try? StudioScanImport.save(pasteboard), !urls.isEmpty else { return false }
        onImport?(urls)
        return true
    }

    func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        false
    }
}

enum StudioScanImport {
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
