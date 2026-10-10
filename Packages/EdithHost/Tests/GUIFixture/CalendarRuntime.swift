import AppKit
import Foundation

@MainActor final class GUIFixtureCalendar: NSObject {
    private var started = false
    private var requestCount = 0

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            return ["id": "calendar", "role": "app", "version": "1.0.0", "hostABI": "edith-host-1"]
                as NSDictionary
        case "start":
            guard let host = input["hostIdentifier"] as? String,
                host.hasPrefix("com.pulkit.edith.tests.gui-"),
                ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
            else { return ["ok": false] as NSDictionary }
            started = true
        case "stop": started = false
        case "status": return ["ok": true, "running": started] as NSDictionary
        case "view": return NSViewController()
        default: break
        }
        return ["ok": true] as NSDictionary
    }

    @objc func invoke(_ input: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        guard started, let command = input["command"] as? String else {
            completion(nil, "Fixture is inactive"); return
        }
        let response: Any
        switch command {
        case "surface.sources":
            response = [["id": "synthetic-calendar", "title": "Synthetic calendar"]]
        case "surface.snapshot":
            requestCount += 1
            if let home = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] {
                let destination = URL(fileURLWithPath: home).appendingPathComponent(
                    "surface-request-count")
                try? Data(String(requestCount).utf8).write(to: destination, options: .atomic)
            }
            response = [
                "contractVersion": 1, "providerID": "calendar", "metrics": [], "actions": [],
                "sources": [["id": "synthetic-calendar", "title": "Synthetic calendar"]],
                "rows": [
                    [
                        "id": "synthetic-review", "sourceID": "synthetic-calendar",
                        "title": "Synthetic design review", "detail": "Synthetic calendar",
                        "value": "10:30", "icon": "calendar", "actions": [],
                    ]
                ],
            ]
        default: completion(nil, "Unsupported fixture command"); return
        }
        do { completion(try JSONSerialization.data(withJSONObject: response) as NSData, nil) } catch
        {
            completion(nil, "Invalid fixture data")
        }
    }
}

@_cdecl("edith_extension_create")
public func createGUIFixtureCalendar() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(GUIFixtureCalendar()).toOpaque())
        })
}
