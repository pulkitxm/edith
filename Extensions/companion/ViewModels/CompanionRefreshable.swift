import EdithExtensionUI
import EdithExtensionSupport
@MainActor
protocol CompanionRefreshable: AnyObject {
    func refresh() async
}
