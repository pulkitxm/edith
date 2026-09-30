import Foundation
import Testing
import EdithKit
@testable import Edith
@testable import EdithCLI

@Suite struct StudioEditLifecycleCLITests {
    @Test func libraryCommandsPreserveExternalProjectAndReportStaleReferences() async throws {
        try await CLIProbe.inWorld { world in
            let url = world.sandbox.appendingPathComponent("sample.openscreen")
            _ = try VideoEditorService.create(at: url, title: "Synthetic sample")
            let original = try Data(contentsOf: url)
            let registered = await CLIProbe.capture([
                "studio", "edit", "register", url.path, "--json",
            ])
            #expect(registered.code == 0)
            #expect(registered.stdout.contains("\"registered\" : true"))
            #expect(
                VideoProject.listProjects().contains {
                    $0.url.path == url.resolvingSymlinksInPath().path
                })
            let listed = await CLIProbe.capture(["studio", "edit", "library", "--json"])
            #expect(listed.code == 0)
            #expect(listed.stdout.contains("Synthetic sample"))
            #expect(try Data(contentsOf: url) == original)
            try FileManager.default.removeItem(at: url)
            let stale = await CLIProbe.capture(["studio", "edit", "library", "--json"])
            #expect(stale.stdout.contains("project_unavailable"))
            let removed = await CLIProbe.capture([
                "studio", "edit", "unregister", url.path, "--json",
            ])
            #expect(removed.code == 0)
        }
    }

    @Test func openCorrelatesRequestPathIdentityAndRevision() async throws {
        try await CLIProbe.inWorld { world in
            let url = world.sandbox.appendingPathComponent("sample.openscreen")
            _ = try VideoEditorService.create(at: url, title: "Synthetic sample")
            CLIEnvironment.isMainAppRunning = { true }
            CLIEnvironment.answer = { name in
                guard name == IPC.Name.videoEditorOpenResult,
                    var payload = world.posted.last?.info
                else { return nil }
                payload.removeValue(forKey: "deadline")
                payload["ok"] = true
                payload["state"] = "opened"
                return payload
            }
            let opened = await CLIProbe.capture(["studio", "edit", "open", url.path, "--json"])
            #expect(opened.code == 0)
            #expect(opened.stdout.contains("\"state\" : \"opened\""))
            #expect(world.posted.last?.name == IPC.Name.requestVideoEditorOpen)
            for key in ["requestID", "path", "projectID", "revision"] {
                CLIEnvironment.answer = { _ in
                    var payload = world.posted.last?.info ?? [:]
                    payload[key] = "unrelated"
                    payload["ok"] = true
                    payload["state"] = "opened"
                    return payload
                }
                let failed = await CLIProbe.capture(["studio", "edit", "open", url.path, "--json"])
                #expect(failed.code != 0)
                #expect(failed.stderr.contains("open_timeout"))
                #expect(failed.stdout.isEmpty)
            }
            CLIEnvironment.answer = { _ in
                var payload = world.posted.last?.info ?? [:]
                payload["ok"] = true
                payload["state"] = "queued"
                return payload
            }
            let queued = await CLIProbe.capture(["studio", "edit", "open", url.path, "--json"])
            #expect(queued.code != 0)
            #expect(queued.stderr.contains("open_failed"))
            CLIEnvironment.isMainAppRunning = { false }
            let unavailable = await CLIProbe.capture(["studio", "edit", "open", url.path, "--json"])
            #expect(unavailable.stderr.contains("app_not_running"))
        }
    }

    @Test func lifecycleOperationsAreDiscoverable() async {
        for name in ["register", "unregister", "library", "open"] {
            let help = await CLIProbe.run(["studio", "edit", name, "--help"])
            #expect(help.code == 0)
            #expect(help.stdout.contains("--json"))
            #expect(StudioEditOperation.allCases.contains { $0.rawValue == name })
        }
        #expect(StudioEditOperation.open.descriptor.effect == .interactive)
        #expect(StudioEditOperation.library.descriptor.effect == .read)
    }
}
