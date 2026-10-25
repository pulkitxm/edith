public enum MultiSelectLogic {
    public struct Outcome<ID: Hashable>: Equatable {
        public let selection: Set<ID>
        public let anchor: ID?
        public let anchorSelected: Bool
        public let dismiss: Bool

        public init(selection: Set<ID>, anchor: ID?, anchorSelected: Bool, dismiss: Bool) {
            self.selection = selection
            self.anchor = anchor
            self.anchorSelected = anchorSelected
            self.dismiss = dismiss
        }
    }

    public static func toggle<ID>(
        _ id: ID, selection: Set<ID>
    ) -> Outcome<ID> {
        var next = selection
        let nowSelected: Bool
        if next.contains(id) {
            if next.count > 1 { next.remove(id) }
            nowSelected = next.contains(id)
        } else {
            next.insert(id)
            nowSelected = true
        }
        return Outcome(selection: next, anchor: id, anchorSelected: nowSelected, dismiss: false)
    }

    public static func rangeApply<ID>(
        _ id: ID, order: [ID], selection: Set<ID>, anchor: ID?, anchorSelected: Bool
    ) -> Outcome<ID> {
        guard let anchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id)
        else {
            return toggle(id, selection: selection)
        }
        let range = order[min(a, b)...max(a, b)]
        var next = selection
        if anchorSelected {
            next.formUnion(range)
        } else {
            next.subtract(range)
            if next.isEmpty { next = [id] }
        }
        return Outcome(
            selection: next, anchor: anchor, anchorSelected: anchorSelected, dismiss: false)
    }

    public static func rowClick<ID>(
        _ id: ID, order: [ID], selection: Set<ID>, anchor: ID?, anchorSelected: Bool,
        toggleModifier: Bool, rangeModifier: Bool
    ) -> Outcome<ID> {
        if rangeModifier {
            return rangeApply(
                id, order: order, selection: selection, anchor: anchor,
                anchorSelected: anchorSelected)
        }
        if toggleModifier { return toggle(id, selection: selection) }
        return Outcome(selection: [id], anchor: id, anchorSelected: true, dismiss: true)
    }

    public static func actionClick<ID>(
        _ id: ID, order: [ID], selection: Set<ID>
    ) -> Outcome<ID> {
        if selection == [id] {
            return Outcome(
                selection: Set(order), anchor: id, anchorSelected: true, dismiss: false)
        }
        return Outcome(selection: [id], anchor: id, anchorSelected: true, dismiss: false)
    }

    public static func actionLabel<ID>(_ id: ID, selection: Set<ID>) -> String {
        selection == [id] ? "All" : "Only"
    }

    public static func selectAll<ID>(order: [ID]) -> Outcome<ID> {
        Outcome(selection: Set(order), anchor: nil, anchorSelected: true, dismiss: false)
    }
}
