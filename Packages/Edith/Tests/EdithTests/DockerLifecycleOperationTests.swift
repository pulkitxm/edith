import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@Suite struct DockerLifecycleOperationTests {
    @Test func descriptorsCoverEveryLifecycleLeafAndMarkDestructiveOperations() {
        let descriptors = DockerLifecycleOperation.allCases.map(\.descriptor)

        #expect(
            Set(descriptors.map(\.cli))
                == [
                    ["machines", "docker", "start"],
                    ["machines", "docker", "stop"],
                    ["machines", "docker", "restart"],
                    ["machines", "docker", "rm"],
                    ["machines", "docker", "rmi"],
                    ["machines", "docker", "volume-rm"],
                    ["machines", "docker", "prune"],
                ])
        #expect(descriptors.filter(\.requiresPreview).count == 4)
        #expect(descriptors.filter { $0.effect == .destructive }.count == 4)
        #expect(DockerLifecycleOperation(cliVerb: "volume-rm") == .removeVolume)
        #expect(DockerLifecycleOperation(cliVerb: "pause") == nil)
    }

    @Test func containerOperationsUseOneQuotedCommandAndLifecycleTimeout() async throws {
        var request: (String, TimeInterval)?
        let result = await DockerLifecycleOperationExecution.perform(
            .restart, target: .containers(["api", "worker one"]),
            using: { command, timeout in
                request = (command, timeout)
                return .success("restarted")
            })

        let output = try result.get()
        #expect(request?.0 == "docker restart -t 10 api 'worker one'")
        #expect(request?.1 == 120)
        #expect(output.operation == .restart)
        #expect(output.target == .containers(["api", "worker one"]))
        #expect(output.output == "restarted")
    }

    @Test func objectRemovalCommandsPreserveForceAndNames() throws {
        let image = try DockerLifecycleOperationExecution.command(
            .removeImage, target: .image("team/api:latest", force: true))
        let volume = try DockerLifecycleOperationExecution.command(
            .removeVolume, target: .volume("database data"))

        #expect(image.command == "docker image rm -f team/api:latest")
        #expect(image.timeout == 120)
        #expect(volume.command == "docker volume rm 'database data'")
        #expect(volume.timeout == 120)
    }

    @Test func pruneUsesTypedTargetsAndLongTimeout() throws {
        for target in DockerPruneTarget.allCases {
            let request = try DockerLifecycleOperationExecution.command(
                .prune, target: .prune(target))
            #expect(request.command == DockerCommands.prune(target.rawValue))
            #expect(request.timeout == 300)
        }
    }

    @Test func invalidRequestsFailBeforeRunningAnything() async {
        var ran = false
        let empty = await DockerLifecycleOperationExecution.perform(
            .start, target: .containers([]),
            using: { _, _ in
                ran = true
                return .success("")
            })
        let mismatch = await DockerLifecycleOperationExecution.perform(
            .removeVolume, target: .image("api", force: false),
            using: { _, _ in
                ran = true
                return .success("")
            })

        #expect(!ran)
        if case let .failure(error) = empty {
            #expect(error as? DockerLifecycleOperationError == .missingContainer)
        } else {
            Issue.record("an empty container request succeeded")
        }
        if case let .failure(error) = mismatch {
            #expect(
                error as? DockerLifecycleOperationError
                    == .invalidTarget(.removeVolume, .image("api", force: false)))
        } else {
            Issue.record("a mismatched lifecycle target succeeded")
        }
    }

    @Test func runnerFailuresPassThroughWithoutChangingTheirIdentity() async {
        let failure = DockerLifecycleTestError.refused
        let result = await DockerLifecycleOperationExecution.perform(
            .stop, target: .containers(["api"]), using: { _, _ in .failure(failure) })

        if case let .failure(error) = result {
            #expect(error as? DockerLifecycleTestError == failure)
        } else {
            Issue.record("a failed runner succeeded")
        }
    }

    @Test func destructiveUIPlansCarryTypedTargetsAndExplicitWarnings() {
        let image = DockerObjectRemovalPlan.image("team/api:latest")
        let volume = DockerObjectRemovalPlan.volume("database")
        let prune = PrunePlan(kind: .volumes)

        #expect(image.operation == .removeImage)
        #expect(image.target == .image("team/api:latest", force: false))
        #expect(image.title.contains("Remove"))
        #expect(volume.operation == .removeVolume)
        #expect(volume.target == .volume("database"))
        #expect(volume.detail.contains("cannot be undone"))
        #expect(prune.id == "volumes")
        #expect(prune.detail.contains("cannot be undone"))
    }
}

private enum DockerLifecycleTestError: Error, Equatable {
    case refused
}
