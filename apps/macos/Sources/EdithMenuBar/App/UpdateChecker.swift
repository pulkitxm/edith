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

func parseLatestRelease(_ line: String) -> (tag: String, dmgURL: String?)? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let fields = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
    guard let tag = fields.first, tag.hasPrefix("v") else { return nil }
    let url = fields.count > 1 && !fields[1].isEmpty ? fields[1] : nil
    return (tag, url)
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let repo = "pulkitxm/edith"

    @Published private(set) var availableTag: String?
    @Published private(set) var installing = false

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
        guard let gh = Self.ghExecutable() else { return }
        let jq =
            ".tag_name + \" \" + "
            + "([.assets[]|select(.name|endswith(\".dmg\"))][0].browser_download_url // \"\")"
        let args = ["api", "repos/\(Self.repo)/releases/latest", "--jq", jq]
        guard
            let out = await Self.run(gh, args),
            let release = parseLatestRelease(out),
            isNewerVersion(release.tag, than: currentVersion)
        else { return }
        availableTag = release.tag
        notifyOnce(release.tag)
    }

    func downloadAndOpen() {
        guard let tag = availableTag, !installing else { return }
        installing = true
        Task {
            defer { installing = false }
            guard let gh = Self.ghExecutable() else {
                NSWorkspace.shared.open(
                    URL(string: "https://github.com/\(Self.repo)/releases/latest")!)
                return
            }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("edith-update-\(tag)")
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard
                await Self.run(
                    gh,
                    [
                        "release", "download", tag, "-R", Self.repo,
                        "-p", "*.dmg", "-D", dir.path,
                    ]) != nil,
                let dmg = try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil
                ).first(where: { $0.pathExtension == "dmg" })
            else {
                NSWorkspace.shared.open(
                    URL(string: "https://github.com/\(Self.repo)/releases/latest")!)
                return
            }
            NSWorkspace.shared.open(dmg)
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

    private nonisolated static func ghExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "\(home)/.local/bin/gh",
        ]
        .map { URL(fileURLWithPath: $0) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private nonisolated static func run(_ tool: URL, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = tool
            p.arguments = arguments
            p.qualityOfService = .utility
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            p.terminationHandler = { proc in
                guard proc.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
            do {
                try p.run()
            } catch {
                p.terminationHandler = nil
                continuation.resume(returning: nil)
            }
        }
    }
}
