import SwiftUI

public struct InfoDot: View {
    private let text: String
    @State private var showing = false

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("More info")
        .help("More info")
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            Text(text)
                .font(.system(size: 12))
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }
}
