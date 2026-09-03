import EdithAgent
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let services = AgentBoot.start()
withExtendedLifetime(services) {
    RunLoop.main.run()
}
