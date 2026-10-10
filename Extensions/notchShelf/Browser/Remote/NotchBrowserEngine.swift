import AppKit
import EdithExtensionSupport
import Foundation

@MainActor final class NotchBrowserEngine {
    private let installation: ChromeInstallation
    private let sessionFile: BrowserSessionFile
    private let defaults: UserDefaults
    private let keyProvider: @Sendable () throws -> ChromeCookieKey
    private let open: (URL, ChromeProfile?) -> Void
    private let openURL: (URL) -> Bool
    private(set) var session: BrowserSession
    private var cookieKey: ChromeCookieKey?
    private var importTask: Task<Result<(ChromeCookieKey, ChromeProfileSnapshot), Error>, Never>?
    private var imported: (NotchBrowserImport, Data)?
    private var stopped = false
    private let downloads: NotchBrowserDownloadEngine
    private var importExpiry: Task<Void, Never>?
    var held = false
    var changed: (() -> Void)?

    init(
        installation: ChromeInstallation = .live, sessionFile: BrowserSessionFile = .standard,
        defaults: UserDefaults,
        keyProvider: @escaping @Sendable () throws -> ChromeCookieKey = {
            try ChromeSafeStorage.keychainKey()
        },
        open: ((URL, ChromeProfile?) -> Void)? = nil, downloads: NotchBrowserDownloadEngine? = nil,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.openURL = openURL
        self.downloads = downloads ?? NotchBrowserDownloadEngine()
        self.installation = installation
        self.sessionFile = sessionFile
        self.defaults = defaults
        self.keyProvider = keyProvider
        self.open = open ?? { installation.open($0, profile: $1) }
        session = sessionFile.load()
    }

    var size: CGSize { session.size ?? NotchBrowserGeometry.defaultSize }
    var profileName: String? { session.profileName }

    func state(includeAvatars: Bool = true) throws -> NotchBrowserClientState {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        let inspected = installation.inspect()
        guard inspected.profiles.count <= 128 else { throw ExtensionPeerError.invalidRequest }
        var avatars: [String: Data] = [:]
        var totalBytes = 0
        for profile in includeAvatars ? inspected.profiles : [] {
            guard let url = profile.pictureURL, let handle = try? FileHandle(forReadingFrom: url)
            else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 65537), data.count <= 65536,
                totalBytes + data.count <= 65536
            else { continue }
            avatars[profile.id] = data
            totalBytes += data.count
        }
        let state = NotchBrowserClientState(
            readiness: inspected.readiness,
            profiles: inspected.profiles.map {
                .init(
                    directory: $0.directory, name: $0.name, email: $0.email, pictureURL: nil,
                    colorARGB: $0.colorARGB)
            },
            avatars: avatars, session: session,
            searchEngine: defaults.string(forKey: AppStorageKeys.Notch.browserSearchEngine)
                ?? BrowserSearchEngine.google.rawValue,
            dataStoreID: inspected.profiles.first(where: { $0.directory == session.profile }).map {
                ChromeProfileImporter.dataStoreIdentifier(
                    profile: $0, userData: installation.userData)
            })
        guard try JSONEncoder().encode(state).count <= NotchPanelEngine.maximumBytes else {
            throw ExtensionPeerError.rejected("The browser profile state exceeds its capacity.")
        }
        return state
    }

    func execute(_ request: NotchBrowserRemoteRequest) async throws -> Data {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        let encoder = JSONEncoder()
        switch request.operation {
        case .downloadStart:
            guard let name = request.fileName else { throw ExtensionPeerError.invalidRequest }
            return try encoder.encode(downloads.start(name))
        case .downloadWrite:
            guard let id = request.downloadID, let offset = request.byteOffset,
                let bytes = request.bytes
            else { throw ExtensionPeerError.invalidRequest }
            try downloads.write(id: id, offset: offset, bytes: bytes)
            return Data("{}".utf8)
        case .downloadCommit:
            guard let id = request.downloadID else { throw ExtensionPeerError.invalidRequest }
            return try encoder.encode(downloads.commit(id: id))
        case .downloadCancel:
            guard let id = request.downloadID else { throw ExtensionPeerError.invalidRequest }
            downloads.cancel(id: id)
            return Data("{}".utf8)
        case .read: break
        case .importStart: return try encoder.encode(await beginImport(request.profileID))
        case .importRead:
            guard let imported, request.importID == imported.0.id, let offset = request.offset,
                offset >= 0, offset < imported.1.count
            else { throw ExtensionPeerError.invalidRequest }
            let end = min(offset + 65536, imported.1.count)
            return try encoder.encode(
                NotchBrowserImportChunk(
                    id: imported.0.id, offset: offset, nextOffset: end,
                    bytes: imported.1.subdata(in: offset..<end)))
        case .importEnd:
            guard let imported, request.importID == imported.0.id else {
                throw ExtensionPeerError.invalidRequest
            }
            self.imported = nil
            importExpiry?.cancel(); importExpiry = nil
        case .save:
            guard let session = request.session, session.tabs.count <= 128,
                session.tabs.allSatisfy({ $0.utf8.count <= 16384 && URL(string: $0) != nil }),
                session.selected >= 0, session.selected < max(1, session.tabs.count),
                session.profile == nil
                    || installation.inspect().profiles.contains(where: {
                        $0.directory == session.profile
                    }),
                session.size.map({
                    $0.width.isFinite && $0.height.isFinite && (240...1200).contains($0.width)
                        && (120...1024).contains($0.height)
                }) ?? true
            else { throw ExtensionPeerError.invalidRequest }
            self.session = session
            sessionFile.save(session)
            changed?()
        case .detach:
            imported = nil; cookieKey = nil
            session.profile = nil; session.profileName = nil; session.tabs = [];
            session.selected = 0
            sessionFile.save(session)
            changed?()
        case .held:
            guard let held = request.held else { throw ExtensionPeerError.invalidRequest }
            self.held = held
            changed?()
        case .openInChrome:
            guard let link = request.link, link.utf8.count <= 16384, let url = URL(string: link),
                ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { throw ExtensionPeerError.invalidRequest }
            let profile = installation.inspect().profiles.first { $0.directory == session.profile }
            open(url, profile)
        case .copyLink:
            guard let link = request.link, link.utf8.count <= 16384, URL(string: link) != nil else {
                throw ExtensionPeerError.invalidRequest
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        case .downloadChrome:
            guard openURL(ChromeInstallation.downloadURL) else {
                throw ExtensionPeerError.unavailable
            }
        case .privacy:
            guard openURL(ChromeInstallation.privacySettingsURL) else {
                throw ExtensionPeerError.unavailable
            }
        case .makeDefault:
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                installation.makeDefaultBrowser { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
        return try encoder.encode(state())
    }

    private func beginImport(_ profileID: String?) async throws -> NotchBrowserImport {
        guard importTask == nil, imported == nil, let profileID,
            let profile = installation.inspect().profiles.first(where: { $0.directory == profileID }
            )
        else { throw ExtensionPeerError.invalidRequest }
        let userData = installation.userData
        let cached = cookieKey
        let provider = keyProvider
        let task = Task.detached(priority: .userInitiated) {
            Result { () throws -> (ChromeCookieKey, ChromeProfileSnapshot) in
                try Task.checkCancellation()
                let key = try cached ?? provider()
                let snapshot = try ChromeProfileImporter.snapshot(
                    profile: profile, userData: userData, key: key, cookiesUpdatedAfter: nil,
                    includeLocalStorage: true)
                try Task.checkCancellation()
                return (key, snapshot)
            }
        }
        importTask = task
        defer { importTask = nil }
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
        let (key, snapshot) = try outcome.get()
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 33554432 else {
            throw ExtensionPeerError.rejected("The browser import exceeds its capacity.")
        }
        cookieKey = key
        var updated = session
        updated.profile = profile.directory; updated.profileName = profile.name
        let descriptor = NotchBrowserImport(
            id: UUID(),
            profile: .init(
                directory: profile.directory, name: profile.name, email: profile.email,
                pictureURL: nil, colorARGB: profile.colorARGB),
            dataStoreID: ChromeProfileImporter.dataStoreIdentifier(
                profile: profile, userData: userData), byteCount: data.count, session: updated)
        imported = (descriptor, data)
        importExpiry?.cancel()
        importExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            if self?.imported?.0.id == descriptor.id { self?.imported = nil }
        }
        return descriptor
    }

    func detach() {
        imported = nil; cookieKey = nil
        session.profile = nil; session.profileName = nil; session.tabs = []; session.selected = 0
        sessionFile.save(session); changed?()
    }

    func stop() {
        stopped = true; importTask?.cancel(); imported = nil; cookieKey = nil; changed = nil
        importExpiry?.cancel(); importExpiry = nil; downloads.stop()
    }
    func stopAndWait() async {
        let task = importTask
        stop()
        _ = await task?.value
    }
}
