import Foundation
import Testing

@testable import EdithKit

@Suite struct RestoredPathValidationTests {
    private let home = URL(fileURLWithPath: "/Users/x")

    @Test func keepsPathUnderHome() {
        #expect(
            RestoredPathValidation.verdict(for: "/Users/x/Projects/edith", homeDirectory: home)
                == .keep)
    }

    @Test func keepsPathEqualToHome() {
        #expect(RestoredPathValidation.verdict(for: "/Users/x", homeDirectory: home) == .keep)
    }

    @Test func keepsSiblingWithSharedPrefix() {
        #expect(RestoredPathValidation.verdict(for: "/Users/xy", homeDirectory: home) == .keep)
    }

    @Test func dropsVolumesPath() {
        #expect(
            RestoredPathValidation.verdict(for: "/Volumes/External/repo", homeDirectory: home)
                == .drop)
    }

    @Test func dropsVolumesRoot() {
        #expect(RestoredPathValidation.verdict(for: "/Volumes", homeDirectory: home) == .drop)
    }

    @Test func keepsVolumesSiblingWithSharedPrefix() {
        #expect(
            RestoredPathValidation.verdict(for: "/VolumesBackup/repo", homeDirectory: home)
                == .keep)
    }

    @Test func keepsVolumesPathInsideVolumesHome() {
        let externalHome = URL(fileURLWithPath: "/Volumes/SSD/home")
        #expect(
            RestoredPathValidation.verdict(
                for: "/Volumes/SSD/home/dev", homeDirectory: externalHome) == .keep)
    }

    @Test func keepsNonHomeNonVolumesPath() {
        #expect(RestoredPathValidation.verdict(for: "/opt/dev", homeDirectory: home) == .keep)
    }

    @Test func standardizesBeforeJudging() {
        #expect(
            RestoredPathValidation.verdict(for: "/Users/x/./dev/", homeDirectory: home) == .keep)
        #expect(
            RestoredPathValidation.verdict(for: "/Users/x/../../Volumes/d", homeDirectory: home)
                == .drop)
    }
}

@Suite(.serialized) struct RepoConfirmedPathTests {
    private static let keys = [
        Repo.musicFolderPathKey, "musicFolderExternalConfirmation", Repo.musicFolderStaleKey,
    ]

    private func withCleanRepoKeys(_ body: () -> Void) {
        let saved = Self.keys.map { ($0, SharedDefaults.store.object(forKey: $0)) }
        for key in Self.keys {
            SharedDefaults.store.removeObject(forKey: key)
        }
        defer {
            for (key, value) in saved {
                if let value {
                    SharedDefaults.store.set(value, forKey: key)
                } else {
                    SharedDefaults.store.removeObject(forKey: key)
                }
            }
        }
        body()
    }

    private var homePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("EdithTest-\(UUID().uuidString)").path
    }

    private var externalPath: String {
        "/Volumes/EdithTest-\(UUID().uuidString)/music"
    }

    @Test func prepareDropsUnconfirmedExternalMusicPathAndMarksStale() {
        withCleanRepoKeys {
            SharedDefaults.store.set(externalPath, forKey: Repo.musicFolderPathKey)
            Repo.prepareStoredPaths()
            #expect(SharedDefaults.store.string(forKey: Repo.musicFolderPathKey) == nil)
            #expect(SharedDefaults.store.bool(forKey: Repo.musicFolderStaleKey))
        }
    }

    @Test func setMusicDirectoryConfirmsExternalPathAndClearsStale() {
        withCleanRepoKeys {
            SharedDefaults.store.set(true, forKey: Repo.musicFolderStaleKey)
            let url = URL(fileURLWithPath: externalPath)
            Repo.setMusicDirectory(url)
            #expect(!SharedDefaults.store.bool(forKey: Repo.musicFolderStaleKey))
            #expect(Repo.musicDir == url.standardizedFileURL)
            Repo.prepareStoredPaths()
            #expect(Repo.musicDir == url.standardizedFileURL)
        }
    }

    @Test func unconfirmedExternalMusicPathFallsBackToTheDataRoot() {
        withCleanRepoKeys {
            SharedDefaults.store.set(externalPath, forKey: Repo.musicFolderPathKey)
            #expect(Repo.musicDir == DataRoot.music)
        }
    }

    @Test func aHomeMusicFolderNeedsNoConfirmation() {
        withCleanRepoKeys {
            let url = URL(fileURLWithPath: homePath)
            Repo.setMusicDirectory(url)
            #expect(Repo.musicDir == url.standardizedFileURL)
            #expect(
                SharedDefaults.store.string(forKey: "musicFolderExternalConfirmation") == nil)
        }
    }
}

@Suite struct DataRootTests {
    @Test func everyDataLocationSitsUnderTheOneRoot() {
        let root = DataRoot.support.path
        for url in [
            DataRoot.machines, DataRoot.clipboard, DataRoot.siteAudit, DataRoot.settingsExport,
            DataRoot.music, DataRoot.usage,
        ] {
            #expect(url.path.hasPrefix(root), "\(url.path) escapes the data root")
        }
    }

    @Test func cachesAndLogsSitOutsideTheDataRoot() {
        #expect(!DataRoot.caches.path.hasPrefix(DataRoot.support.path))
        #expect(!DataRoot.logs.path.hasPrefix(DataRoot.support.path))
        #expect(DataRoot.runtime.path.hasPrefix(DataRoot.caches.path))
        #expect(DataRoot.logs.path.hasSuffix("Library/Logs/Edith"))
    }

    @Test func theDevOverrideIsAnEnvironmentVariableRatherThanASetting() {
        #expect(DataRoot.devOverrideVariable == "EDITH_DATA_ROOT")
        #expect(!ConfigCatalog.keys.contains("repoPath"))
    }

    @Test func logsOlderThanSevenDaysExpire() {
        let now = Date()
        let names = ["today.log", "old.log", "ancient.log"]
        let ages: [String: Date] = [
            "today.log": now.addingTimeInterval(-3600),
            "old.log": now.addingTimeInterval(-6 * 24 * 60 * 60),
            "ancient.log": now.addingTimeInterval(-8 * 24 * 60 * 60),
        ]

        #expect(DataRoot.expiredLogs(in: names, now: now, ages: ages) == ["ancient.log"])
    }
}
