import EdithKit
import Foundation
import Testing

@testable import Edith

@Suite struct MachineExtensionSkeletonLoadingTests {
    @Test func auditedFeaturesContainNoIndeterminateProgressViews() throws {
        let roots = ["Machines", "Quinjet", "Herdr", "Extensions", "SEOAudit"]
        var violations: [String] = []

        for root in roots {
            let directory = featuresRoot.appendingPathComponent(root)
            for source in try swiftSources(in: directory) {
                let text = try String(contentsOf: source, encoding: .utf8)
                for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                    .enumerated()
                where line.contains("ProgressView(") && !line.contains("value:") {
                    violations.append(
                        "\(source.lastPathComponent):\(offset + 1)"
                    )
                }
            }
        }

        #expect(violations.isEmpty)
    }

    @Test func auditedLoadingSurfacesUseDedicatedGeometry() throws {
        let expectations: [String: [String]] = [
            "Machines/ViewModels/DockerDetailModel.swift": [
                "DockerInspectSkeleton", "DockerProcessRowsSkeleton", "DockerFileRowsSkeleton",
            ],
            "Machines/ViewModels/FilePreviewModel.swift": ["FilePreviewLoadingSkeleton"],
            "Machines/Views/DockerConsoleViews.swift": ["DockerContainerRowsSkeleton"],
            "Machines/Views/MachineProcessesTab.swift": ["MachineProcessRowsSkeleton"],
            "Machines/Views/MachineOverviewTab.swift": ["NetworkSpeedLoadingSkeleton"],
            "Machines/Views/MachineSkeletons.swift": [
                "MetricsGridLayout", "NetworkMetricCardSkeleton",
            ],
            "Machines/Views/MachineTerminalTab.swift": ["TerminalLoadingSkeleton"],
            "Quinjet/Views/QuinjetMachineProjectPicker.swift": [
                "QuinjetPreparingMachineSkeleton", "QuinjetProjectGridSkeleton",
                "QuinjetFolderBrowserSkeleton",
            ],
            "Herdr/Views/HerdrPage.swift": ["HerdrBoardSkeleton"],
            "Herdr/Views/HerdrSessionView.swift": [
                "HerdrAgentTerminalSkeleton", "TerminalLoadingSkeleton",
            ],
            "Extensions/Views/ToolProvisioningViews.swift": ["SkeletonBlock"],
            "SEOAudit/Views/SEOAuditProjectView.swift": ["SEOAuditPageRowsSkeleton"],
            "SEOAudit/Views/SEOAuditPageAccordion.swift": ["SEOAuditScoreTilesSkeleton"],
        ]

        for (path, names) in expectations {
            let source = try String(
                contentsOf: featuresRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            for name in names {
                #expect(source.contains(name), "Missing \(name) in \(path)")
            }
        }
    }

    @Test func everyVisibleHerdrAgentFlavorHasDedicatedTerminalGeometry() {
        let flavors = HerdrKind.filterLabels.map(HerdrAgentTerminalSkeletonFlavor.init(kind:))

        #expect(!flavors.contains(.generic))
        #expect(Set(flavors.map(\.rawValue)).count == HerdrKind.filterLabels.count)
    }

    @Test func networkRetestsKeepTheLastMeasurementVisible() throws {
        let source = try String(
            contentsOf: featuresRoot.appendingPathComponent(
                "Machines/Views/MachineOverviewTab.swift"),
            encoding: .utf8
        )

        #expect(source.contains("if isTesting, measurement == nil"))
        #expect(source.contains("NetworkSpeedLoadingSkeleton()"))
    }

    @Test @MainActor func dockerProcessFailureEndsTheLoadingState() async {
        let model = DockerDetailModel()
        let session = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        let container = DockerContainer(
            id: "api", names: ["api"], image: "api", command: "", state: .running,
            status: "Up"
        )

        model.startLogs(session: session, container: container)
        await model.loadProcesses(container: container) { _, _ in .success("invalid") }

        #expect(model.processesLoaded)
        #expect(!model.processesLoading)
        #expect(model.processesFailed)
        model.stop()
    }

    private var featuresRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Edith/Features")
    }

    private func swiftSources(in directory: URL) throws -> [URL] {
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]))
        return enumerator.compactMap { value in
            guard let url = value as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }
}
