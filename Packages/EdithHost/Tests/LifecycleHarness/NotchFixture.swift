import CoreFoundation
import EdithExtensionSupport
import EdithHostCore
import Foundation

@MainActor enum NotchLifecycleMetadata {
    static let declinedCommands = [
        "notch.panel.attach", "notch.panel.wait", "notch.panel.geometry", "notch.panel.measure",
        "notch.panel.pointer", "notch.panel.detach", "notch.panel.scene.stop", "notch.panel.drop",
        "notch.panel.promise.prepare", "notch.panel.promise.finish", "notch.panel.transfer.ack",
        "notch.panel.transfer.finish", "notch.chrome.read", "notch.chrome.action",
        "notch.chrome.thumbnail", "notch.chrome.browser", "notch.chrome.quick",
        "notch.chrome.camera",
        "surface.snapshot", "surface.perform", "browser.cli", "browser.cli.start",
        "browser.cli.read",
        "browser.cli.write", "browser.cli.cancel", "browser.cli.end", "notch.cli",
        "notch.cli.start",
        "notch.cli.read", "notch.cli.write", "notch.cli.cancel", "notch.cli.end",
    ]

    static func verify(invoke: (String) async throws -> Data) async throws {
        try validateCatalog(await invoke("notchShelf.cli.catalog"))
        try await InertCommandDecline.verify(declinedCommands, invoke: invoke)
    }

    static func validateCatalog(_ bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= 512 * 1_024,
            let catalog = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            Set(catalog.keys) == [
                "version", "owner", "commands", "settings", "acceptsInput", "parserHelp",
            ],
            let version = catalog["version"] as? NSNumber,
            CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
            catalog["owner"] as? String == "notchShelf",
            let acceptsInput = catalog["acceptsInput"] as? NSNumber,
            CFGetTypeID(acceptsInput) == CFBooleanGetTypeID(), acceptsInput.boolValue,
            let settings = catalog["settings"] as? [Any], settings.isEmpty,
            let commands = catalog["commands"] as? [[String: Any]],
            !commands.isEmpty, commands.count <= 128,
            let help = catalog["parserHelp"] as? [[String: Any]], help.count == 2
        else { throw HostWorkerError.invalidResponse }
        var roots: Set<String> = []
        var routes: Set<[String]> = []
        for command in commands {
            guard
                Set(command.keys) == [
                    "route", "operation", "streamOperation", "streamDeadline", "summary", "timeout",
                    "destructive", "readsInput", "jsonOutput",
                ], let route = command["route"] as? [String], !route.isEmpty, route.count <= 12,
                route.allSatisfy(validComponent), routes.insert(route).inserted,
                let first = route.first, ["shelf", "browser"].contains(first),
                let operation = command["operation"] as? String,
                operation == (first == "shelf" ? "notch.cli" : "browser.cli"),
                command["streamOperation"] as? String == operation,
                let summary = command["summary"] as? String,
                !summary.isEmpty, summary.utf8.count <= 4_096,
                integer(command["timeout"], equals: 30),
                integer(command["streamDeadline"], equals: 30),
                boolean(command["destructive"]) != nil,
                boolean(command["readsInput"]) == false,
                boolean(command["jsonOutput"]) == false
            else { throw HostWorkerError.invalidResponse }
            roots.insert(first)
        }
        guard roots == ["shelf", "browser"], routes.contains(["shelf"]),
            routes.contains(["browser"])
        else { throw HostWorkerError.invalidResponse }
        var parserRoots: Set<String> = []
        var parserRoutes: Set<[String]> = []
        func collect(_ node: [String: Any], parent: [String]) throws {
            guard let name = node["commandName"] as? String, validComponent(name),
                parent.count < 12, parserRoutes.count < 128
            else { throw HostWorkerError.invalidResponse }
            let route = parent + [name]
            guard parserRoutes.insert(route).inserted else { throw HostWorkerError.invalidResponse }
            if let children = node["subcommands"] {
                guard let children = children as? [[String: Any]] else {
                    throw HostWorkerError.invalidResponse
                }
                for child in children { try collect(child, parent: route) }
            }
        }
        for parser in help {
            guard let command = parser["command"] as? [String: Any],
                let name = command["commandName"] as? String,
                roots.contains(name), parserRoots.insert(name).inserted
            else { throw HostWorkerError.invalidResponse }
            try collect(command, parent: [])
        }
        guard parserRoutes == routes else { throw HostWorkerError.invalidResponse }
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 45
            }
    }

    private static func integer(_ value: Any?, equals expected: Int) -> Bool {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return false }
        return number == NSNumber(value: expected)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }
}
