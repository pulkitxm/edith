import Foundation

public final class GhosttyExternalIO: @unchecked Sendable {
    private enum Event {
        case write(Data)
        case resize(UInt16, UInt16, UInt32, UInt32)
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private var bytes = 0
    private var scheduled = false
    private var active = true
    private var write: (@MainActor (Data) -> Void)?
    private var resize: (@MainActor (UInt16, UInt16, UInt32, UInt32) -> Void)?
    private var failure: (@MainActor () -> Void)?

    public init(
        write: @escaping @MainActor (Data) -> Void,
        resize: @escaping @MainActor (UInt16, UInt16, UInt32, UInt32) -> Void,
        failure: @escaping @MainActor () -> Void
    ) {
        self.write = write
        self.resize = resize
        self.failure = failure
    }

    public func invalidate() {
        lock.lock()
        active = false
        events.removeAll()
        bytes = 0
        write = nil
        resize = nil
        failure = nil
        lock.unlock()
    }

    func enqueue(bytes pointer: UnsafePointer<UInt8>?, count: Int) {
        guard count > 0, let pointer else { return }
        guard count <= 16_384 else { overflow(); return }
        enqueue(.write(Data(bytes: pointer, count: count)), size: count)
    }

    func enqueue(columns: UInt16, rows: UInt16, width: UInt32, height: UInt32) {
        guard columns > 0, rows > 0 else { return }
        enqueue(.resize(columns, rows, width, height), size: 0)
    }

    private func enqueue(_ event: Event, size: Int) {
        lock.lock()
        guard active else { lock.unlock(); return }
        guard bytes + size <= 262_144, events.count < 256 else {
            lock.unlock()
            overflow()
            return
        }
        events.append(event)
        bytes += size
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        if schedule {
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated { drain() }
            }
        }
    }

    private func overflow() {
        lock.lock()
        guard active else { lock.unlock(); return }
        let failure = self.failure
        active = false
        events.removeAll()
        bytes = 0
        write = nil
        resize = nil
        self.failure = nil
        lock.unlock()
        DispatchQueue.main.async { MainActor.assumeIsolated { failure?() } }
    }

    @MainActor private func drain() {
        lock.lock()
        let next = events
        events.removeAll()
        bytes = 0
        scheduled = false
        lock.unlock()
        for event in next {
            lock.lock()
            let write = active ? self.write : nil
            let resize = active ? self.resize : nil
            lock.unlock()
            switch event {
            case let .write(data): write?(data)
            case let .resize(columns, rows, width, height): resize?(columns, rows, width, height)
            }
        }
    }
}
