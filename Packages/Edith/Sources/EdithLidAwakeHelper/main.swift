import EdithKit
import Foundation
import Security

final class LidAwakeHelper: NSObject, NSXPCListenerDelegate, LidAwakePrivilegedProtocol {
    private let listener: NSXPCListener
    private let clientRequirement: SecRequirement?

    override init() {
        listener = NSXPCListener(machServiceName: LidAwakePrivilegedService.machServiceName)
        clientRequirement = Self.loadClientRequirement()
        super.init()
        listener.delegate = self
    }

    func run() {
        listener.resume()
        RunLoop.current.run()
    }

    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard let clientRequirement, Self.isTrusted(connection, requirement: clientRequirement)
        else { return false }
        connection.exportedInterface = NSXPCInterface(with: LidAwakePrivilegedProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func setSleepDisabled(_ disable: Bool, reply: @escaping (NSError?) -> Void) {
        do {
            let result = try LidAwakeCommandProcess.run(
                executableURL: URL(fileURLWithPath: LidAwakeCommand.toolPath),
                arguments: LidAwakeCommand.arguments(active: disable))
            guard !result.timedOut else {
                reply(
                    NSError(
                        domain: LidAwakePrivilegedService.bundleIdentifier, code: Int(ETIMEDOUT),
                        userInfo: [NSLocalizedDescriptionKey: "pmset timed out"])
                )
                return
            }
            guard result.terminationStatus != 0 else {
                reply(nil)
                return
            }
            reply(
                NSError(
                    domain: LidAwakePrivilegedService.bundleIdentifier,
                    code: Int(result.terminationStatus),
                    userInfo: [
                        NSLocalizedDescriptionKey: result.standardError.isEmpty
                            ? "pmset failed" : result.standardError
                    ]))
        } catch {
            reply(error as NSError)
        }
    }

    private static func loadClientRequirement() -> SecRequirement? {
        var ownCode: SecCode?
        guard
            SecCodeCopySelf([], &ownCode) == errSecSuccess,
            let ownCode
        else { return nil }
        var ownStaticCode: SecStaticCode?
        guard
            SecCodeCopyStaticCode(ownCode, [], &ownStaticCode) == errSecSuccess,
            let ownStaticCode
        else { return nil }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                ownStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let values = information as? [CFString: Any],
            let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String
        else { return nil }
        let expression =
            "identifier \"\(LidAwakePrivilegedService.clientBundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var requirement: SecRequirement?
        guard
            SecRequirementCreateWithString(expression as CFString, [], &requirement)
                == errSecSuccess
        else { return nil }
        return requirement
    }

    private static func isTrusted(
        _ connection: NSXPCConnection, requirement: SecRequirement
    ) -> Bool {
        let attributes = [kSecGuestAttributePid: NSNumber(value: connection.processIdentifier)]
        var code: SecCode?
        guard
            SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code)
                == errSecSuccess,
            let code
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

LidAwakeHelper().run()
