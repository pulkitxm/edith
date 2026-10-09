import EdithExtensionSupport
import Foundation
import Testing

@testable import MusicExtension

extension MusicExtensionTests {
    @Suite struct MusicNativePlayerTests {
        @Test func loadsOnlyLibrariesWithTheRequiredBridgeSymbols() async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let library = try await fixture(root, source: "int unrelated(void) { return 1; }")
            #expect(throws: CocoaError.self) {
                _ = try MusicNativePlayer(
                    libraryURL: library, service: "synthetic.music", name: "Mock Player",
                    resume: true, receive: { _ in }, onExit: {})
            }
        }

        @Test func nativeCallbacksAndCommandsStopWithTheirOwner() async throws {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let library = try await fixture(
                root,
                source: """
                    #include <stdbool.h>
                    #include <stdlib.h>
                    #include <string.h>
                    typedef void (*callback_t)(const unsigned char *, size_t, void *);
                    typedef struct { callback_t callback; void *context; } player_t;
                    void *edith_music_player_start(const char *service, const char *name, int mode,
                        callback_t callback, void *context) {
                        player_t *player = malloc(sizeof(player_t));
                        player->callback = callback; player->context = context;
                        const char *event = "{\\"event\\":\\"connected\\",\\"account\\":\\"mock-listener\\"}";
                        callback((const unsigned char *)event, strlen(event), context);
                        return player;
                    }
                    bool edith_music_player_send(void *handle, const unsigned char *bytes, size_t size) {
                        if (!handle || !size) return false;
                        player_t *player = handle;
                        player->callback(bytes, size, player->context);
                        return true;
                    }
                    void edith_music_player_stop(void *handle) { free(handle); }
                    """)
            let probe = Probe()
            let player = try MusicNativePlayer(
                libraryURL: library, service: "synthetic.music", name: "Mock Player",
                resume: true, receive: { probe.append($0) }, onExit: { probe.exited() })
            #expect(probe.events.count == 1)
            #expect(String(decoding: probe.events[0], as: UTF8.self).hasSuffix("\n"))
            let command = Data(#"{"event":"volume","value":0.4}"#.utf8)
            player.send(command) { probe.failed() }
            #expect(probe.events.last == command + Data([10]))
            player.send(Data(repeating: 1, count: 4097)) { probe.failed() }
            #expect(probe.failures == 1)
            player.stop()
            player.stop()
            player.send(command) { probe.failed() }
            #expect(probe.failures == 2)
            #expect(probe.events.count == 2)
            let restarted = try MusicNativePlayer(
                libraryURL: library, service: "synthetic.music", name: "Mock Player",
                resume: true, receive: { probe.append($0) }, onExit: { probe.exited() })
            restarted.stop()
            #expect(probe.events.count == 3)
        }

        private func directory() throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }

        private func fixture(_ root: URL, source: String) async throws -> URL {
            let input = root.appendingPathComponent("fixture.c")
            let output = root.appendingPathComponent("fixture.dylib")
            try source.write(to: input, atomically: true, encoding: .utf8)
            let result = try await CLICommandRunner.runLocal(
                CLICommandRequest(
                    executableURL: URL(fileURLWithPath: "/usr/bin/clang"),
                    arguments: ["-dynamiclib", input.path, "-o", output.path],
                    environment: ["PATH": "/usr/bin:/bin"],
                    timeout: 30, maximumOutputBytes: 65536), onLine: { _ in })
            try #require(result.terminationStatus == 0)
            return output
        }
    }
}

private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Data] = []
    private var failedCount = 0
    private var exitCount = 0
    var events: [Data] { lock.withLock { stored } }
    var failures: Int { lock.withLock { failedCount } }
    func append(_ data: Data) { lock.withLock { stored.append(data) } }
    func failed() { lock.withLock { failedCount += 1 } }
    func exited() { lock.withLock { exitCount += 1 } }
}
