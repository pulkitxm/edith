import EdithExtensionSupport
import EdithHostCore
import Foundation
import Testing
@testable import HostLifecycleHarness

@MainActor @Suite struct SurfaceActionRejectionTests {
    @Test func actualRemoteRejectionPasses() async throws {
        var invoked = false
        try await SurfaceActionRejection.require {
            invoked = true
            throw ExtensionPeerError.rejected("The synthetic action is invalid.")
        }
        #expect(invoked)
    }

    @Test(arguments: ["unavailable", "timeout", "cancelled", "invalid-response", "success"])
    func transportCancellationAndSuccessNeverCountAsRemoteRejection(mode: String) async {
        var failureKind: String?
        do {
            try await SurfaceActionRejection.require {
                switch mode {
                case "unavailable": throw ExtensionPeerError.unavailable
                case "timeout": throw ExtensionPeerError.timedOut
                case "cancelled": throw CancellationError()
                case "invalid-response": throw HostWorkerError.invalidResponse
                default: return Data("{}".utf8)
                }
            }
        } catch let error as ExtensionPeerError {
            switch error {
            case .unavailable: failureKind = "unavailable"
            case .timedOut: failureKind = "timeout"
            default: failureKind = "changed"
            }
        } catch is CancellationError {
            failureKind = "cancelled"
        } catch HostWorkerError.invalidResponse {
            failureKind = "invalid-response"
        } catch {
            failureKind = "changed"
        }
        #expect(failureKind == (mode == "success" ? "invalid-response" : mode))
    }
}
