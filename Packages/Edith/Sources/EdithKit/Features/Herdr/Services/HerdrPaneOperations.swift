import Foundation

public struct HerdrPaneProcess: Equatable, Sendable {
    public var name: String
    public var command: String
    public var running: Bool

    public init(name: String, command: String, running: Bool) {
        self.name = name
        self.command = command
        self.running = running
    }
}

public enum HerdrPaneState: Equatable, Sendable {
    case live(HerdrPaneProcess?)
    case missing
}

public enum HerdrPaneProcessCommand {
    public static func arguments(session: String, pane: String) -> [String] {
        HerdrSessionCommand.scoped(["pane", "process-info", "--pane", pane], session: session)
    }
}

public enum HerdrPaneCloseCommand {
    public static func arguments(session: String, pane: String) -> [String] {
        HerdrSessionCommand.scoped(["pane", "close", pane], session: session)
    }
}

public enum HerdrPaneOperations {
    private static let timeout: TimeInterval = 10

    public static func state(
        session: String, pane: String, on machine: Machine?
    ) async throws -> HerdrPaneState {
        do {
            let output = try await HerdrCommand.run(
                HerdrPaneProcessCommand.arguments(session: session, pane: pane),
                timeout: timeout, on: machine)
            return .live(HerdrListParser.paneProcess(from: output))
        } catch let error as HerdrCommandError where error.paneMissing {
            return .missing
        }
    }

    public static func close(session: String, pane: String, on machine: Machine?) async throws {
        do {
            _ = try await HerdrCommand.run(
                HerdrPaneCloseCommand.arguments(session: session, pane: pane),
                timeout: timeout, on: machine)
        } catch let error as HerdrCommandError where error.paneMissing {
            return
        }
    }

    public static func waitForShell(
        timeout: Duration, interval: Duration = .milliseconds(250),
        clock: ContinuousClock = ContinuousClock(),
        state: @Sendable () async throws -> HerdrPaneState
    ) async -> Bool {
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let current = try? await state() {
                switch current {
                case .missing:
                    return true
                case .live(nil):
                    try? await Task.sleep(for: min(timeout, .seconds(1)))
                    return true
                case .live(let process?):
                    if !process.running { return true }
                }
            }
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: interval)
        }
        return false
    }
}
