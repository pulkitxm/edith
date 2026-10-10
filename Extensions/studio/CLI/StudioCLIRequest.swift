import EdithExtensionSupport
import Foundation

struct StudioCLIRequest: Codable, Sendable {
    let arguments: [String]
    let workingDirectory: String
    let standardInput: Data
    let interactive: Bool

    init(
        arguments: [String], workingDirectory: String, standardInput: Data = Data(),
        interactive: Bool = false
    ) throws {
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.standardInput = standardInput
        self.interactive = interactive
        try validate()
    }

    func validate() throws {
        try ExtensionCLIRequest(arguments: arguments).validate()
        _ = try StudioCommands.localPath(workingDirectory)
        guard standardInput.count <= StudioEditPlanInput.maximumBytes else {
            throw ExtensionPeerError.invalidRequest
        }
    }
}
