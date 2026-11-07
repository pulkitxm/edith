import SwiftUI

public enum EdithRowMetrics {
    public static let plateInset = 4.0
    public static let contentHorizontal = PageMetrics.cardPadding - plateInset
    public static let contentVertical = 8.0
    public static let minimumHeight = 32.0
    public static let cornerRadius = PageMetrics.cardCornerRadius - plateInset

    static let buttonMetrics = EdithButtonMetrics(
        horizontalPadding: contentHorizontal, verticalPadding: contentVertical,
        minimumWidth: minimumHeight, minimumHeight: minimumHeight, cornerRadius: cornerRadius)

    public static func plateFrame(cell: CGRect, scale: Double = 1) -> CGRect {
        cell.insetBy(dx: plateInset * scale, dy: plateInset * scale)
    }

    public static func contentFrame(cell: CGRect, scale: Double = 1) -> CGRect {
        plateFrame(cell: cell, scale: scale).insetBy(
            dx: contentHorizontal * scale, dy: contentVertical * scale)
    }
}

public struct EdithRowSlot {
    let report: @MainActor (Bool) -> Void

    public init(report: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.report = report
    }
}

private struct EdithRowSlotKey: EnvironmentKey {
    static let defaultValue: EdithRowSlot? = nil
}

extension EnvironmentValues {
    public var edithRowSlot: EdithRowSlot? {
        get { self[EdithRowSlotKey.self] }
        set { self[EdithRowSlotKey.self] = newValue }
    }
}

public struct EdithRowList<Data: RandomAccessCollection, ID: Hashable, Row: View>: View {
    private struct Entry: Identifiable {
        let id: ID
        let element: Data.Element
    }

    private let data: Data
    private let id: KeyPath<Data.Element, ID>
    private let lazy: Bool
    private let row: (Data.Element) -> Row
    @State private var lit: Set<ID> = []

    public init(
        _ data: Data, id: KeyPath<Data.Element, ID>, lazy: Bool = false,
        @ViewBuilder row: @escaping (Data.Element) -> Row
    ) {
        self.data = data
        self.id = id
        self.lazy = lazy
        self.row = row
    }

    public var body: some View {
        let entries = data.map { Entry(id: $0[keyPath: id], element: $0) }
        let shape = RoundedRectangle(
            cornerRadius: UIScale.pt(PageMetrics.cardCornerRadius), style: .continuous)
        Group {
            if lazy {
                LazyVStack(spacing: 0) { cells(entries) }
            } else {
                VStack(spacing: 0) { cells(entries) }
            }
        }
        .edithSurface(cornerRadius: PageMetrics.cardCornerRadius)
        .clipShape(shape)
    }

    private func cells(_ entries: [Entry]) -> some View {
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            VStack(spacing: 0) {
                if index > 0 {
                    EdithRowDivider(
                        hidden: lit.contains(entry.id) || lit.contains(entries[index - 1].id))
                }
                row(entry.element)
                    .environment(
                        \.edithRowSlot,
                        EdithRowSlot { on in
                            if on { lit.insert(entry.id) } else { lit.remove(entry.id) }
                        })
            }
        }
    }
}

extension EdithRowList where Data.Element: Identifiable, ID == Data.Element.ID {
    public init(
        _ data: Data, lazy: Bool = false, @ViewBuilder row: @escaping (Data.Element) -> Row
    ) {
        self.init(data, id: \.id, lazy: lazy, row: row)
    }
}

struct EdithRowDivider: View {
    let hidden: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(DashSkin.line(scheme == .dark))
            .frame(height: 1)
            .padding(.horizontal, UIScale.pt(EdithRowMetrics.plateInset))
            .opacity(hidden ? 0 : 1)
            .accessibilityHidden(true)
    }
}

private struct EdithRowAccessorySizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}

public struct EdithRowButton<Label: View, Accessory: View>: View {
    private let action: () -> Void
    private let selected: Bool
    private let label: () -> Label
    private let accessory: () -> Accessory
    @Environment(\.edithRowSlot) private var slot
    @State private var accessorySize = CGSize.zero

    public init(
        selected: Bool = false, action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.action = action
        self.selected = selected
        self.label = label
        self.accessory = accessory
    }

    public var body: some View {
        let trailing =
            slot == nil
            ? EdithButtonMetrics.metrics(for: .row).horizontalPadding
            : EdithRowMetrics.plateInset + EdithRowMetrics.contentHorizontal
        let reserved =
            accessorySize.width > 0 ? accessorySize.width + UIScale.pt(PageMetrics.cardSpacing) : 0
        Button(action: action) {
            HStack(spacing: 0) {
                label()
                Spacer(minLength: 0)
            }
            .padding(.trailing, reserved)
            .frame(minHeight: accessorySize.height)
        }
        .buttonStyle(.edith(.row, selected: selected))
        .overlay(alignment: .trailing) {
            accessory()
                .fixedSize()
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: EdithRowAccessorySizeKey.self, value: proxy.size)
                    }
                }
                .padding(.trailing, UIScale.pt(trailing))
        }
        .onPreferenceChange(EdithRowAccessorySizeKey.self) { accessorySize = $0 }
    }
}

extension EdithRowButton where Accessory == EmptyView {
    public init(
        selected: Bool = false, action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.init(selected: selected, action: action, label: label, accessory: { EmptyView() })
    }
}
