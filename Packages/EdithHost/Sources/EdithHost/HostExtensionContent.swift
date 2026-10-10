import AppKit
import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostExtensionContentRequest: Equatable, Sendable {
    let extensionID: String
    let location: String
    let section: String?
    let presentationID: UUID
}

@MainActor protocol HostExtensionContentPresenting: AnyObject {
    func controller(for request: HostExtensionContentRequest) async throws -> NSViewController
    func endPresentation(id: UUID)
}

struct HostExtensionContent: View {
    let marketplace: HostMarketplace
    let extensionID: String
    let location: String
    var section: String? = nil
    let presenter: (any HostExtensionContentPresenting)?
    let openMarketplace: () -> Void
    @State private var controller: NSViewController?
    @State private var presentationID = UUID()
    @State private var error: String?

    private var active: Bool { marketplace.surfaceAvailability.activeIDs.contains(extensionID) }
    private var title: String {
        marketplace.entries.first { $0.id == extensionID }?.title ?? extensionID
    }
    var body: some View {
        Group {
            if let controller {
                HostEmbeddedController(controller: controller)
            } else if !active {
                ContentUnavailableView {
                    Label(title, systemImage: "puzzlepiece.extension")
                } description: {
                    Text(
                        marketplace.downloadedIDs.contains(extensionID)
                            ? "Enable this extension to open its page."
                            : "Download this extension to open its page.")
                } actions: {
                    Button("Extensions", action: openMarketplace).buttonStyle(.edith(.secondary))
                }
            } else if presenter == nil {
                ContentUnavailableView(
                    title, systemImage: "puzzlepiece.extension",
                    description: Text("The extension view is not connected."))
            } else if let error {
                ContentUnavailableView(
                    title, systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                PageLoading(state: .loading, title: "Opening " + title) { EmptyView() }
            }
        }
        .pageTask(
            id: Request(
                version: marketplace.sessions.versions[extensionID], location: location,
                section: section), active: active && presenter != nil, cancel: clear
        ) {
            guard let presenter else { return }
            let token = UUID()
            presentationID = token
            do {
                let loaded = try await presenter.controller(
                    for: .init(
                        extensionID: extensionID, location: location, section: section,
                        presentationID: token))
                guard !Task.isCancelled, presentationID == token else {
                    presenter.endPresentation(id: token); return
                }
                controller = loaded
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "The extension page could not open."
            }
        }
        .onDisappear(perform: clear)
    }
    private struct Request: Equatable {
        let version: String?; let location: String; let section: String?
    }
    private func clear() {
        presenter?.endPresentation(id: presentationID); controller = nil; error = nil
    }
}

private struct HostEmbeddedController: NSViewControllerRepresentable {
    let controller: NSViewController
    func makeNSViewController(context: Context) -> NSViewController { controller }
    func updateNSViewController(_ controller: NSViewController, context: Context) {}
}
