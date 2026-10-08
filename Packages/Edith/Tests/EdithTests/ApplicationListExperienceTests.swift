import AppKit
import EdithKit
import SwiftUI
import Testing

@testable import Edith

@MainActor
@Suite(.serialized) struct ApplicationListExperienceTests {
    @Test func processProjectionSearchesEveryRowAndUsesStableOrdering() async throws {
        let processes = Self.processes()
        let model = MachineProcessListModel()
        await model.refresh(processes, debounce: false)
        #expect(model.rows.count == 10_000)
        #expect(model.rows.first?.cpu == 49)
        #expect(model.rows.prefix(2).map(\.pid) == [49, 99])
        model.query = "sample-worker-9999"
        await model.refresh(processes, debounce: false)
        #expect(model.rows.map(\.pid) == [9999])
        model.query = " sample-user "
        model.sortByMemory = true
        await model.refresh(processes, debounce: false)
        #expect(model.rows.count == 10_000)
        #expect(model.rows.first?.pid == 10_000)
    }

    @Test func supersededProjectionCannotReplaceNewFiltersAndCancellationKeepsContent() async {
        let model = MachineProcessListModel()
        let processes = Self.processes()
        await model.refresh(processes, debounce: false)
        model.selectedPID = 49
        let old = Task { await model.refresh(processes) }
        await Task.yield()
        model.query = "sample-worker-10000"
        await model.refresh(processes, debounce: false)
        await old.value
        #expect(model.rows.map(\.pid) == [10_000])
        #expect(model.selectedPID == nil)
        let cancelled = Task { await model.refresh(processes) }
        await Task.yield()
        model.loading.cancel()
        cancelled.cancel()
        await cancelled.value
        #expect(model.rows.map(\.pid) == [10_000])
        #expect(model.loading.hasContent)
        #expect(!model.loading.isRunning)
    }

    @Test func processFiltersBelongToTheWindowAndMachine() {
        let owner = WindowSessionOwner()
        let first = UUID()
        let second = UUID()
        owner.processes(for: first).query = "sample-worker"
        owner.processes(for: first).sortByMemory = true
        #expect(owner.processes(for: first).query == "sample-worker")
        #expect(owner.processes(for: first).sortByMemory)
        #expect(owner.processes(for: second).query.isEmpty)
        #expect(WindowSessionOwner().processes(for: first).query.isEmpty)
    }

    @Test(arguments: [false, true], [ColorScheme.light, .dark])
    func longListsUseNativeRecycledRows(compact: Bool, scheme: ColorScheme) async throws {
        let previous = UIScale.current
        UIScale.apply(compact ? 1.6 : 1)
        defer { UIScale.apply(previous) }
        let owner = WindowSessionOwner()
        let machine = Machine(name: "Sample machine", host: "sample.example.invalid")
        let session = MachineSession(machine: machine, observesWakeRequests: false)
        await owner.processes(for: machine.id).refresh(Self.processes(), debounce: false)
        let packages = (1...10_000).map { index in
            HomebrewPackage(
                kind: .formula, name: "sample-package-\(index)",
                displayName: "Sample package \(index)", description: "A synthetic package",
                installedVersions: ["1.0"], currentVersion: "1.1", outdated: index % 3 == 0)
        }
        let brew = HomebrewPageModel()
        brew.packages = packages
        brew.status = HomebrewStatus(available: true, executable: nil, version: "Homebrew 5.0")
        brew.loading.setContent()
        for (name, view) in [
            ("processes", AnyView(MachineProcessesTab(session: session))),
            ("packages", AnyView(HomebrewMaintenanceView(model: brew))),
        ] {
            let host = NSHostingView(
                rootView: view.environment(\.windowSessionOwner, owner)
                    .environment(\.compactLayout, compact)
                    .environment(\.colorScheme, scheme)
                    .environment(\.automaticViewActionsEnabled, false)
                    .environment(\.loadingAnimationsEnabled, false))
            host.frame = NSRect(x: 0, y: 0, width: compact ? 680 : 1280, height: 900)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.contentView = host
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            let table = try #require(table(in: host))
            #expect(table.numberOfRows == 10_000)
            let visible = table.tableColumns.indices.filter { !table.tableColumns[$0].isHidden }
            let last = try #require(visible.last)
            #expect(table.rect(ofColumn: last).maxX <= table.visibleRect.maxX + 2)
            #expect(table.subviews.filter { $0 is NSTableRowView }.count < 100)
            #expect(table.enclosingScrollView?.bounds.height ?? 0 > 300)
            table.scrollRowToVisible(9999)
            host.layoutSubtreeIfNeeded()
            #expect(table.rows(in: table.visibleRect).contains(9999))
            #expect(table.subviews.filter { $0 is NSTableRowView }.count < 100)
            table.scrollRowToVisible(0)
            if name == "packages" {
                brew.installedQuery = "sample-package-10000"
                try await Task.sleep(for: .milliseconds(120))
                host.layoutSubtreeIfNeeded()
                #expect(table.numberOfRows == 1)
                brew.installedQuery = ""
                brew.updatesOnly = true
                try await Task.sleep(for: .milliseconds(120))
                host.layoutSubtreeIfNeeded()
                #expect(table.numberOfRows == 3333)
                brew.updatesOnly = false
            }
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(png.count > 10_000)
            if let directory = ProcessInfo.processInfo.environment["EDITH_TEST_EVIDENCE_DIR"] {
                let folder = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true)
                try png.write(
                    to: folder.appendingPathComponent(
                        "\(name)-\(compact ? "compact" : "regular")-\(scheme).png"))
            }
        }
    }

    private func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { table(in: $0) }.first
    }

    private static func processes() -> [MachineProcess] {
        (1...10_000).map {
            MachineProcess(
                pid: $0, user: "sample-user", cpu: Double($0 % 50), mem: 1,
                rssKB: Int64($0 * 1024), name: "sample-worker-\($0)",
                cmd: "sample-worker --job \($0)")
        }
    }
}
