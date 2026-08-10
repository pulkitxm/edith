import Foundation

public enum FilesLaunch {
    public static let machineFlag = "--machine"
    public static let pathFlag = "--path"

    public static func parse(_ arguments: [String]) -> (machine: UUID, path: String?)? {
        var machine: UUID?
        var path: String?
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if word == machineFlag, index + 1 < arguments.count {
                machine = UUID(uuidString: arguments[index + 1])
                index += 2
                continue
            }
            if word == pathFlag, index + 1 < arguments.count {
                let value = arguments[index + 1]
                path = value.isEmpty ? nil : value
                index += 2
                continue
            }
            index += 1
        }
        guard let machine else { return nil }
        return (machine, path)
    }
}
