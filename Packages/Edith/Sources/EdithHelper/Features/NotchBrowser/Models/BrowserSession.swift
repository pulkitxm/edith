import EdithKit
import Foundation

extension BrowserSession {
    var restorableURLs: [URL] {
        tabs.compactMap(URL.init(string:)).filter { BrowserTab.origin(of: $0) != nil }
    }
}

struct BrowserDialog: Identifiable {
    enum Kind: Equatable {
        case alert
        case confirm
        case prompt(defaultText: String)
    }

    let id = UUID()
    let kind: Kind
    let host: String
    let message: String
    let resolve: @MainActor (Bool, String?) -> Void
}
