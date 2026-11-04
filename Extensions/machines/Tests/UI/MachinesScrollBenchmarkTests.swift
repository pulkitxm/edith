@testable import MachinesExtension
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@Suite(.serialized) @MainActor struct MachinesScrollBenchmarkTests {
    static let enabled = ProcessInfo.processInfo.environment["EDITH_SCROLL_BENCHMARK"] != nil

    @Test(.enabled(if: enabled)) func scrollingEveryLongListWithSyntheticMachines() async throws {
        let only = ProcessInfo.processInfo.environment["EDITH_SCROLL_CASE"]
        let frames = Int(ProcessInfo.processInfo.environment["EDITH_SCROLL_FRAMES"] ?? "") ?? 300
        for name in ["processes", "containers", "images"] where only == nil || only == name {
            let timing = await Self.measure(name, count: Self.heavyCount(name), frames: frames)
            print("machines-scroll \(name): \(timing) slowAt=\(timing.slowOffsets)")
        }
    }

    @Test(arguments: ["processes", "containers", "images"]) func scrollStaysWithinBounds(
        name: String
    ) async throws {
        let timing = await Self.measure(name, count: 600, frames: 120)
        print("machines-scroll regression \(name): \(timing)")
        #expect(Set(timing.offsets).count > 10)
        #expect(timing.worst < 80)
        #expect(timing.median < 12)
    }

    static func heavyCount(_ name: String) -> Int {
        switch name {
        case "processes": return 2_000
        case "containers": return 400
        default: return 1_500
        }
    }

    static func measure(_ name: String, count: Int, frames: Int) async -> MachinesScrollTiming {
        let machine = Machine(name: "Sample Server", host: "sample.example.com")
        let session = MachineSession(
            machine: machine, local: false, observesWakeRequests: false, synthetic: true)
        MachineProcessModels.reset()
        let size = CGSize(width: 1_100, height: 800)
        let view: AnyView
        switch name {
        case "processes":
            session.apply(sample: MachinesSynthetic.sample(processes: count))
            let model = MachineProcessModels.model(for: session.id)
            await model.refresh(session.sample?.procs ?? [], debounce: false)
            view = AnyView(
                MachineProcessesTab(session: session)
                    .environment(\.machineViewPresented, true)
                    .environment(\.compactLayout, false))
        default:
            let bridge = MachinesSilentBridge()
            let client = MachineUIClient(
                client: ExtensionEngineClient(bridge: bridge, presentationID: UUID())!)
            let remote = MachineSession(machine: machine, local: false, uiClient: client)
            remote.applyUIState(
                MachinesSynthetic.state(
                    machine: machine, containers: name == "containers" ? count : 0,
                    images: name == "images" ? count : 0))
            let screen = name == "containers" ? DockerScreen.containers : DockerScreen.images
            view = AnyView(
                MachinesDockerListFixture(session: remote, screen: screen)
                    .environment(\.machineViewPresented, true)
                    .environment(\.compactLayout, false))
        }
        let (window, host) = MachinesScrollHarness.host(
            view.environment(\.colorScheme, .dark), size: size)
        await MachinesScrollHarness.settle(host, for: .seconds(1))
        let timing = await MachinesScrollHarness.scroll(host, frames: frames)
        window.orderOut(nil)
        window.contentView = nil
        return timing
    }
}

struct MachinesDockerListFixture: View {
    let session: MachineSession
    let screen: DockerScreen

    var body: some View {
        switch screen {
        case .containers:
            DockerContainerList(
                session: session, query: "", dark: true, busyIDs: [], onOpen: { _ in },
                onAction: { _, _ in }, onShell: { _ in }, onRemove: { _ in },
                onGroupAction: { _, _, _ in })
        default:
            DockerSimpleList(
                rows: session.images.map {
                    DockerRow(
                        id: $0.id, title: $0.displayName,
                        subtitle: "\($0.shortID) · \($0.createdSince)",
                        trailing: ByteFormatter.string($0.sizeBytes),
                        symbol: "square.stack.3d.up", badge: $0.dangling ? "dangling" : nil)
                }, dark: true, onDelete: { _ in })
        }
    }
}

@MainActor final class MachinesSilentBridge: NSObject {
    @objc func invoke(_ data: NSData, completion: @escaping @Sendable (NSData) -> Void) {}
    @objc func cancel(_ token: NSString) {}
}

enum MachinesSynthetic {
    static func sample(processes count: Int) -> MachineSample {
        let words = ["worker", "daemon", "agent", "server", "indexer", "proxy", "scheduler"]
        let procs = (0..<count).map { index in
            MachineProcess(
                pid: 100 + index, user: index % 5 == 0 ? "root" : "svc\(index % 7)",
                cpu: Double((index * 37) % 1_000) / 10, mem: Double(index % 90) / 10,
                rssKB: Int64(2_000 + (index * 7_919) % 900_000),
                name: "\(words[index % words.count])-\(index)",
                cmd:
                    "/usr/local/lib/sample/\(words[index % words.count])/bin/\(words[index % words.count]) --config /etc/sample/\(index).toml --listen 127.0.0.1:\(8_000 + index % 900) --log-level info"
            )
        }
        return MachineSample(
            ts: 1_000, dt: 2, cpu: MachineCPU(total: 20),
            mem: MachineMemory(totalKB: 16_000_000, availKB: 8_000_000, usedKB: 8_000_000),
            procs: procs)
    }

    static func state(machine: Machine, containers: Int, images: Int) -> MachineUISessionState {
        let projects = max(1, containers / 10)
        let rows = (0..<containers).map { index in
            DockerContainer(
                id: String(format: "%064x", index + 1), names: ["sample-service-\(index)"],
                image: "registry.example.com/sample/service-\(index % 31):1.\(index % 17)",
                command: "run", state: index % 4 == 0 ? .exited : .running,
                status: index % 4 == 0 ? "Exited (0) 3 hours ago" : "Up \(index % 50) hours",
                ports: [
                    DockerPortMapping(
                        hostIP: "0.0.0.0", hostPort: 8_000 + index, containerPort: 80,
                        proto: "tcp")
                ], composeProject: "project-\(index % projects)",
                composeService: "service-\(index)", cpuPercent: Double(index % 90) / 3,
                memUsedBytes: Int64(index % 400 + 10) * 1_048_576)
        }
        let pictures = (0..<images).map { index in
            DockerImage(
                id: String(format: "sha256:%064x", index + 1),
                repository: "registry.example.com/sample/image-\(index)", tag: "v\(index % 13)",
                createdSince: "\(index % 30 + 1) days ago",
                sizeBytes: Int64(index % 900 + 20) * 1_048_576, dangling: index % 40 == 0)
        }
        return MachineUISessionState(
            machine: machine, state: .connected(latencyMillis: 10), platform: .linux, hello: nil,
            slow: nil,
            sample: nil,
            docker: DockerAvailability(status: .available(serverVersion: "27.0", hasCompose: true)),
            containersLoaded: true,
            containersError: nil, containers: rows, images: pictures, volumes: [],
            diskUsage: [], networks: [], services: [], facts: MachineSessionSummary(),
            activeForwards: [], isRemounting: false, isApplyingPlatformProfile: false,
            platformProfileRevertsAt: nil, internetSpeed: nil, internetSpeedError: nil,
            isTestingInternetSpeed: false, histories: Array(repeating: [], count: 8))
    }
}
