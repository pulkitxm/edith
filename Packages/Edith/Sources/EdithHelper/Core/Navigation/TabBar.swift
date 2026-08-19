import AppKit
import EdithKit
import SwiftUI

struct TabBar: View {
    let tabs: [(id: String, title: String)]
    @Binding var selection: String
    let theme: Color
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.id) { entry in
                chip(entry)
            }
        }
        .padding(3)
        .background(DashSkin.line(dark), in: Capsule())
    }

    private func chip(_ entry: (id: String, title: String)) -> some View {
        let selected = selection == entry.id
        return Button {
            selection = entry.id
        } label: {
            Text(entry.title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .white : DashSkin.inkSoft(dark))
                .lineLimit(1)
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .background(
                    selected ? AnyShapeStyle(theme) : AnyShapeStyle(Color.clear),
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
