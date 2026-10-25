import Foundation
import Testing

@testable import EdithHostCore

@MainActor @Suite struct HostRemoteTaskRetirementTests {
    @Test func lateLaunchAndConfigurationRetireBeforeLeaseCanClose() async throws {
        var launchWaiter: CheckedContinuation<Void, Never>?
        var configurationWaiter: CheckedContinuation<Void, Never>?
        var born = false
        var invalidated = false
        var configured = false
        var closed = false
        let launch = Task {
            await withCheckedContinuation { launchWaiter = $0 }
            born = true
            return 7
        }
        let configuration = Task {
            _ = await launch.value
            await withCheckedContinuation { configurationWaiter = $0 }
            configured = true
        }
        while launchWaiter == nil { await Task.yield() }
        let stop = Task {
            await HostRemoteTaskRetirement.cancelAndJoin(
                cancel: {
                    launch.cancel(); configuration.cancel()
                },
                joinLaunch: {
                    _ = await launch.value; invalidated = true
                },
                joinConfiguration: { await configuration.value })
            closed = true
        }
        await Task.yield()
        #expect(!closed)
        #expect(!born)
        launchWaiter?.resume()
        while configurationWaiter == nil { await Task.yield() }
        #expect(born)
        #expect(!closed)
        configurationWaiter?.resume()
        await stop.value
        #expect(invalidated)
        #expect(configured)
        #expect(closed)
    }
}
