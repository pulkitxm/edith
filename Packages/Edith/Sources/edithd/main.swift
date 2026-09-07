import EdithAgent
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let services = AgentBoot.start()
var shutdownTask: Task<Void, Never>?
let shutdownSignals = [SIGTERM, SIGINT].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        guard shutdownTask == nil else { return }
        alarm(10)
        shutdownTask = Task {
            await services.stop()
            exit(0)
        }
    }
    source.resume()
    return source
}
withExtendedLifetime((services, shutdownSignals)) {
    RunLoop.main.run()
}
