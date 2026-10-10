import Foundation
import MCP

actor DatabaseMCPCommandLifetime {
    private var tasks: [UUID: Task<CallTool.Result, Never>] = [:]
    private var stopping = false

    func run(_ operation: @escaping @Sendable () async -> CallTool.Result) async -> CallTool.Result
    {
        guard !stopping, tasks.count < 32, !Task.isCancelled else {
            return CallTool.Result(
                content: [.text("The owned database tool session is unavailable.")],
                isError: true)
        }
        let id = UUID()
        let task = Task { await operation() }
        tasks[id] = task
        defer { tasks.removeValue(forKey: id) }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func shutdownAndWait() async {
        stopping = true
        let owned = Array(tasks.values)
        for task in owned { task.cancel() }
        for task in owned { _ = await task.value }
    }
}
