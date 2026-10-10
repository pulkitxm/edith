import EdithExtensionSupport
import Foundation
import Testing
@testable import HerdrExtension

@Suite(.serialized) struct HerdrCollectorFixtureTests {
    @Test func localCollectionUsesTheResolvedFixtureExecutableForEveryCommand() async throws {
        let home = try #require(ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"])
        let bin = URL(fileURLWithPath: home).appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("herdr")
        let script = """
            #!/usr/bin/python3
            import json,sys
            args=sys.argv[1:]
            if args[:2]==['session','list']: print(json.dumps([{'name':'synthetic-fixture'}]))
            elif 'snapshot' in args: print('{}')
            else: print(json.dumps({'agents':[{'pane_id':'fixture-pane','agent':'opencode','agent_status':'working','title':'Fixture-only agent'}]}))
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: executable) }
        #expect(HerdrCollector.executable() == executable)
        let snapshot = await HerdrCollector.collectLocal()
        #expect(snapshot.herdrPresent && snapshot.reachable && snapshot.agents.count == 1)
        #expect(snapshot.agents.first?.id == "local|synthetic-fixture|fixture-pane")
        #expect(snapshot.agents.first?.title == "Fixture-only agent")
    }
}
