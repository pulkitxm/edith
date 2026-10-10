import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

protocol SystemStatsSampling: Sendable {
    func hello() -> MachineHello
    func sample() async -> MachineSample
    func slow() async -> MachineSlow
}

extension LocalMachineSampler: SystemStatsSampling {}

struct SystemStatsFollowRequest: Codable {
    let session: UUID
    var json = false
    var processes = 0
}

@MainActor final class SystemStatsFollow {
    private final class Session {
        let sampler: any SystemStatsSampling
        let hello: MachineHello
        let request: SystemStatsFollowRequest
        var expires = Date().addingTimeInterval(60)
        var busy = false

        init(sampler: any SystemStatsSampling, request: SystemStatsFollowRequest) {
            self.sampler = sampler
            hello = sampler.hello()
            self.request = request
        }
    }

    private var sessions: [UUID: Session] = [:]
    private var stopped = false
    private let makeSampler: () -> any SystemStatsSampling

    init(makeSampler: @escaping () -> any SystemStatsSampling = { LocalMachineSampler() }) {
        self.makeSampler = makeSampler
    }

    func execute(_ operation: String, payload: Data) async throws -> Data {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        let request = try JSONDecoder().decode(SystemStatsFollowRequest.self, from: payload)
        guard request.processes >= 0, request.processes <= 1000 else {
            throw ExtensionPeerError.invalidRequest
        }
        sessions = sessions.filter { $0.value.expires > Date() || $0.value.busy }
        switch operation {
        case "systemStats.follow.begin":
            guard sessions.count < 8, sessions[request.session] == nil else {
                throw ExtensionPeerError.invalidRequest
            }
            let session = Session(sampler: makeSampler(), request: request)
            session.busy = true
            sessions[request.session] = session
            do {
                _ = await session.sampler.sample()
                try await Task.sleep(for: .milliseconds(500))
                return try await reply(session, first: true)
            } catch {
                sessions[request.session] = nil
                throw error
            }
        case "systemStats.follow.read":
            guard let session = sessions[request.session], !session.busy,
                session.request.json == request.json,
                session.request.processes == request.processes
            else { throw ExtensionPeerError.invalidRequest }
            session.busy = true
            do { return try await reply(session, first: false) } catch {
                sessions[request.session] = nil; throw error
            }
        case "systemStats.follow.end":
            sessions[request.session] = nil
            return Data("{}".utf8)
        default: throw ExtensionPeerError.invalidRequest
        }
    }

    private func reply(_ session: Session, first: Bool) async throws -> Data {
        defer { session.busy = false }
        let sample = await session.sampler.sample()
        try Task.checkCancellation()
        guard !stopped, sessions[session.request.session] === session else {
            throw ExtensionPeerError.unavailable
        }
        session.expires = Date().addingTimeInterval(60)
        let stdout = SystemStatsOutput.render(
            hello: session.hello, sample: sample, header: first,
            json: session.request.json, compact: true, processes: session.request.processes)
        return try JSONEncoder().encode(ExtensionCLIReply(stdout: stdout, stderr: "", exitCode: 0))
    }

    func shutdown() {
        stopped = true
        sessions.removeAll()
    }
}

enum SystemStatsOutput {
    static func render(
        hello: MachineHello, sample: MachineSample, header: Bool,
        json: Bool, compact: Bool, processes: Int
    ) -> String {
        if json {
            return JSONSerializer.string(
                .object([
                    "host": MachineReports.hello(hello),
                    "sample": MachineReports.sample(sample, processes: processes),
                ]), pretty: !compact) + "\n"
        }
        var output: [String] = []
        if header { output.append("\(hello.host)  \(hello.os)  \(hello.cores) cores") }
        let memory = String(
            format: "%.0f%% of %@", sample.mem.usedPercent,
            ByteFormatter.string(sample.mem.totalKB * 1024))
        let load = sample.load.map { String(format: "%.2f", $0) }.joined(separator: " ")
        output.append(
            String(
                format: "cpu %5.1f%%   mem %@   load %@   net down %@ up %@",
                sample.cpu.total, memory, load, ByteFormatter.rate(sample.net.rxBps),
                ByteFormatter.rate(sample.net.txBps)))
        if processes > 0 {
            let rows = sample.procs.prefix(processes).map { process in
                [
                    String(process.pid), process.user, String(format: "%.1f", process.cpu),
                    String(format: "%.1f", process.mem), process.name,
                ]
            }
            output.append(
                TextTable.render(headers: ["PID", "USER", "CPU", "MEM", "NAME"], rows: rows))
        }
        return output.joined(separator: "\n") + "\n"
    }
}
