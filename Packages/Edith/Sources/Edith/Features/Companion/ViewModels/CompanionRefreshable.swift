@MainActor
protocol CompanionRefreshable: AnyObject {
    func refresh() async
}
