import Darwin
import Foundation

@objc protocol EdithAgentXPC {
    func handshake(peerVersion: Int, reply: @escaping (Data?, String?) -> Void)
    func snapshot(topic: String, reply: @escaping (Data?, String?) -> Void)
    func subscribe(topic: String, reply: @escaping (String?) -> Void)
    func unsubscribe(topic: String, reply: @escaping (String?) -> Void)
    func perform(operation: String, payload: Data, reply: @escaping (Data?, String?) -> Void)
}

@objc protocol EdithAgentSubscriberXPC {
    func topicChanged(topic: String, payload: Data)
}

final class Reply: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var data: Data?
    var failure: String?
    func finish(_ data: Data?, _ failure: String?) {
        lock.lock()
        self.data = data
        self.failure = failure
        lock.unlock()
        semaphore.signal()
    }
}

final class Receiver: NSObject, EdithAgentSubscriberXPC {
    let lock = NSLock()
    var values: [Data] = []
    func topicChanged(topic: String, payload: Data) {
        lock.lock()
        values.append(payload)
        lock.unlock()
    }
    func snapshot() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

let arguments = CommandLine.arguments
let connection = NSXPCConnection(machServiceName: arguments[1])
connection.remoteObjectInterface = NSXPCInterface(with: EdithAgentXPC.self)
connection.exportedInterface = NSXPCInterface(with: EdithAgentSubscriberXPC.self)
let receiver = Receiver()
connection.exportedObject = receiver
connection.resume()

func request(_ body: (EdithAgentXPC, @escaping (Data?, String?) -> Void) -> Void) throws -> Data {
    let reply = Reply()
    let proxy = connection.remoteObjectProxyWithErrorHandler { reply.finish(nil, $0.localizedDescription) }
    guard let remote = proxy as? EdithAgentXPC else {
        throw NSError(domain: "Fixture", code: 1)
    }
    body(remote, reply.finish)
    guard reply.semaphore.wait(timeout: .now() + 15) == .success else {
        throw NSError(domain: "Fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "XPC reply timed out."])
    }
    if let failure = reply.failure {
        throw NSError(domain: "Fixture", code: 3, userInfo: [NSLocalizedDescriptionKey: failure])
    }
    return reply.data ?? Data()
}

do {
    _ = try request { $0.handshake(peerVersion: 1, reply: $1) }
    let result: Data
    if arguments[2] == "watch" {
        let message = try JSONSerialization.data(withJSONObject: ["channel": arguments[3], "body": ""])
        _ = try request { $0.perform(operation: "bus.subscribe", payload: message, reply: $1) }
        Thread.sleep(forTimeInterval: Double(arguments[4]) ?? 3)
        _ = try request { $0.perform(operation: "bus.unsubscribe", payload: message, reply: $1) }
        result = try JSONSerialization.data(withJSONObject: receiver.snapshot().map {
            try JSONSerialization.jsonObject(with: $0)
        })
    } else {
        let payload = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
        result = try request { $0.perform(operation: arguments[2], payload: payload, reply: $1) }
    }
    FileHandle.standardOutput.write(result)
    connection.invalidate()
} catch {
    FileHandle.standardError.write(Data(error.localizedDescription.utf8))
    connection.invalidate()
    exit(1)
}
