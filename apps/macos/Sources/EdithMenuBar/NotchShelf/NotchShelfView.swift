import AppKit
import SwiftUI

struct NotchShelfContentView: View {
    @ObservedObject var controller: NotchShelfController

    var body: some View {
        ZStack {
            if controller.isExpanded {
                expanded
            } else {
                collapsed
            }
        }
        .onHover { controller.hoverChanged($0) }
    }

    private var collapsed: some View {
        Capsule()
            .fill(.black)
            .overlay {
                if !controller.items.isEmpty {
                    Text("\(controller.items.count)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
    }

    private var expanded: some View {
        Group {
            if controller.items.isEmpty {
                Text("Drop files here to park them")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(controller.items) { item in
                            ShelfItemView(item: item, controller: controller)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black, in: RoundedRectangle(cornerRadius: 22))
    }
}

private struct ShelfItemView: View {
    let item: ShelfItem
    @ObservedObject var controller: NotchShelfController

    var body: some View {
        Menu {
            Button("Open") { controller.open(item) }
            Button("Reveal in Finder") { controller.reveal(item) }
            Button("Clear", role: .destructive) { controller.remove(item) }
        } label: {
            VStack(spacing: 4) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: controller.fileURL(for: item).path))
                    .resizable()
                    .frame(width: 38, height: 38)
                Text(item.name)
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: 64)
            }
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .onDrag { controller.dragOutProvider(for: item) }
    }
}
