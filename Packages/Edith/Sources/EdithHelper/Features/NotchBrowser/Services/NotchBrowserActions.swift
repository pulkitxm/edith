import EdithKit
import Foundation
import WebKit

struct NotchBrowserActionError: LocalizedError, Equatable {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }
}

extension NotchBrowserStore {
    func perform(_ request: NotchBrowserRequest) throws -> NotchBrowserSnapshot {
        var link: String?
        switch request {
        case .status:
            break
        case .navigate(let text, let tab):
            try requireAttached()
            let target = try resolvedTab(tab)
            guard let url = BrowserAddress.url(for: text, engine: searchEngine) else {
                throw NotchBrowserActionError("That address is empty.")
            }
            target.webView.load(URLRequest(url: url))
        case .reload(let hard, let tab):
            try requireAttached()
            let target = try resolvedTab(tab)
            if hard { target.webView.reloadFromOrigin() } else { target.webView.reload() }
        case .copyLink(let tab):
            try requireAttached()
            let target = try resolvedTab(tab)
            guard let url = target.url?.absoluteString, !url.isEmpty else {
                throw NotchBrowserActionError("That tab has no address to copy.")
            }
            link = url
        case .close(let tab):
            try requireAttached()
            close(try resolvedTab(tab))
        case .closeOthers(let tab):
            try requireAttached()
            closeOthers(try resolvedTab(tab))
        case .closeRight(let tab):
            try requireAttached()
            closeToRight(try resolvedTab(tab))
        case .reopen:
            try requireAttached()
            guard canReopenClosedTab else {
                throw NotchBrowserActionError("There is no closed tab to reopen.")
            }
            reopenClosedTab()
        case .duplicate(let tab):
            try requireAttached()
            guard duplicate(try resolvedTab(tab)) != nil else {
                throw NotchBrowserActionError("That tab could not be duplicated.")
            }
        case .sync:
            try requireAttached()
            syncNow()
        case .profile(let query):
            attach(try matchingProfile(query))
        case .detach:
            detach()
        case .newTab(let text):
            try requireAttached()
            let url = try text.map { value -> URL in
                guard let url = BrowserAddress.url(for: value, engine: searchEngine) else {
                    throw NotchBrowserActionError("That address is empty.")
                }
                return url
            }
            guard newTab(url) != nil else {
                throw NotchBrowserActionError("A tab could not be opened.")
            }
        }
        return snapshot(link: link)
    }

    func snapshot(link: String? = nil) -> NotchBrowserSnapshot {
        NotchBrowserSnapshot(
            attached: profile != nil && !choosingProfile,
            profile: profile.map { NotchBrowserProfileState(id: $0.directory, name: $0.name) },
            profiles: profiles.map { NotchBrowserProfileState(id: $0.directory, name: $0.name) },
            tabs: tabs.enumerated().map { index, tab in
                NotchBrowserTabState(
                    id: tab.id.uuidString, index: index + 1, title: tab.displayTitle,
                    url: tab.url?.absoluteString, selected: tab.id == selectedTabID,
                    loading: tab.isLoading)
            },
            sync: syncLabel, canReopen: canReopenClosedTab, link: link)
    }

    private var syncLabel: String {
        switch syncState {
        case .idle: syncSummary ?? "idle"
        case .unlocking: "unlocking"
        case .importing(let text): text
        case .failed(let text): text
        }
    }

    private func requireAttached() throws {
        guard profile != nil, !choosingProfile else {
            throw NotchBrowserActionError(
                "No Chrome profile is attached. Run `ed browser profile` with a profile name.")
        }
    }

    private func resolvedTab(_ token: String?) throws -> BrowserTab {
        if let token {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = UUID(uuidString: trimmed), let tab = tabs.first(where: { $0.id == id }) {
                return tab
            }
            if let index = Int(trimmed), tabs.indices.contains(index - 1) {
                return tabs[index - 1]
            }
            throw NotchBrowserActionError("No tab matches \(trimmed).")
        }
        guard let selectedTab else {
            throw NotchBrowserActionError("There is no selected tab.")
        }
        return selectedTab
    }

    private func matchingProfile(_ query: String) throws -> ChromeProfile {
        refreshEnvironment()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            throw NotchBrowserActionError("Name the Chrome profile to attach.")
        }
        let exact = profiles.filter {
            $0.directory.caseInsensitiveCompare(needle) == .orderedSame
                || $0.name.caseInsensitiveCompare(needle) == .orderedSame
        }
        if exact.count == 1, let profile = exact.first { return profile }
        let partial = profiles.filter { $0.name.localizedStandardContains(needle) }
        if exact.isEmpty, partial.count == 1, let profile = partial.first { return profile }
        let names = profiles.map(\.name).joined(separator: ", ")
        throw NotchBrowserActionError(
            names.isEmpty
                ? "Chrome has no profiles Edith can attach."
                : "No single profile matches \(needle). Profiles: \(names).")
    }
}
