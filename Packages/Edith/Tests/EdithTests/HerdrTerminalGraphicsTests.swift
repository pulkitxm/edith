import Darwin
import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct HerdrTerminalGraphicsTests {
    @Test func nativeRelayPreservesGraphicsReplayAndTerminalReplies() throws {
        let pixels = Data([
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 255, 255,
        ]).base64EncodedString()
        let file = Data("/fixture/terminal-image.png".utf8).base64EncodedString()
        let sharedMemory = Data("/fixture-terminal-image".utf8).base64EncodedString()
        let sequences = [
            "\u{1B}[2J\u{1B}[H",
            "\u{1B}_Ga=t,f=32,s=2,v=2,i=7,m=1;\(pixels.prefix(12))\u{1B}\\",
            "\u{1B}_Gm=0;\(pixels.dropFirst(12))\u{1B}\\",
            "\u{1B}_Ga=p,i=7,c=4,r=2;\u{1B}\\",
            "\u{1B}_Ga=t,t=f,f=100,i=8;\(file)\u{1B}\\",
            "\u{1B}_Ga=t,t=s,f=32,s=2,v=2,i=9;\(sharedMemory)\u{1B}\\",
            "\u{1B}_Ga=d,d=i,i=7;\u{1B}\\",
        ]
        let graphics = Data(sequences.joined().utf8)
        let replies = Data("\u{1B}_Gi=7;OK\u{1B}\\\u{1B}[6;18;9t".utf8)
        let result = try relay(graphics: graphics, input: replies)
        #expect(result.status == 0)
        #expect(result.bytes.starts(with: graphics))
        #expect(result.bytes.suffix(replies.count) == replies)
    }

    @Test func nativeClientHasItsOwnControllingTerminalAndPixelGeometry() throws {
        let geometry = HerdrTerminalDimensions(
            columns: 120, rows: 40, cellWidth: 9, cellHeight: 18)
        let result = try relay(graphics: Data(), input: Data("ready".utf8), resized: geometry)
        #expect(result.status == 0)
        #expect(String(decoding: result.bytes, as: UTF8.self) == "40,120,1080,720|ready")
    }

    @Test func nativeRelayDoesNotTruncateImagesLargerThanItsReadBuffer() throws {
        let pixels = Data(repeating: 127, count: 128 * 128 * 4).base64EncodedString()
        let graphics = Data("\u{1B}_Ga=T,f=32,s=128,v=128,i=10;\(pixels)\u{1B}\\".utf8)
        let reply = Data("\u{1B}_Gi=10;OK\u{1B}\\".utf8)
        let result = try relay(graphics: graphics, input: reply)
        #expect(result.status == 0)
        #expect(result.bytes == graphics + reply)
    }

    @Test(arguments: [false, true])
    func nativeRelayPumpsLargePasteAndImageOutputSimultaneously(
        backpressuredOutput: Bool
    ) throws {
        let paste = Data(repeating: 120, count: 64 * 1024)
        let script = """
            import os, signal
            signal.alarm(8)
            graphics = b'g' * (1024 * 1024)
            while graphics:
                graphics = graphics[os.write(1, graphics):]
            data = bytearray()
            while len(data) < 65536:
                data.extend(os.read(0, 65536 - len(data)))
            while data:
                data = data[os.write(1, data):]
            """
        let result = try relay(
            graphics: Data(), input: paste, script: script, asynchronousInput: true,
            backpressuredOutput: backpressuredOutput)
        #expect(result.status == 0)
        #expect(result.bytes == Data(repeating: 103, count: 1024 * 1024) + paste)
    }

    @Test func closingAClientThatIgnoresHangupAndTerminationIsBounded() throws {
        let script = """
            import os, signal, time
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.alarm(8)
            os.write(1, b'ready')
            time.sleep(30)
            """
        let child = try HerdrNativeTerminalProcess(
            request: TerminalLaunchRequest(
                executable: "/usr/bin/python3", arguments: ["-c", script], environment: []),
            dimensions: HerdrTerminalDimensions(
                columns: 80, rows: 24, cellWidth: 8, cellHeight: 16))
        defer { child.close() }
        #expect(
            try HerdrTerminalStream.read(from: child.terminal, timeoutMilliseconds: 5000)
                == Data("ready".utf8))
        let clock = ContinuousClock()
        let started = clock.now
        child.close()
        #expect(started.duration(to: clock.now) < .seconds(2))
        #expect(child.terminationStatus == 128 + SIGKILL)
        child.close()
        #expect(child.terminationStatus == 128 + SIGKILL)
    }

    @Test func closingInputCancelsAnUnreadPasteWithinTheShutdownBudget() throws {
        let script = """
            import os, signal, time
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.alarm(8)
            os.write(1, b'ready')
            time.sleep(30)
            """
        let clock = ContinuousClock()
        let started = clock.now
        let result = try relay(
            graphics: Data(), input: Data(repeating: 120, count: 64 * 1024), script: script,
            asynchronousInput: true, closeInput: true)
        #expect(started.duration(to: clock.now) < .seconds(2))
        #expect(result.status == 0)
    }

    @Test(arguments: [HerdrTerminalMouse.buttons, .scroll])
    func nativeInputRetainsWheelAndGraphicsResponsesUnderEitherMousePolicy(
        mouse: HerdrTerminalMouse
    ) throws {
        var router = HerdrTerminalInputRouter(mouse: mouse, transport: .terminal)
        let wheel = Data("\u{1B}[<64;11;6M".utf8)
        let response = Data("\u{1B}_Gi=7;OK\u{1B}\\".utf8)
        let click = Data("\u{1B}[<0;11;6M".utf8)
        #expect(try router.commands(for: wheel + response) == [wheel + response])
        #expect(try router.commands(for: click) == (mouse == .buttons ? [click] : []))
        #expect(try router.commands(for: Data("\u{1B}[<35;11;6M".utf8)).isEmpty)
    }

    @Test func nativeInputBuffersSplitMouseReportsWithoutSplittingGraphicsReplies() throws {
        var router = HerdrTerminalInputRouter(transport: .terminal)
        let response = Data("\u{1B}_Gi=7;OK\u{1B}\\".utf8)
        #expect(try router.commands(for: response + Data("\u{1B}[<64;".utf8)) == [response])
        #expect(try router.commands(for: Data("11;6M".utf8)) == [Data("\u{1B}[<64;11;6M".utf8)])
        #expect(try router.commands(for: Data([0x1B])).isEmpty)
        #expect(try router.flushEscapePrefix() == [Data([0x1B])])
    }

    private func relay(
        graphics: Data, input: Data, resized: HerdrTerminalDimensions? = nil,
        script: String? = nil, asynchronousInput: Bool = false,
        backpressuredOutput: Bool = false, closeInput: Bool = false
    ) throws -> (status: Int32, bytes: Data) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: file) }
        let capture = try FileHandle(forWritingTo: file)
        defer { try? capture.close() }
        let outputPipe = backpressuredOutput ? Pipe() : nil
        let output = outputPipe?.fileHandleForWriting ?? capture
        let readerDone = DispatchGroup()
        if let outputPipe {
            readerDone.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { readerDone.leave() }
                usleep(200_000)
                while true {
                    let bytes = outputPipe.fileHandleForReading.availableData
                    if bytes.isEmpty { return }
                    try? capture.write(contentsOf: bytes)
                }
            }
        }
        defer {
            if let outputPipe {
                try? outputPipe.fileHandleForWriting.close()
                _ = readerDone.wait(timeout: .now() + 5)
                try? outputPipe.fileHandleForReading.close()
            }
        }
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        let writerDone = DispatchGroup()
        if asynchronousInput {
            writerDone.enter()
            let descriptor = pipe.fileHandleForWriting.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            #expect(fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0)
            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    if closeInput { try? pipe.fileHandleForWriting.close() }
                    writerDone.leave()
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                var offset = 0
                while offset < input.count, ContinuousClock.now < deadline {
                    let written = input.withUnsafeBytes { bytes in
                        Darwin.write(
                            descriptor, bytes.baseAddress!.advanced(by: offset),
                            input.count - offset)
                    }
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno != EAGAIN, errno != EINTR {
                        return
                    } else {
                        usleep(1000)
                    }
                }
            }
        } else {
            try pipe.fileHandleForWriting.write(contentsOf: input)
        }
        let fixture =
            script ?? """
                import base64, fcntl, os, select, struct, termios
                tty = os.open('/dev/tty', os.O_RDWR)
                assert os.tcgetpgrp(tty) == os.getpgrp()
                assert os.getsid(0) == os.getpid()
                os.close(tty)
                graphics = base64.b64decode('\(graphics.base64EncodedString())')
                for start in range(0, len(graphics), 4093):
                    os.write(1, graphics[start:start + 4093])
                if not select.select([0], [], [], 5)[0]:
                    raise RuntimeError('terminal input was not relayed')
                data = os.read(0, 4096)
                size = struct.unpack('HHHH', fcntl.ioctl(0, termios.TIOCGWINSZ, bytes(8)))
                if not graphics:
                    os.write(1, (','.join(str(value) for value in size) + '|').encode())
                os.write(1, data)
                """
        let specification = HerdrTerminalBridgeSpecification(
            controller: TerminalLaunchRequest(
                executable: "/usr/bin/python3", arguments: ["-c", fixture], environment: []),
            transport: .terminal)
        var samples = 0
        let status = try HerdrNativeTerminalBridge.relay(
            specification: specification, input: pipe.fileHandleForReading, output: output,
            dimensions: {
                defer { samples += 1 }
                if samples > 0, let resized { return resized }
                return HerdrTerminalDimensions(
                    columns: 80, rows: 24, cellWidth: 8, cellHeight: 16)
            })
        if asynchronousInput { #expect(writerDone.wait(timeout: .now() + 6) == .success) }
        if let outputPipe {
            try outputPipe.fileHandleForWriting.close()
            #expect(readerDone.wait(timeout: .now() + 5) == .success)
        }
        return (status, try Data(contentsOf: file))
    }
}
