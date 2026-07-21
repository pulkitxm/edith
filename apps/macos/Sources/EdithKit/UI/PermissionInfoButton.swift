import SwiftUI

public struct PermissionInfoButton: View {
    private let permissions: [ExtensionPermission]
    private let label: String?
    private let color: Color
    @State private var showing = false

    public init(
        permissions: [ExtensionPermission], label: String? = nil, color: Color = .secondary
    ) {
        self.permissions = permissions
        self.label = label
        self.color = color
    }

    public init(_ permission: ExtensionPermission) {
        permissions = [permission]
        label = nil
        color = .secondary
    }

    public var body: some View {
        Button {
            showing.toggle()
        } label: {
            if let label {
                HStack(spacing: UIScale.pt(4)) {
                    Text(label)
                    Image(systemName: "info.circle")
                }
                .font(.system(size: UIScale.pt(10), weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, UIScale.pt(7))
                .padding(.vertical, UIScale.pt(3))
                .background(color.opacity(0.12), in: Capsule())
            } else {
                Image(systemName: "info.circle")
                    .font(.system(size: UIScale.pt(10)))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(color)
        .pointerCursor()
        .accessibilityLabel("Permission details")
        .help("Permission details")
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                ForEach(permissions, id: \.self) { permission in
                    VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                        Text(permission.displayName)
                            .font(.system(size: UIScale.pt(10), weight: .semibold))
                        Text(permission.reason)
                            .font(.system(size: UIScale.pt(10)))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: UIScale.pt(280), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(UIScale.pt(12))
        }
    }
}
