public enum UsageSourceSelection {
    public static func reconcile(
        selected: Set<String>?, known: Set<String>?, available: Set<String>,
        defaults: Set<String>
    ) -> Set<String> {
        guard !available.isEmpty else { return [] }
        let fallback = defaults.intersection(available)
        guard let selected, !selected.isEmpty, let known else {
            return fallback.isEmpty ? available : fallback
        }
        let next = selected.union(available.subtracting(known)).intersection(available)
        return next.isEmpty ? (fallback.isEmpty ? available : fallback) : next
    }
}
