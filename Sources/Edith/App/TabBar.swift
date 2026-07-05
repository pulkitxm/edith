import AppKit
import SwiftUI

struct TabBar: View {
    let tabs: [(id: String, title: String)]
    @Binding var selection: String
    let theme: Color
    @State private var chipFrames: [String: CGRect] = [:]

    private struct ChipFramesKey: PreferenceKey {
        static var defaultValue: [String: CGRect] { [:] }
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue()) { $1 }
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(expand: true)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    row(expand: false)
                }
                .onChange(of: selection) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(selection, anchor: .center)
                    }
                }
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
        }
        .background(.primary.opacity(0.06), in: Capsule())
    }

    private func row(expand: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.id) { entry in
                chip(entry, expand: expand)
                    .id(entry.id)
            }
        }
        .padding(3)
        .coordinateSpace(name: "tabbar")
        .background(alignment: .topLeading) {
            if let frame = chipFrames[selection] {
                Capsule()
                    .fill(theme)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selection)
            }
        }
        .onPreferenceChange(ChipFramesKey.self) { chipFrames = $0 }
    }

    private func chip(_ entry: (id: String, title: String), expand: Bool) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                selection = entry.id
            }
        } label: {
            Text(entry.title)
                .font(.system(size: 13, weight: selection == entry.id ? .semibold : .regular))
                .foregroundStyle(selection == entry.id ? .white : .secondary)
                .lineLimit(1)
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
                .frame(maxWidth: expand ? .infinity : nil)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ChipFramesKey.self,
                            value: [entry.id: geo.frame(in: .named("tabbar"))])
                    }
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { over in
            over ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
        }
    }
}
