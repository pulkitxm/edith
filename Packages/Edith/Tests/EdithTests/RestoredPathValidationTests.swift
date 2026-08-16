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
        "repoPath", "repoPathExternalConfirmation", Repo.musicFolderPathKey,
        "musicFolderExternalConfirmation", Repo.musicFolderStaleKey,
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
            .appendingPathComponent("edith-test-\(UUID().uuidString)").path
    }

    private var externalPath: String {
        "/Volumes/EdithTest-\(UUID().uuidString)/repo"
    }

    @Test func devRootIsNilWhenUnset() {
        withCleanRepoKeys {
            #expect(Repo.devRoot == nil)
        }
    }

    @Test func setDevRootPathKeepsHomePathWithoutConfirmation() {
        withCleanRepoKeys {
            let path = homePath
            Repo.setDevRootPath(path)
            #expect(Repo.devRoot == URL(fileURLWithPath: path).standardizedFileURL)
            #expect(SharedDefaults.store.string(forKey: "repoPathExternalConfirmation") == nil)
        }
    }

    @Test func setDevRootPathConfirmsExternalPath() {
        withCleanRepoKeys {
            let path = externalPath
            Repo.setDevRootPath(path)
            #expect(Repo.devRoot == URL(fileURLWithPath: path).standardizedFileURL)
            #expect(SharedDefaults.store.string(forKey: "repoPathExternalConfirmation") == path)
        }
    }

    @Test func setDevRootPathNilClearsPathAndConfirmation() {
        withCleanRepoKeys {
            Repo.setDevRootPath(externalPath)
            Repo.setDevRootPath(nil)
            #expect(Repo.devRoot == nil)
            #expect(SharedDefaults.store.string(forKey: "repoPath") == nil)
            #expect(SharedDefaults.store.string(forKey: "repoPathExternalConfirmation") == nil)
        }
    }

    @Test func unconfirmedExternalDevRootIsHidden() {
        withCleanRepoKeys {
            SharedDefaults.store.set(externalPath, forKey: "repoPath")
            #expect(Repo.devRoot == nil)
        }
    }

    @Test func staleConfirmationDoesNotCoverDifferentPath() {
        withCleanRepoKeys {
            SharedDefaults.store.set(externalPath, forKey: "repoPath")
            SharedDefaults.store.set(
                "/Volumes/Other/repo", forKey: "repoPathExternalConfirmation")
            #expect(Repo.devRoot == nil)
        }
    }

    @Test func prepareDropsUnconfirmedExternalRepoPathAndMarksMusicStale() {
        withCleanRepoKeys {
            SharedDefaults.store.set(externalPath, forKey: "repoPath")
            Repo.prepareStoredPaths()
            #expect(SharedDefaults.store.string(forKey: "repoPath") == nil)
            #expect(SharedDefaults.store.bool(forKey: Repo.musicFolderStaleKey))
        }
    }

    @Test func prepareKeepsConfirmedExternalRepoPath() {
        withCleanRepoKeys {
            let path = externalPath
            Repo.setDevRootPath(path)
            Repo.prepareStoredPaths()
            #expect(Repo.devRoot == URL(fileURLWithPath: path).standardizedFileURL)
            #expect(!SharedDefaults.store.bool(forKey: Repo.musicFolderStaleKey))
        }
    }

    @Test func prepareKeepsHomeRepoPathWithoutStale() {
        withCleanRepoKeys {
            let path = homePath
            Repo.setDevRootPath(path)
            Repo.prepareStoredPaths()
            #expect(Repo.devRoot == URL(fileURLWithPath: path).standardizedFileURL)
            #expect(!SharedDefaults.store.bool(forKey: Repo.musicFolderStaleKey))
        }
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

    @Test func unconfirmedExternalMusicPathFallsBackToSupportDir() {
        withCleanRepoKeys {
            SharedDefaults.store.set(externalPath, forKey: Repo.musicFolderPathKey)
            #expect(Repo.musicDir == AppData.supportDir.appendingPathComponent("music"))
        }
    }

    @Test func musicDirFallsBackToDevRootLocalMusic() {
        withCleanRepoKeys {
            let path = homePath
            Repo.setDevRootPath(path)
            let expected = URL(fileURLWithPath: path).standardizedFileURL
                .appendingPathComponent("local/music")
            #expect(Repo.musicDir == expected)
        }
    }
}
