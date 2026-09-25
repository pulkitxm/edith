import EdithKit
import SwiftUI

struct HerdrTerminalScrollbar: View {
    var scroll: HerdrTerminalScroll
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var grab: Double?

    var body: some View {
        if let info = scroll.info, info.scrollable {
            GeometryReader { proxy in
                let track = Double(proxy.size.height)
                let length = HerdrScrollbarGeometry.thumbLength(for: info, track: track)
                let top = HerdrScrollbarGeometry.thumbTop(for: info, track: track)
                let active = hovered || grab != nil
                ZStack(alignment: .topTrailing) {
                    Rectangle()
                        .fill(color.opacity(active ? 0.08 : 0))
                    Capsule()
                        .fill(color.opacity(active ? 0.55 : 0.3))
                        .frame(width: UIScale.pt(active ? 8 : 5), height: length)
                        .padding(.trailing, UIScale.pt(2))
                        .offset(y: top)
                }
                .frame(width: UIScale.pt(12), height: proxy.size.height, alignment: .topTrailing)
                .contentShape(Rectangle())
                .gesture(drag(info: info, track: track, length: length, top: top))
                .onHover { hovered = $0 }
                .animation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: active)
            }
            .frame(width: UIScale.pt(12))
            .padding(.vertical, UIScale.pt(3))
            .accessibilityElement()
            .accessibilityLabel("Terminal scrollback")
            .accessibilityValue(
                info.offset == 0 ? "At the bottom" : "\(info.offset) lines above the bottom"
            )
            .accessibilityAdjustableAction { direction in
                let page = max(1, info.viewportRows - 1)
                switch direction {
                case .increment: scroll.scroll(to: info.offset - page)
                case .decrement: scroll.scroll(to: info.offset + page)
                @unknown default: break
                }
            }
        }
    }

    private func drag(info: HerdrScrollInfo, track: Double, length: Double, top: Double)
        -> some Gesture
    {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let y = Double(value.location.y)
                let hold = grab ?? ((y >= top && y <= top + length) ? y - top : length / 2)
                grab = hold
                scroll.scroll(
                    to: HerdrScrollbarGeometry.offset(
                        forThumbTop: y - hold, info: info, track: track))
            }
            .onEnded { _ in grab = nil }
    }
}
