import AppKit
import GhosttyKit
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit
@testable import GhosttyTerminal

@Suite(.serialized) @MainActor struct TerminalSurfaceTests {
    enum Surface: String, CaseIterable {
        case machine
        case split
        case commandJ
    }

    @Test(arguments: Surface.allCases)
    func mountedSurfacesDeliverClicksDragsCopyAndPaste(surface: Surface) async throws {
        let engine = GhosttyEngineFixture(enabled: true)
        defer { engine.restore() }
        let board = NSPasteboard.general
        let previous = (board.types ?? []).compactMap { type in
            board.data(forType: type).map { (type, $0) }
        }
        defer {
            board.declareTypes(previous.map(\.0), owner: nil)
            for (type, data) in previous { board.setData(data, forType: type) }
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-surface-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let defaults = UserDefaults(suiteName: "test.terminal-surfaces.\(UUID().uuidString)")!
        let store = HerdrStore(defaults: defaults)
        store.open(
            HerdrAgent.make(
                machineID: "local", machineName: "This Mac", machineIsLocal: true,
                sshTarget: nil, session: "synthetic", pane: "fixture", kind: "Shell fixture",
                status: .working, title: "Synthetic terminal", workspace: "fixture", cwd: "/tmp"))
        var tab = try #require(store.sessions.first)
        tab.view = .split
        let holder = surface == .split ? tab.holder : TerminalSessionHolder()
        let request: TerminalLaunchRequest
        if surface == .commandJ {
            let package = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let executable = try #require(
                [".build/debug/ed", ".build/out/Products/Debug/ed"].map {
                    package.appendingPathComponent($0)
                }.first { FileManager.default.isExecutableFile(atPath: $0.path) })
            let controller = TerminalLaunchRequest(
                executable: "/usr/bin/python3",
                arguments: [
                    "-u", "-c",
                    """
                    import base64, json, sys
                    frame = b'\\x1b[2J\\x1b[3J\\x1b[Halpha beta gamma'
                    print(json.dumps({'type': 'terminal.frame', 'bytes': base64.b64encode(frame).decode()}))
                    for line in sys.stdin:
                        command = json.loads(line)
                        if command['type'] == 'terminal.input':
                            with open(sys.argv[1], 'ab') as output:
                                output.write(base64.b64decode(command['bytes']))
                    """,
                    output.path,
                ], environment: [])
            request = try HerdrTerminalBridge.launchRequest(
                bridgeExecutable: executable, controller: controller,
                mouse: HerdrTerminalSettings.load(defaults).mouse)
        } else {
            request = TerminalLaunchRequest(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "stty raw -echo; printf '\\033[2J\\033[3J\\033[Halpha beta gamma\\033[?1002h\\033[?1006h'; cat > '\(output.path)'",
                ], environment: [])
        }
        holder.start(
            executable: request.executable, arguments: request.arguments,
            environment: request.environment)
        var focusReports = 0
        let content: AnyView
        switch surface {
        case .machine:
            let session = MachineSession(
                machine: Machine(name: "Synthetic Mac", host: "localhost", username: "fixture"),
                local: true, observesWakeRequests: false)
            content = AnyView(
                MachineTerminalTab(
                    session: session, showsStatusBar: false, onFocus: { focusReports += 1 },
                    holder: holder, allowsShellLaunch: false))
        case .split:
            content = AnyView(
                HerdrSessionView(
                    store: store, tab: tab, launchEnabled: false,
                    onFocus: { focusReports += 1 }, showsDetails: false))
        case .commandJ:
            let terminal = HerdrPanelTerminal(
                id: "fixture", host: .local, session: "synthetic", cwd: "/tmp",
                holder: holder,
                scroll: HerdrTerminalScroll(open: { _, _, _ in throw CancellationError() }),
                pane: "fixture")
            content = AnyView(
                HerdrPanelTerminalView(
                    store: store, terminal: terminal, selected: true, wantsFocus: true,
                    launchEnabled: false, onFocus: { focusReports += 1 }))
        }
        let hosting = NSHostingView(rootView: content)
        let frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        hosting.frame = frame
        let window = TestWindowHost.window(contentRect: frame)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            holder.stop()
            window.contentView = nil
        }
        try await eventually {
            guard let view = holder.ghosttyView, let surface = view.surface else { return false }
            return ghostty_surface_mouse_captured(surface)
                && (view.accessibilityValue() as? String)?.contains("alpha beta gamma") == true
        }
        let view = try #require(holder.ghosttyView)
        let nativeSurface = try #require(view.surface)
        let size = ghostty_surface_size(nativeSurface)
        let cellWidth = CGFloat(size.cell_width_px) / window.backingScaleFactor
        let cellHeight = CGFloat(size.cell_height_px) / window.backingScaleFactor
        let start = NSPoint(x: 6 + cellWidth * 0.1, y: view.bounds.height - 4 - cellHeight * 0.5)
        let end = NSPoint(x: start.x + cellWidth * 5, y: start.y)
        #expect(hosting.hitTest(view.convert(start, to: hosting)) === view)
        _ = window.makeFirstResponder(view)
        #expect(focusReports > 0)

        func event(
            _ type: NSEvent.EventType, point: NSPoint, number: Int,
            flags: NSEvent.ModifierFlags = []
        ) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: view.convert(point, to: nil), modifierFlags: flags,
                    timestamp: Double(number), windowNumber: window.windowNumber, context: nil,
                    eventNumber: number, clickCount: 1, pressure: 0))
        }
        view.mouseDown(with: try event(.leftMouseDown, point: start, number: 1))
        view.mouseDragged(with: try event(.leftMouseDragged, point: end, number: 2))
        view.mouseUp(with: try event(.leftMouseUp, point: end, number: 3))
        try await eventually {
            guard let data = try? Data(contentsOf: output) else { return false }
            return String(decoding: data, as: UTF8.self).contains("m")
        }
        let reports = String(decoding: try Data(contentsOf: output), as: UTF8.self)
        #expect(reports.contains("\u{1B}[<0;"))
        #expect(reports.contains("\u{1B}[<32;"))

        view.mouseDown(with: try event(.leftMouseDown, point: start, number: 4, flags: .shift))
        view.mouseDragged(with: try event(.leftMouseDragged, point: end, number: 5, flags: .shift))
        view.mouseUp(with: try event(.leftMouseUp, point: end, number: 6, flags: .shift))
        #expect(view.selectedText() == "alpha")
        let copiedText = board.string(forType: .string)
        #expect(copiedText == "alpha")
        board.clearContents()
        board.setString("paste-marker", forType: .string)
        let paste = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 7,
                windowNumber: window.windowNumber, context: nil, characters: "v",
                charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        #expect(view.performKeyEquivalent(with: paste))
        try await eventually {
            guard let data = try? Data(contentsOf: output) else { return false }
            return String(decoding: data, as: UTF8.self).contains("paste-marker")
        }
        if let evidence = ProcessInfo.processInfo.environment["EDITH_TERMINAL_SURFACE_EVIDENCE"] {
            let received = String(decoding: try Data(contentsOf: output), as: UTF8.self)
            let result: [String: Any] = [
                "surface": surface.rawValue,
                "mousePressReachedChild": reports.contains("\u{1B}[<0;"),
                "mouseDragReachedChild": reports.contains("\u{1B}[<32;"),
                "copiedSelection": copiedText ?? "",
                "pasteReachedChild": received.contains("paste-marker"),
            ]
            let data = try JSONSerialization.data(
                withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(
                to: URL(fileURLWithPath: evidence).appendingPathComponent(
                    "\(surface.rawValue).json"))
        }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "terminal interaction did not complete")
    }
}
