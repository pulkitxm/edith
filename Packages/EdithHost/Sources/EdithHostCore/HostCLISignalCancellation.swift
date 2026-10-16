import Darwin
import Foundation

final class HostCLISignalCancellation {
    private var sources: [DispatchSourceSignal] = []
    init(task: Task<Void, Never>) {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            _ = signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { task.cancel() }
            sources.append(source)
            source.resume()
        }
    }
    deinit { for source in sources { source.cancel() } }
}
