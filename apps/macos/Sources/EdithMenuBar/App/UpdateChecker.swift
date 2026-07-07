import AppKit
import UserNotifications

func isNewerVersion(_ candidate: String, than current: String) -> Bool {
    func parts(_ s: String) -> [Int] {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            .split(separator: ".").map { Int($0) ?? 0 }
    }
    let a = parts(candidate)
    let b = parts(current)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

struct LatestRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    var dmgDownloadURL: URL? {
        assets.first { $0.name.hasSuffix(".dmg") }
            .flatMap { URL(string: $0.browserDownloadURL) }
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let releasesRepo = "pulkitxm/edith-releases"
    static let releasesPage = URL(string: "https://github.com/\(releasesRepo)/releases/latest")!

    @Published private(set) var availableTag: String?
    @Published private(set) var installing = false

    private var dmgURL: URL?
    private var timer: Timer?

    var availableVersion: String? {
        availableTag.map { String($0.dropFirst()) }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func start() {
        guard timer == nil else { return }
        Task { await self.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await UpdateChecker.shared.check() }
        }
    }

    func check() async {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(Self.releasesRepo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let release = try? JSONDecoder().decode(LatestRelease.self, from: data),
            isNewerVersion(release.tagName, than: currentVersion)
        else { return }
        availableTag = release.tagName
        dmgURL = release.dmgDownloadURL
        notifyOnce(release.tagName)
    }

    func downloadAndOpen() {
        guard let tag = availableTag, !installing else { return }
        guard let dmgURL else {
            NSWorkspace.shared.open(Self.releasesPage)
            return
        }
        installing = true
        Task {
            defer { installing = false }
            guard let (downloaded, _) = try? await URLSession.shared.download(from: dmgURL) else {
                NSWorkspace.shared.open(Self.releasesPage)
                return
            }
            let dmg = FileManager.default.temporaryDirectory
                .appendingPathComponent("Edith-\(tag).dmg")
            try? FileManager.default.removeItem(at: dmg)
            do {
                try FileManager.default.moveItem(at: downloaded, to: dmg)
                NSWorkspace.shared.open(dmg)
            } catch {
                NSWorkspace.shared.open(Self.releasesPage)
            }
        }
    }

    private func notifyOnce(_ tag: String) {
        let d = UserDefaults.standard
        guard d.string(forKey: "updateNotifiedTag") != tag else { return }
        d.set(tag, forKey: "updateNotifiedTag")
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = "Edith update available"
            content.body =
                "Version \(tag.dropFirst()) is ready - open the menu bar panel to install."
            try? await center.add(
                UNNotificationRequest(
                    identifier: "edith-update-\(tag)", content: content, trigger: nil))
        }
    }
}
