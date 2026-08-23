import Foundation
import Testing

@testable import EdithKit

@Suite struct AppInspectionOperationTests {
    @Test func descriptorsAreUniqueRegisteredAndSafe() {
        let descriptors = AppInspectionOperation.allCases.map(\.descriptor)

        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(Set(descriptors.map(\.cli)).count == descriptors.count)
        #expect(descriptors.allSatisfy { UserOperationCatalog.descriptor(id: $0.id) == $0 })
        #expect(descriptors.allSatisfy { !$0.requiresPreview })
        #expect(descriptors.allSatisfy { $0.effect != .destructive })
    }

    @Test func infoCarriesStableIdentityAndLinks() {
        let info = AppInspectionCenter().info()

        #expect(!info.name.isEmpty)
        #expect(!info.version.isEmpty)
        #expect(!info.build.isEmpty)
        #expect(info.repositoryURL.absoluteString == "https://github.com/pulkitxm/edith")
        #expect(info.creatorURL.absoluteString == "https://pulkit.page")
    }

    @Test func diagnosticsUseInjectedClockAndEnergyProbe() {
        let center = AppInspectionCenter(idleWakeups: { 17 })
        let launched = Date(timeIntervalSince1970: 100)

        let snapshot = center.diagnostics(
            launchedAt: launched, now: Date(timeIntervalSince1970: 7_400), processID: 42)

        #expect(snapshot.processID == 42)
        #expect(snapshot.uptimeSeconds == 7_300)
        #expect(snapshot.uptimeText == "2h 1m")
        #expect(snapshot.idleWakeups == 17)
    }

    @Test func pathsUseTheDirectoriesTheUIExposes() {
        let paths = AppInspectionCenter(exists: { $0 == Repo.musicDir }).paths()

        #expect(paths.map(\.id) == AppPathID.allCases)
        #expect(paths.first { $0.id == .appData }?.url == AppData.supportDir)
        #expect(paths.first { $0.id == .icloud }?.url == AppData.cloudDir)
        #expect(paths.first { $0.id == .data }?.url == Repo.dataDir)
        #expect(paths.first { $0.id == .music }?.exists == true)
    }

    @Test func linksIncludeFixedDestinationsExtensionDocsAndContributors() throws {
        let contributor = Contributor(
            id: 1, login: "octo", avatarURL: URL(string: "https://example.com/avatar")!,
            profileURL: URL(string: "https://example.com/octo")!, contributions: 2)

        let links = AppInspectionCenter().links(contributors: [contributor])
        let usageDoc = try #require(
            links.first { $0.id == "extension-doc:usage:guide" })

        #expect(Array(links.prefix(2).map(\.id)) == ["repository", "creator"])
        #expect(
            usageDoc.url.absoluteString
                == "https://github.com/pulkitxm/edith/blob/main/docs/cli/usage/README.md")
        #expect(links.last?.url == contributor.profileURL)
    }

    @Test func openingAPathUsesTheResolvedExactTarget() throws {
        final class Capture {
            var opened: [URL] = []
        }
        let capture = Capture()
        let center = AppInspectionCenter(open: {
            capture.opened.append($0)
            return true
        })

        let result = try center.openPath(.appData)

        #expect(result.id == "app-data")
        #expect(result.url == AppData.supportDir)
        #expect(result.mode == .open)
        #expect(capture.opened == [AppData.supportDir])
    }

    @Test func refreshLogRevealsAFileAndFallsBackToItsFolder() throws {
        final class Capture {
            var opened: [URL] = []
            var revealed: [[URL]] = []
        }
        let log = Repo.dataDir.appendingPathComponent("refresh.log")
        let present = Capture()
        let revealCenter = AppInspectionCenter(
            exists: { $0 == log },
            open: {
                present.opened.append($0)
                return true
            },
            reveal: { present.revealed.append($0) })

        let revealed = try revealCenter.openPath(.refreshLog)

        #expect(revealed.mode == .reveal)
        #expect(present.revealed == [[log]])
        #expect(present.opened.isEmpty)

        let missing = Capture()
        let openCenter = AppInspectionCenter(
            exists: { _ in false },
            open: {
                missing.opened.append($0)
                return true
            })

        let opened = try openCenter.openPath(.refreshLog)

        #expect(opened.url == Repo.dataDir)
        #expect(opened.mode == .open)
        #expect(missing.opened == [Repo.dataDir])
    }

    @Test func missingUICreatedFoldersAreCreatedBeforeOpening() throws {
        final class Capture {
            var created: [URL] = []
            var opened: [URL] = []
        }
        let capture = Capture()
        let center = AppInspectionCenter(
            exists: { _ in false }, createDirectory: { capture.created.append($0) },
            open: {
                capture.opened.append($0)
                return true
            })

        _ = try center.openPath(.icloud)
        _ = try center.openPath(.music)

        #expect(capture.created == [AppData.cloudDir, Repo.musicDir])
        #expect(capture.opened == [AppData.cloudDir, Repo.musicDir])
    }

    @Test func openingLinksIsTypedAndReportsFailures() throws {
        final class Capture {
            var opened: [URL] = []
        }
        let capture = Capture()
        let center = AppInspectionCenter(open: {
            capture.opened.append($0)
            return true
        })

        let result = try center.openLink("repository", contributors: [])

        #expect(result.url == AppInspectionCenter.repositoryURL)
        #expect(capture.opened == [AppInspectionCenter.repositoryURL])
        let documentation = try center.openLink(
            "extension-doc:usage:guide", contributors: [])
        #expect(
            documentation.url.absoluteString
                == "https://github.com/pulkitxm/edith/blob/main/docs/cli/usage/README.md")
        #expect(throws: AppInspectionError.unknownLink("missing")) {
            try center.openLink("missing", contributors: [])
        }
    }

    @Test func diagnosticPayloadRoundTrips() throws {
        let snapshot = AppDiagnosticsSnapshot(
            info: AppInfoSnapshot(
                name: "Edith", version: "1.2", build: "34", bundleID: "com.pulkit.edith",
                bundlePath: "/Applications/Edith.app",
                repositoryURL: AppInspectionCenter.repositoryURL,
                creatorURL: AppInspectionCenter.creatorURL),
            processID: 9, uptimeSeconds: 120, idleWakeups: 7)

        let decoded = try #require(
            AppDiagnosticsPayload.decode(AppDiagnosticsPayload.encode(snapshot)))

        #expect(decoded == snapshot)
    }
}
