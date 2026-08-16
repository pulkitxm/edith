import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@Suite struct CompanionSetupFlowTests {
    private func deployment() -> CompanionDeployment {
        CompanionDeployment(machineID: UUID(), machineName: "box", tier: "cpu", localPort: 4820)
    }

    @Test func aFreshMachineStartsAtTheBeginning() async {
        await MainActor.run {
            #expect(
                CompanionSetupModel.initialStep(
                    deployment: nil, reachable: false, reasonerConfigured: false) == .welcome)
        }
    }

    @Test func aDeployedButUnreachableStackResumesAtDeploy() async {
        await MainActor.run {
            #expect(
                CompanionSetupModel.initialStep(
                    deployment: deployment(), reachable: false, reasonerConfigured: true)
                    == .deploy)
        }
    }

    @Test func aHealthyStackWithoutAReasonerResumesAtIntelligence() async {
        await MainActor.run {
            #expect(
                CompanionSetupModel.initialStep(
                    deployment: deployment(), reachable: true, reasonerConfigured: false)
                    == .intelligence)
        }
    }

    @Test func aFullySetUpCompanionLandsOnDone() async {
        await MainActor.run {
            #expect(
                CompanionSetupModel.initialStep(
                    deployment: deployment(), reachable: true, reasonerConfigured: true)
                    == .done)
        }
    }

    @Test func everyStageHasATitleForTheChecklist() {
        for stage in CompanionDeployStage.allCases {
            #expect(!stage.title.isEmpty)
        }
        #expect(CompanionDeployStage.allCases.count == 7)
    }

    @Test func theOptionalStepIsTheIntelligenceOne() {
        for step in CompanionSetupStep.allCases {
            #expect(step.optional == (step == .intelligence))
        }
    }
}
