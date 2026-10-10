import EdithExtensionUI
import SwiftUI

struct HostPageTabPicker<Option: Hashable>: View {
    let title: String
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String
    @Environment(\.compactLayout) private var compact

    var body: some View {
        if compact {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.large)
            .font(.edithText(.body))
            .accessibilityLabel(title)
        } else {
            EdithSegmentedPicker(title, selection: $selection, options: options, label: label)
                .labelsHidden()
        }
    }
}

struct HostPermissionInfoButton: View {
    private let permissions: [HostPermission]
    private let label: String?
    private let color: Color
    @State private var showing = false

    init(
        permissions: [HostPermission], label: String? = nil, color: Color = .secondary
    ) {
        self.permissions = permissions
        self.label = label
        self.color = color
    }

    init(_ permission: HostPermission) {
        permissions = [permission]
        label = nil
        color = .secondary
    }

    var body: some View {
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
        .buttonStyle(.edith(.borderless))
        .foregroundStyle(color)
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
