import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct WorkspacePaneIdentity {
    let title: String
    let category: String
    let symbol: String
    var image: NSImage?
}

@MainActor
protocol PaneWorkspaceInteractions: AnyObject {
    var interactionTab: HerdrTab? { get }
    var interactionTabIDs: [String] { get }
    var interactionLibraryID: String { get }
    var interactionSelection: String { get set }
    var layoutAnimation: Animation? { get }
    func normalized(_ item: HerdrDragItem) -> HerdrDragItem
    func snapCount(for item: HerdrDragItem) -> Int?
    func templates(for count: Int) -> [HerdrLayoutTemplate]
    func proposedLayout(_ item: HerdrDragItem, _ target: HerdrDropTarget) -> HerdrLayout?
    func accepts(_ item: HerdrDragItem, _ target: HerdrDropTarget) -> Bool
    func drop(_ item: HerdrDragItem, on target: HerdrDropTarget)
    func draggedPaneIDs(_ item: HerdrDragItem) -> [String]
    func paneIdentity(_ id: String) -> WorkspacePaneIdentity?
    func paneIsOpen(_ id: String) -> Bool
    func dragTitle(_ item: HerdrDragItem) -> String
    func sidebarTarget(_ item: HerdrDragItem, at point: CGPoint, frames: [String: CGRect])
        -> HerdrDropTarget?
}

struct WorkspacePaneMark: View {
    let pane: WorkspacePaneIdentity
    var size: CGFloat

    var body: some View {
        Group {
            if let image = pane.image {
                Image(nsImage: image).resizable().scaledToFill().clipShape(Circle())
            } else {
                Image(systemName: pane.symbol).font(.system(size: size))
            }
        }.frame(width: size, height: size)
    }
}

struct WorkspacePaneMarks: View {
    let panes: [WorkspacePaneIdentity]
    let dark: Bool
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: UIScale.pt(-3)) {
            ForEach(Array(panes.prefix(3).enumerated()), id: \.offset) { _, pane in
                WorkspacePaneMark(pane: pane, size: UIScale.pt(size))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .padding(UIScale.pt(1.5))
                    .background(DashSkin.paper2(dark), in: Circle())
            }
        }
    }
}
