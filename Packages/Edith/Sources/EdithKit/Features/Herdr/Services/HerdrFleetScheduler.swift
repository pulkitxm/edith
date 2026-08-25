import Foundation

enum HerdrFleetScheduler {
    static let defaultMaximumInFlight = 4

    static func map<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], maximumInFlight: Int = defaultMaximumInFlight,
        operation: @escaping @Sendable (Input) async -> Output
    ) async -> [Output] {
        guard !inputs.isEmpty else { return [] }
        let limit = max(1, min(maximumInFlight, inputs.count))
        return await withTaskGroup(of: (Int, Output).self) { group in
            var nextIndex = 0
            var completed: [(Int, Output)] = []
            completed.reserveCapacity(inputs.count)

            func submit(_ index: Int) {
                group.addTask { (index, await operation(inputs[index])) }
            }

            while nextIndex < limit {
                submit(nextIndex)
                nextIndex += 1
            }
            while let result = await group.next() {
                completed.append(result)
                if nextIndex < inputs.count {
                    submit(nextIndex)
                    nextIndex += 1
                }
            }
            return completed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func cycle<Input: Sendable>(
        _ inputs: [Input], maximumInFlight: Int = defaultMaximumInFlight,
        operation: @escaping @Sendable (Input) async -> Void
    ) async {
        guard !inputs.isEmpty else { return }
        let workerCount = max(1, min(maximumInFlight, inputs.count))
        let queue = HerdrFleetLeaseQueue(inputs)
        await withTaskGroup(of: Void.self) { group in
            for _ in inputs.prefix(workerCount) {
                group.addTask {
                    while !Task.isCancelled {
                        guard let lease = await queue.acquire() else {
                            await Task.yield()
                            continue
                        }
                        await operation(lease.value)
                        await queue.release(lease.index)
                    }
                }
            }
            await group.waitForAll()
        }
    }
}

private actor HerdrFleetLeaseQueue<Value: Sendable> {
    struct Lease: Sendable {
        let index: Int
        let value: Value
    }

    private let values: [Value]
    private var active: Set<Int> = []
    private var nextIndex = 0

    init(_ values: [Value]) {
        self.values = values
    }

    func acquire() -> Lease? {
        for offset in 0..<values.count {
            let index = (nextIndex + offset) % values.count
            guard !active.contains(index) else { continue }
            active.insert(index)
            nextIndex = (index + 1) % values.count
            return Lease(index: index, value: values[index])
        }
        return nil
    }

    func release(_ index: Int) {
        active.remove(index)
    }
}
