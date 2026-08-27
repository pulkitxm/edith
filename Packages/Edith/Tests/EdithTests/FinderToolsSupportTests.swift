import Foundation
import Testing

@testable import EdithKit

@Suite struct FinderToolsSupportTests {
    @Test func choosesLosslessPasteboardImages() {
        #expect(
            FinderToolsSupport.preferredImageType(
                in: ["public.tiff", "public.png", "public.utf8-plain-text"])
                == .png)
        #expect(FinderToolsSupport.preferredImageType(in: ["public.tiff"]) == .tiff)
        #expect(FinderToolsSupport.preferredImageType(in: ["public.jpeg"]) == nil)
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
    }
}
