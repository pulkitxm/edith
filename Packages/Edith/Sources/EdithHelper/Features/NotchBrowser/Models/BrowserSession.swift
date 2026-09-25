import CoreGraphics
import EdithKit
import Foundation

struct BrowserSession: Codable, Equatable, Sendable {
    var profile: String?
    var tabs: [String] = []
    var selected = 0
    var width: Double?
    var height: Double?

    var size: CGSize? {
        guard let width, let height else { return nil }
        return CGSize(width: width, height: height)
    }

    var restorableURLs: [URL] {
        tabs.compactMap(URL.init(string:)).filter { BrowserTab.origin(of: $0) != nil }
    }
}

struct BrowserSessionFile: Sendable {
    let url: URL

    static var standard: BrowserSessionFile {
        BrowserSessionFile(
            url: DataRoot.support.appendingPathComponent("notch-browser/session.json"))
    }

    func load() -> BrowserSession {
        guard let data = try? Data(contentsOf: url),
            let session = try? JSONDecoder().decode(BrowserSession.self, from: data)
        else { return BrowserSession() }
        return session
    }

    func save(_ session: BrowserSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
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
