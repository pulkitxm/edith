import Foundation
import Testing

@testable import EdithKit

@Suite struct DockerProjectOrderTests {
    @Test func edithsOwnStackSortsAboveEverythingElse() {
        let projects = ["orbit", "edith-companion", "crowdvolt", "noveum-local-db"]
        #expect(
            projects.sorted(by: DockerProjectOrder.before)
                == ["edith-companion", "crowdvolt", "noveum-local-db", "orbit"])
    }

    @Test func everythingElseKeepsItsNaturalOrder() {
        let projects = ["orbit", "crowdvolt", "alpha"]
        #expect(
            projects.sorted(by: DockerProjectOrder.before) == ["alpha", "crowdvolt", "orbit"])
    }

    @Test func theCompanionProjectIsNamedForWhatItIs() {
        #expect(DockerProjectOrder.title("edith-companion") == "Companion")
        #expect(DockerProjectOrder.title("orbit") == "orbit")
        #expect(DockerProjectOrder.title(nil) == "Standalone")
    }

    @Test func theCompanionCarriesItsOwnSymbol() {
        #expect(DockerProjectOrder.symbol("edith-companion") == "brain.head.profile")
        #expect(DockerProjectOrder.symbol("orbit") == "square.stack")
        #expect(DockerProjectOrder.symbol(nil) == "cube")
    }

    @Test func onlyTheRealProjectNameCounts() {
        #expect(DockerProjectOrder.isCompanion("edith-companion"))
        #expect(!DockerProjectOrder.isCompanion("edith-companion-old"))
        #expect(!DockerProjectOrder.isCompanion(nil))
        #expect(DockerProjectOrder.companionProject == CompanionDeployment.projectName)
    }
}
