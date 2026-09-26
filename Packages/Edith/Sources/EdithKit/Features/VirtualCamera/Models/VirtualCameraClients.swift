import AVFoundation
import Foundation

public enum VirtualCameraClients {
    public typealias Resolver = (String) -> String?

    public static func name(for signingID: String, resolver: Resolver) -> String {
        var candidate = signingID
        while !candidate.isEmpty {
            if let name = resolver(candidate) { return name }
            guard let dot = candidate.lastIndex(of: ".") else { break }
            candidate = String(candidate[..<dot])
            guard candidate.contains(".") else { break }
        }
        return signingID
    }

    public static func clients(_ signingIDs: [String], resolver: Resolver) -> [VirtualCameraClient]
    {
        var seen = Set<String>()
        var result: [VirtualCameraClient] = []
        for id in signingIDs {
            let name = name(for: id, resolver: resolver)
            guard seen.insert(name).inserted else { continue }
            result.append(VirtualCameraClient(id: id, name: name))
        }
        return result
    }

    public static func accessDescription(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: "granted"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notRequested"
        @unknown default: "unknown"
        }
    }
}
