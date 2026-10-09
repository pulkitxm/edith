import AppKit
import UniformTypeIdentifiers

public enum ExportDeliveryError: LocalizedError {
    case copyFailed

    public var errorDescription: String? { "The image could not be copied." }
}

public enum ExportDelivery {
    public static func copyPNG(_ data: Data, to pasteboard: NSPasteboard = .general) throws {
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: .png) else { throw ExportDeliveryError.copyFailed }
    }

    public static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    @MainActor
    public static func chooseSaveURL(suggestedName: String, in window: NSWindow?) async -> URL? {
        guard !Task.isCancelled, window?.attachedSheet == nil else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedName
        let url: URL? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let completion: (NSApplication.ModalResponse) -> Void = { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
                if let window {
                    panel.beginSheetModal(for: window, completionHandler: completion)
                } else {
                    panel.begin(completionHandler: completion)
                }
            }
        } onCancel: {
            Task { @MainActor in panel.cancel(nil) }
        }
        return Task.isCancelled ? nil : url
    }
}
