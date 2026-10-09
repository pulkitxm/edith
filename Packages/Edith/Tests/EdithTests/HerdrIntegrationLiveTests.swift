import Darwin
import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite(.serialized) struct HerdrIntegrationLiveTests {
    private static let sessionKey = "EDITH_HERDR_INTEGRATION_SESSION"

    @Test(.enabled(if: ProcessInfo.processInfo.environment[sessionKey] != nil))
    func shellAttachmentInputResizeReattachmentAndScrollingUseTheLiveServer() async throws {
        let session = try #require(ProcessInfo.processInfo.environment[Self.sessionKey])
        try #require(session.hasPrefix("edith-integration-"))
        let created = try await HerdrLaunchOperations.createWorkspace(
            label: "Terminal verification", cwd: "/tmp", session: session, on: nil)
        defer {
            Task {
                try? await HerdrPaneOperations.close(
                    session: session, pane: created.paneID, on: nil)
            }
        }
        let terminalID = try await HerdrPaneOperations.terminalID(
            session: session, pane: created.paneID, on: nil)
        let request = HerdrOperationExecution.localTerminalAttachRequest(
            session: session, terminalID: terminalID, environment: ["TERM=xterm-256color"])
        let geometry = HerdrTerminalDimensions(
            columns: 100, rows: 24, cellWidth: 8, cellHeight: 16)
        let child = try HerdrNativeTerminalProcess(request: request, dimensions: geometry)
        defer { child.close() }
        try await HerdrPaneOperations.run(
            session: session, pane: created.paneID, command: "printf 'ready\\n'", on: nil)
        _ = try read("ready", from: child)
        try child.terminal.write(
            contentsOf: Data("printf '\\123\\110\\105\\114\\114\\137\\117\\113\\n'\r".utf8))
        let output = try read("SHELL_OK", from: child)
        #expect(String(decoding: output, as: UTF8.self).contains("SHELL_OK"))

        try child.resize(
            HerdrTerminalDimensions(columns: 120, rows: 32, cellWidth: 9, cellHeight: 18))
        try await Task.sleep(for: .milliseconds(300))
        let pane = try await HerdrCommand.run(
            HerdrSessionCommand.scoped(["pane", "get", created.paneID], session: session),
            timeout: 5, on: nil)
        #expect(HerdrListParser.scrollInfo(from: pane, pane: created.paneID)?.viewportRows == 32)
        child.close()

        let replacement = try HerdrNativeTerminalProcess(request: request, dimensions: geometry)
        defer { replacement.close() }
        #expect(
            String(decoding: try read("SHELL_OK", from: replacement), as: UTF8.self).contains(
                "SHELL_OK"))
        try await HerdrPaneOperations.run(
            session: session, pane: created.paneID,
            command:
                "for i in {1..80}; do printf 'fixture row %s\\n' $i; done; printf '\\123\\103\\122\\117\\114\\114\\137\\122\\105\\101\\104\\131\\n'",
            on: nil)
        _ = try read("SCROLL_READY", from: replacement)
        let scroll = try await HerdrPaneScrollChannel.open(
            session: session, pane: created.paneID, machine: nil)
        defer { scroll.close() }
        let position = try #require(try await scroll.scroll(to: 10))
        #expect(position.offset == 10)
        #expect(position.maximum >= 10)
        _ = try await scroll.scroll(to: 0)
        replacement.close()
        try await HerdrPaneOperations.close(session: session, pane: created.paneID, on: nil)
        #expect(
            try await HerdrPaneOperations.state(session: session, pane: created.paneID, on: nil)
                == .missing)
    }

    private func read(_ marker: String, from child: HerdrNativeTerminalProcess) throws -> Data {
        var output = Data()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let bytes = try HerdrTerminalStream.read(
                from: child.terminal, timeoutMilliseconds: 100)
            {
                if bytes.isEmpty { break }
                output.append(bytes)
                if String(decoding: output, as: UTF8.self).contains(marker) { return output }
            }
        }
        Issue.record("The terminal did not display the expected fixture output: \(marker)")
        return output
    }
}
