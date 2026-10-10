import Foundation

@MainActor
public final class HostHerdrWindowLease {
    public let target: HostHerdrWindowTarget
    private let invoke: @MainActor (String, Data) async throws -> Data
    private var retained = false
    private let validateOrigin: @MainActor () throws -> Void

    init(
        target: HostHerdrWindowTarget,
        invoke: @escaping @MainActor (String, Data) async throws -> Data,
        validateOrigin: @escaping @MainActor () throws -> Void
    ) {
        self.target = target; self.invoke = invoke; self.validateOrigin = validateOrigin
    }

    public func validate() async throws {
        try validateOrigin()
        try target.validate()
        let data = try await invoke("herdr.ui.read", Data("{}".utf8))
        try requireDescriptor(data, presented: target.presented)
        try validateOrigin()
        retained = true
    }

    public func admit() async throws {
        guard retained else { throw HostWorkerError.rejected }
        try validateOrigin()
        let data = try await call("admit")
        try requireDescriptor(data, presented: true)
        try validateOrigin()
    }

    public func focus(_ key: Bool) async throws {
        guard retained else { throw HostWorkerError.rejected }
        try validateOrigin()
        let data = try await call("focus", key: key)
        try requireDescriptor(data, presented: true)
        try validateOrigin()
    }

    public func close() async throws {
        guard retained else { return }
        let data = try await call("close")
        guard try descriptors(data).allSatisfy({ $0.token != target.token }) else {
            throw HostWorkerError.rejected
        }
    }

    private func call(_ action: String, key: Bool? = nil) async throws -> Data {
        var object: [String: Any] = ["token": target.token.uuidString]
        if let key { object["key"] = key }
        return try await invoke(
            "herdr.ui.presentation." + action,
            JSONSerialization.data(withJSONObject: object))
    }

    private func requireDescriptor(_ data: Data, presented: Bool) throws {
        let values = try descriptors(data)
        guard values.contains(where: { target.matches($0, presented: presented) }) else {
            throw HostWorkerError.rejected
        }
    }

    private func descriptors(_ data: Data) throws -> [HostHerdrWindowTarget] {
        guard data.count <= 8 * 1024 * 1024,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let values = object["presentations"] as? [[String: Any]], values.count <= 64
        else { throw HostWorkerError.rejected }
        let result = try values.map {
            try HostHerdrWindowTarget.decode(
                JSONSerialization.data(withJSONObject: $0))
        }
        guard Set(result.map(\.token)).count == result.count else { throw HostWorkerError.rejected }
        return result
    }
}
