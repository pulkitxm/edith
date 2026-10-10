import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor final class FixtureRuntime: NSObject {
    private var client: ExtensionEngineClient?
    @objc func execute(_ input: NSDictionary) -> AnyObject? {
        guard let operation = input["operation"] as? String else { return nil }
        switch operation {
        case "describe":
            return ["id": "sample", "version": "1.0.0", "hostABI": "HOST_ABI", "role": "app"]
                as NSDictionary
        case "configureUI":
            guard let configuration = ExtensionUIConfiguration(context: input),
                let client = configuration.engineClient
            else {
                return ["ok": false] as NSDictionary
            }
            self.client = client
            return ["ok": true] as NSDictionary
        case "view":
            guard let client else { return nil }
            return NSHostingController(rootView: ExtensionPageHost { FixturePage(client: client) })
        case "stopUI": client?.invalidate(); client = nil; return ["ok": true] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
    }
}

private struct FixturePage: View {
    let client: ExtensionEngineClient
    @State private var title = "Waiting for owned engine"
    @State private var count = 0
    @State private var hold = "No request pending"
    var body: some View {
        VStack(spacing: 20) {
            Text("Owned remote controller").font(.edithText(.title))
            Text(title)
            Text("Engine reads: \(count)")
            Button("Read owned record") { Task { await read() } }
            Button("Hold owned request") {
                Task {
                    hold = "Request pending"
                    do {
                        _ = try await client.invoke("sample.hold"); hold = "Request finished"
                    } catch { hold = "Request cancelled" }
                }
            }
            Text(hold)
        }
        .padding(32)
        .task { await read() }
    }
    @MainActor private func read() async {
        do {
            let data = try await client.invoke("sample.read")
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let next = value["count"] as? Int, let title = value["title"] as? String
            else { return }
            count = next
            self.title = title
        } catch { title = "Owned engine unavailable" }
    }
}

@_cdecl("edith_extension_create")
public func createFixtureRuntime() -> UnsafeMutableRawPointer? {
    let address = MainActor.assumeIsolated {
        UInt(bitPattern: Unmanaged.passRetained(FixtureRuntime()).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: address)
}
