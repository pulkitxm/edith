import EdithKit
import Foundation

@MainActor
enum TimeLapseSurfaceBridge {
    private static var observer: NSObjectProtocol?
    static func install() {
        guard observer == nil else { return }
        observer = IPC.observe(
            IPC.Name.requestRecorderSurface,
            info: { info in
                MainActor.assumeIsolated {
                    guard let text = info["request"] as? String, text.utf8.count <= 8192,
                        let request = try? JSONDecoder().decode(
                            SurfaceRecorderRequest.self, from: Data(text.utf8))
                    else { return }
                    Task { await receive(request) }
                }
            })
    }
    private static func receive(_ request: SurfaceRecorderRequest) async {
        guard request.isLive(at: Date()),
            SharedDefaults.store.bool(forKey: AppStorageKeys.Tabs.timeLapseEnabled)
        else { reply(request, error: "Screen Recorder is off or this request expired."); return }
        guard #available(macOS 15.0, *) else {
            reply(request, error: "Screen Recorder needs macOS 15 or later."); return
        }
        let recorder = TimeLapseRecorder.shared
        if request.operation == .stop {
            guard recorder.surfaceSnapshot.permitsStop(request) else {
                reply(request, error: "The recording changed. Refresh before stopping it."); return
            }
            await recorder.stop()
        }
        let data = try? JSONEncoder().encode(recorder.surfaceSnapshot)
        reply(request, snapshot: data.map { String(decoding: $0, as: UTF8.self) })
    }
    private static func reply(
        _ request: SurfaceRecorderRequest, snapshot: String? = nil, error: String? = nil
    ) {
        var value: [String: Any] = ["requestID": request.id.uuidString, "ok": error == nil]
        value["snapshot"] = snapshot; value["error"] = error
        IPC.post(IPC.Name.recorderSurfaceResult, userInfo: value)
    }
}
