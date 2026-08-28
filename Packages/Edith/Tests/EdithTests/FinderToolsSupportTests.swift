import Foundation
import Testing

@testable import EdithKit

@Suite struct FinderToolsSupportTests {
    @Test func choosesLosslessPasteboardImages() {
        #expect(
            FinderToolsSupport.preferredImageType(
                in: ["public.tiff", "public.png", "public.utf8-plain-text"])
                == .png)
        #expect(
            FinderToolsSupport.preferredImageType(in: ["public.tiff"])
                == .image("public.tiff"))
        #expect(
            FinderToolsSupport.preferredImageType(in: ["public.jpeg"])
                == .image("public.jpeg"))
        #expect(
            FinderToolsSupport.preferredImageType(in: ["public.file-url", "public.png"])
                == nil)
    }

    @Test func renameRequiresAFileCollectionAndEditingDetectionIsIndependent() {
        for role in ["AXBrowser", "AXGrid", "AXList", "AXOutline", "AXTable"] {
            #expect(FinderToolsSupport.focusedRoleAllowsRename(role))
        }
        for role in ["AXButton", "AXDialog", "AXGroup", "AXScrollArea", "AXTextField"] {
            #expect(!FinderToolsSupport.focusedRoleAllowsRename(role))
        }
        #expect(!FinderToolsSupport.focusedRoleAllowsRename("AXTextField"))
        #expect(!FinderToolsSupport.focusedRoleAllowsRename(nil))
        #expect(FinderToolsSupport.focusedRoleIsEditable("AXTextField"))
        #expect(FinderToolsSupport.focusedRoleIsEditable("AXTextArea"))
        #expect(FinderToolsSupport.focusedRoleIsEditable("AXComboBox"))
        #expect(FinderToolsSupport.focusedRoleIsEditable("AXSecureTextField"))
        #expect(!FinderToolsSupport.focusedRoleIsEditable("AXOutline"))
        #expect(!FinderToolsSupport.focusedRoleIsEditable(nil))
    }

    @Test func imageDimensionsBoundDecodedMemory() {
        #expect(FinderToolsSupport.imageDimensionsAreSafe(width: 7_680, height: 4_320))
        #expect(!FinderToolsSupport.imageDimensionsAreSafe(width: 16_385, height: 1))
        #expect(!FinderToolsSupport.imageDimensionsAreSafe(width: 10_000, height: 10_000))
        #expect(!FinderToolsSupport.imageDimensionsAreSafe(width: 0, height: 100))
        #expect(!FinderToolsSupport.imageDimensionsAreSafe(width: 100, height: -1))
        #expect(
            FinderToolsSupport.imageDimensionsAreSafe(
                width: 20, height: 20, maxDimension: 20, maxPixels: 400))
    }

    @Test func parsesOnlyValidCodeSignatureFingerprints() {
        let hash = "0123456789abcdef0123456789abcdef01234567"
        #expect(
            FinderToolsSupport.codeSignatureFingerprint(
                in: "Identifier=com.example.App\nCDHash=\(hash.uppercased())\nTeamIdentifier=ABCDE")
                == hash)
        #expect(
            FinderToolsSupport.codeSignatureFingerprint(in: "Identifier=com.example.App") == nil)
        #expect(FinderToolsSupport.codeSignatureFingerprint(in: "CDHash=1234") == nil)
        #expect(
            FinderToolsSupport.codeSignatureFingerprint(
                in: "CDHash=0123456789abcdef0123456789abcdef0123456z") == nil)
    }

    @Test func createsStableUniqueImageNames() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_704_067_200)
        let name = FinderToolsSupport.imageFileName(at: date, calendar: calendar)
        #expect(name == "Pasted Image 2024-01-01 at 00.00.00.png")
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let existing = Set([
            "/tmp/Pasted Image 2024-01-01 at 00.00.00.png",
            "/tmp/Pasted Image 2024-01-01 at 00.00.00 2.png",
        ])
        let destination = FinderToolsSupport.uniqueImageURL(named: name, in: directory) {
            existing.contains($0)
        }
        #expect(destination.lastPathComponent == "Pasted Image 2024-01-01 at 00.00.00 3.png")
    }

    @Test func moveDestinationsRejectOverwriteAndRecursion() {
        let source = URL(fileURLWithPath: "/tmp/source", isDirectory: true)
        let target = URL(fileURLWithPath: "/tmp/target", isDirectory: true)
        #expect(
            FinderToolsSupport.moveDestination(for: source, in: target, fileExists: { _ in false })
                == URL(fileURLWithPath: "/tmp/target/source"))
        #expect(
            FinderToolsSupport.moveDestination(for: source, in: target, fileExists: { _ in true })
                == nil)
        #expect(
            FinderToolsSupport.moveDestination(
                for: source,
                in: URL(fileURLWithPath: "/tmp/source/child", isDirectory: true),
                fileExists: { _ in false }) == nil)
    }

    @Test func fileMovesCompleteOrRollBackInReverseOrder() {
        struct MoveFailure: Error {}
        let first = (
            source: URL(fileURLWithPath: "/source/a"),
            destination: URL(fileURLWithPath: "/target/a")
        )
        let second = (
            source: URL(fileURLWithPath: "/source/b"),
            destination: URL(fileURLWithPath: "/target/b")
        )
        var operations: [String] = []
        let outcome = FinderToolsSupport.move([first, second]) { source, destination in
            operations.append("\(source.path)->\(destination.path)")
            if source == second.source { throw MoveFailure() }
        }
        #expect(outcome == .reverted)
        #expect(
            operations == [
                "/source/a->/target/a", "/source/b->/target/b", "/target/a->/source/a",
            ])

        operations = []
        let completed = FinderToolsSupport.move([first, second]) { source, destination in
            operations.append("\(source.path)->\(destination.path)")
        }
        #expect(completed == .completed)
        #expect(operations.count == 2)
    }

    @Test func fileMovesReportAnIncompleteRollback() {
        struct MoveFailure: Error {}
        let first = (
            source: URL(fileURLWithPath: "/source/a"),
            destination: URL(fileURLWithPath: "/target/a")
        )
        let second = (
            source: URL(fileURLWithPath: "/source/b"),
            destination: URL(fileURLWithPath: "/target/b")
        )
        let outcome = FinderToolsSupport.move([first, second]) { source, _ in
            if source == second.source || source == first.destination { throw MoveFailure() }
        }
        #expect(outcome == .incomplete)
    }

    @Test func mapsOnlyOneRealDiskImageToTheMount() throws {
        let root: [String: Any] = [
            "images": [
                [
                    "image-path": "/Users/me/Downloads/App.dmg",
                    "system-entities": [["mount-point": "/Volumes/App"]],
                ]
            ]
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: root, format: .xml, options: 0)
        #expect(
            FinderToolsSupport.diskImageURL(
                mountedAt: URL(fileURLWithPath: "/Volumes/App"), hdiutilInfo: data)?.path
                == "/Users/me/Downloads/App.dmg")
        #expect(
            FinderToolsSupport.diskImageURL(
                mountedAt: URL(fileURLWithPath: "/Volumes/Other"), hdiutilInfo: data) == nil)

        let ambiguous = try PropertyListSerialization.data(
            fromPropertyList: [
                "images": [
                    [
                        "image-path": "/Users/me/Downloads/App.dmg",
                        "system-entities": [["mount-point": "/Volumes/App"]],
                    ],
                    [
                        "image-path": "/Users/me/Downloads/Other.dmg",
                        "system-entities": [["mount-point": "/Volumes/App"]],
                    ],
                ]
            ], format: .xml, options: 0)
        #expect(
            FinderToolsSupport.diskImageURL(
                mountedAt: URL(fileURLWithPath: "/Volumes/App"), hdiutilInfo: ambiguous) == nil)
    }

    @Test func applicationDestinationsStayInsideApplications() {
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        #expect(
            FinderToolsSupport.applicationDestination(
                for: URL(fileURLWithPath: "/Volumes/App/Example.app"),
                applicationsDirectory: applications)?.path == "/Applications/Example.app")
        #expect(
            FinderToolsSupport.applicationDestination(
                for: URL(fileURLWithPath: "/Volumes/App/.Hidden.app"),
                applicationsDirectory: applications) == nil)
        #expect(
            FinderToolsSupport.displayName(
                preferred: "  Example\n  App  ",
                application: URL(fileURLWithPath: "/Volumes/App/Fallback.app")) == "Example App")
    }
}
