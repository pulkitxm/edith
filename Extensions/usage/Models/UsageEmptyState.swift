import EdithExtensionUI

enum UsageEmptyState: Equatable {
    case none
    case collecting
    case firstRun
    case failed(String)

    static func resolve(
        state: ContentLoadingState, loaded: Bool, updating: Bool, errorMessage: String?
    ) -> UsageEmptyState {
        guard !loaded else { return .none }
        switch state {
        case .content, .loading, .cancelled:
            return .none
        case .empty:
            return updating ? .collecting : .firstRun
        case .error, .offline:
            if updating { return .collecting }
            return .failed(errorMessage ?? "Usage data could not be read.")
        }
    }
}
