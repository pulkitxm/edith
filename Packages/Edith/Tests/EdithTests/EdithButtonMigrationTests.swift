import Foundation
import Testing

@Suite struct EdithButtonMigrationTests {
    @Test func legacyButtonPathsDoNotReturn() throws {
        for source in try swiftSources() {
            let text = try String(contentsOf: source, encoding: .utf8)
            #expect(!text.contains(".buttonStyle(.plain)"))
            #expect(!text.contains("HoverButtonStyle"))
            #expect(!text.contains(".hoverButton()"))
            #expect(!text.contains(".shelfPointer()"))
            #expect(!text.contains("pointerCursor"))
        }
    }

    @Test func featureButtonStylesDelegateToTheCanonicalTarget() throws {
        let expected = [
            "Edith/Features/Dashboard/Views/FolderScopePicker.swift": 1,
            "Edith/Features/Dashboard/Views/UsageMachinesPicker.swift": 1,
            "Edith/Features/Onboarding/Views/OnboardingView.swift": 1,
            "Edith/Features/Quinjet/Views/QuinjetMachineProjectPicker.swift": 2,
            "Edith/Features/Quinjet/Views/QuinjetProjectPicker.swift": 3,
        ]

        for (path, count) in expected {
            let source = sourcesRoot.appendingPathComponent(path)
            let text = try String(contentsOf: source, encoding: .utf8)
            #expect(occurrences(of: ": ButtonStyle", in: text) == count)
            #expect(occurrences(of: ".edithButtonTarget(", in: text) == count)
        }
    }

    @Test func onlyDirectManipulationGesturesRemain() throws {
        let expected = [
            "Edith/Core/Navigation/MainNavigationView.swift": 1,
            "Edith/Features/Herdr/Views/HerdrPage.swift": 1,
            "Edith/Features/Machines/ViewModels/DockerDetailModel.swift": 1,
            "Edith/Features/Machines/ViewModels/WorkspaceModel.swift": 1,
            "Edith/Features/Machines/ViewModels/WorkspacePaneModel.swift": 1,
            "Edith/Features/Machines/Views/DockerConsoleViews.swift": 1,
            "Edith/Features/Machines/Views/FinderContentViews.swift": 6,
            "Edith/Features/Pages/Views/MusicPageView.swift": 1,
            "Edith/Features/Settings/Views/GeneralPane.swift": 1,
            "EdithHelper/Features/NotchShelf/Views/NotchShelfView.swift": 1,
        ]
        var actual: [String: Int] = [:]

        for source in try swiftSources() {
            let text = try String(contentsOf: source, encoding: .utf8)
            let count = occurrences(of: ".onTapGesture", in: text)
                + occurrences(of: "TapGesture()", in: text)
            if count > 0 {
                actual[relativePath(source)] = count
            }
        }

        #expect(actual == expected)
    }

    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private func swiftSources() throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: sourcesRoot, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]))
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func relativePath(_ url: URL) -> String {
        String(url.path.dropFirst(sourcesRoot.path.count + 1))
    }
}
