import Darwin
import EdithCore
import Foundation

public enum DatabaseBrokerProcess {
    public static func run() async -> Int32 {
        await DatabaseBrokerProcessRunner(
            dependencies: .live()
        ).run()
    }
}

struct DatabaseBrokerProcessRuntime: Sendable {
    private let startHandler: @Sendable () async throws -> Void
    private let shutdownHandler: @Sendable () async -> Void
    private let waitUntilStoppedHandler: @Sendable () async -> Void
    private let shutdownReasonHandler: @Sendable () async -> DatabaseBrokerRuntimeShutdownReason?

    init(
        start: @escaping @Sendable () async throws -> Void,
        shutdown: @escaping @Sendable () async -> Void,
        waitUntilStopped: @escaping @Sendable () async -> Void,
        shutdownReason:
            @escaping @Sendable () async -> DatabaseBrokerRuntimeShutdownReason?
    ) {
        startHandler = start
        shutdownHandler = shutdown
        waitUntilStoppedHandler = waitUntilStopped
        shutdownReasonHandler = shutdownReason
    }

    func start() async throws {
        try await startHandler()
    }

    func shutdown() async {
        await shutdownHandler()
    }

    func waitUntilStopped() async {
        await waitUntilStoppedHandler()
    }

    func shutdownReason() async -> DatabaseBrokerRuntimeShutdownReason? {
        await shutdownReasonHandler()
    }

    static func live(
        paths: DatabaseBrokerPaths,
        observeShutdownRequest:
            @escaping @Sendable (DatabaseBrokerRuntimeShutdownReason) -> Void
    ) -> DatabaseBrokerProcessRuntime {
        let controller = DatabaseBrokerLiveProcessRuntimeController(
            paths: paths,
            observeShutdownRequest: observeShutdownRequest)
        return DatabaseBrokerProcessRuntime(
            start: {
                try await controller.start()
            },
            shutdown: {
                await controller.shutdown()
            },
            waitUntilStopped: {
                await controller.waitUntilStopped()
            },
            shutdownReason: {
                await controller.shutdownReason()
            })
    }
}

private actor DatabaseBrokerLiveProcessRuntimeController {
    private struct Resources: Sendable {
        let id: UUID
        let runtime: DatabaseBrokerRuntime
        let metadataStore: SQLiteDatabaseMetadataStore
        let executor: DatabaseExecutor
        let owner: DatabaseRuntimeOwnerToken
    }

    private let paths: DatabaseBrokerPaths
    private let observeShutdownRequest: @Sendable (DatabaseBrokerRuntimeShutdownReason) -> Void
    private var resources: Resources?
    private var lastShutdownReason: DatabaseBrokerRuntimeShutdownReason?

    init(
        paths: DatabaseBrokerPaths,
        observeShutdownRequest:
            @escaping @Sendable (DatabaseBrokerRuntimeShutdownReason) -> Void
    ) {
        self.paths = paths
        self.observeShutdownRequest = observeShutdownRequest
    }

    func start() async throws {
        guard resources == nil else {
            throw DatabaseBrokerRuntimeError.invalidPhase
        }
        let metadataStore = try SQLiteDatabaseMetadataStore(
            path: paths.metadataFile.path)
        let secretStore = try DatabaseKeychainSecretStore()
        let claim = try await DatabaseRuntimeOwnerFactory.claimReadyOwner(
            from: metadataStore,
            claimedAt: Date())
        let owner = claim.owner.token
        let executor: DatabaseExecutor
        let dispatcher: DatabaseBrokerCommandDispatcher
        do {
            executor = try DatabaseExecutor(
                metadataStore: metadataStore,
                secretStore: secretStore,
                runtimeOwner: owner,
                adapters: DatabaseBrokerLiveAdapterFactory.make())
            dispatcher = try DatabaseBrokerCommandDispatcher(
                handler: DatabaseBrokerExecutorHandler(executor: executor))
        } catch {
            _ = try? await metadataStore.releaseRuntimeOwner(
                owner,
                releasedAt: Date())
            throw error
        }
        let liveDependencies = DatabaseBrokerRuntimeDependencies.live(
            commandDispatcher: dispatcher)
        let runtime = DatabaseBrokerRuntime(
            paths: paths,
            dependencies: DatabaseBrokerRuntimeDependencies(
                acquireOwnership: liveDependencies.acquireOwnership,
                makeTransport: liveDependencies.makeTransport,
                makeAcceptSource: liveDependencies.makeAcceptSource,
                observeShutdownRequest: observeShutdownRequest))
        let resources = Resources(
            id: UUID(),
            runtime: runtime,
            metadataStore: metadataStore,
            executor: executor,
            owner: owner)
        self.resources = resources
        do {
            try await runtime.start()
        } catch {
            if self.resources?.id == resources.id {
                self.resources = nil
                await cleanup(resources)
            }
            throw error
        }
    }

    func shutdown() async {
        guard let resources else { return }
        self.resources = nil
        await resources.runtime.shutdown()
        await cleanup(resources)
    }

    func waitUntilStopped() async {
        guard let resources else { return }
        await resources.runtime.waitUntilStopped()
        guard self.resources?.id == resources.id else { return }
        self.resources = nil
        await cleanup(resources)
    }

    func shutdownReason() async -> DatabaseBrokerRuntimeShutdownReason? {
        if let resources {
            return await resources.runtime.snapshot().shutdownReason
        }
        return lastShutdownReason
    }

    private func cleanup(_ resources: Resources) async {
        lastShutdownReason = await resources.runtime.snapshot().shutdownReason
        await resources.executor.disconnectAll()
        _ = try? await resources.metadataStore.releaseRuntimeOwner(
            resources.owner,
            releasedAt: Date())
    }
}

enum DatabaseBrokerLiveAdapterFactory {
    static func make() -> [any DatabaseAdapter] {
        [
            SQLiteDatabaseAdapter(),
            RedisValkeyDatabaseAdapter(),
            MongoDBDatabaseAdapter(),
            ElasticsearchDatabaseAdapter(),
            OpenSearchDatabaseAdapter(),
            ClickHouseDatabaseAdapter(),
            MySQLDatabaseAdapter(),
            PostgreSQLDatabaseAdapter(),
        ]
    }
}

struct DatabaseBrokerProcessLifecycle: Sendable {
    private let firstShutdownRequestHandler: @Sendable () -> DatabaseBrokerShutdownRequest?
    private let requestShutdownHandler: @Sendable (DatabaseBrokerShutdownRequest) -> Bool
    private let disarmWatchdogHandler: @Sendable () -> Bool
    private let cleanupHandler: @Sendable () -> Bool

    init(
        firstShutdownRequest:
            @escaping @Sendable () -> DatabaseBrokerShutdownRequest?,
        requestShutdown:
            @escaping @Sendable (DatabaseBrokerShutdownRequest) -> Bool,
        disarmWatchdog: @escaping @Sendable () -> Bool,
        cleanup: @escaping @Sendable () -> Bool
    ) {
        firstShutdownRequestHandler = firstShutdownRequest
        requestShutdownHandler = requestShutdown
        disarmWatchdogHandler = disarmWatchdog
        cleanupHandler = cleanup
    }

    var firstShutdownRequest: DatabaseBrokerShutdownRequest? {
        firstShutdownRequestHandler()
    }

    @discardableResult
    func requestShutdown(
        _ request: DatabaseBrokerShutdownRequest
    ) -> Bool {
        requestShutdownHandler(request)
    }

    @discardableResult
    func disarmWatchdog() -> Bool {
        disarmWatchdogHandler()
    }

    @discardableResult
    func cleanup() -> Bool {
        cleanupHandler()
    }

    static func activate(
        onShutdownRequest:
            @escaping @Sendable (DatabaseBrokerShutdownRequest) -> Void
    ) throws -> DatabaseBrokerProcessLifecycle {
        let lifecycle = try DatabaseBrokerLifecycle.activate(
            onShutdownRequest: onShutdownRequest)
        return DatabaseBrokerProcessLifecycle(
            firstShutdownRequest: {
                lifecycle.firstShutdownRequest
            },
            requestShutdown: { request in
                lifecycle.requestShutdown(request)
            },
            disarmWatchdog: {
                lifecycle.disarmWatchdog()
            },
            cleanup: {
                lifecycle.cleanup()
            })
    }
}

struct DatabaseBrokerProcessDependencies: Sendable {
    let setRestrictiveFileCreationMask: @Sendable () -> Void
    let makeAppDirectories: @Sendable () -> AppDirectories
    let makePaths: @Sendable (AppDirectories) -> DatabaseBrokerPaths
    let makeRuntime:
        @Sendable (
            DatabaseBrokerPaths,
            @escaping @Sendable (DatabaseBrokerRuntimeShutdownReason) -> Void
        ) -> DatabaseBrokerProcessRuntime
    let activateLifecycle:
        @Sendable (
            @escaping @Sendable (DatabaseBrokerShutdownRequest) -> Void
        ) throws -> DatabaseBrokerProcessLifecycle
    let prepareAppDirectories: @Sendable (AppDirectories) throws -> Void
    let preparePaths: @Sendable (DatabaseBrokerPaths) throws -> Void

    static func live() -> DatabaseBrokerProcessDependencies {
        DatabaseBrokerProcessDependencies(
            setRestrictiveFileCreationMask: {
                _ = Darwin.umask(mode_t(0o077))
            },
            makeAppDirectories: {
                AppDirectories.current
            },
            makePaths: { directories in
                DatabaseBrokerPaths(directories: directories)
            },
            makeRuntime: { paths, observeShutdownRequest in
                DatabaseBrokerProcessRuntime.live(
                    paths: paths,
                    observeShutdownRequest: observeShutdownRequest)
            },
            activateLifecycle: { onShutdownRequest in
                try DatabaseBrokerProcessLifecycle.activate(
                    onShutdownRequest: onShutdownRequest)
            },
            prepareAppDirectories: { directories in
                try directories.prepare()
            },
            preparePaths: { paths in
                try paths.prepare()
            })
    }
}

struct DatabaseBrokerProcessRunner: Sendable {
    private let dependencies: DatabaseBrokerProcessDependencies

    init(dependencies: DatabaseBrokerProcessDependencies) {
        self.dependencies = dependencies
    }

    func run() async -> Int32 {
        dependencies.setRestrictiveFileCreationMask()
        let appDirectories = dependencies.makeAppDirectories()
        let paths = dependencies.makePaths(appDirectories)
        let shutdownRelay = DatabaseBrokerProcessShutdownRelay()
        let runtime = dependencies.makeRuntime(paths) { reason in
            shutdownRelay.runtimeRequestedShutdown(reason)
        }
        shutdownRelay.bind(runtime: runtime)

        let lifecycle: DatabaseBrokerProcessLifecycle
        do {
            lifecycle = try dependencies.activateLifecycle { request in
                shutdownRelay.lifecycleRequestedShutdown(request)
            }
        } catch {
            await stop(runtime)
            shutdownRelay.clear()
            return EXIT_FAILURE
        }
        shutdownRelay.bind(lifecycle: lifecycle)

        let exitCode: Int32
        do {
            try dependencies.prepareAppDirectories(appDirectories)
            if lifecycle.firstShutdownRequest != nil {
                await stop(runtime)
                exitCode = EXIT_SUCCESS
            } else {
                try dependencies.preparePaths(paths)
                if lifecycle.firstShutdownRequest != nil {
                    await stop(runtime)
                    exitCode = EXIT_SUCCESS
                } else {
                    exitCode = await startAndWait(runtime: runtime)
                }
            }
        } catch {
            let shutdownWasRequested = lifecycle.firstShutdownRequest != nil
            await stop(runtime)
            exitCode = shutdownWasRequested ? EXIT_SUCCESS : EXIT_FAILURE
        }

        _ = lifecycle.disarmWatchdog()
        _ = lifecycle.cleanup()
        shutdownRelay.clear()
        return exitCode
    }

    private func startAndWait(
        runtime: DatabaseBrokerProcessRuntime
    ) async -> Int32 {
        do {
            try await runtime.start()
        } catch DatabaseBrokerSocketError.listenerAlreadyRunning {
            await stop(runtime)
            return EXIT_SUCCESS
        } catch {
            await stop(runtime)
            return await classifyStoppedRuntime(runtime)
        }

        await runtime.waitUntilStopped()
        return await classifyStoppedRuntime(runtime)
    }

    private func classifyStoppedRuntime(
        _ runtime: DatabaseBrokerProcessRuntime
    ) async -> Int32 {
        switch await runtime.shutdownReason() {
        case .requested, .peerVersionMismatch:
            return EXIT_SUCCESS
        case .startupFailure, .acceptFailure:
            return EXIT_FAILURE
        case nil:
            return EXIT_FAILURE
        }
    }

    private func stop(_ runtime: DatabaseBrokerProcessRuntime) async {
        await runtime.shutdown()
        await runtime.waitUntilStopped()
    }
}

private final class DatabaseBrokerProcessShutdownRelay: @unchecked Sendable {
    private struct State {
        var runtime: DatabaseBrokerProcessRuntime?
        var lifecycle: DatabaseBrokerProcessLifecycle?
        var shouldShutdownRuntimeWhenBound = false
        var shouldRequestLifecycleWhenBound = false
        var isCleared = false
    }

    private let stateLock = NSLock()
    private var state = State()

    func bind(runtime: DatabaseBrokerProcessRuntime) {
        let shouldShutdown = stateLock.withLock { () -> Bool in
            guard !state.isCleared else { return false }
            state.runtime = runtime
            let shouldShutdown = state.shouldShutdownRuntimeWhenBound
            state.shouldShutdownRuntimeWhenBound = false
            return shouldShutdown
        }
        if shouldShutdown {
            Task {
                await runtime.shutdown()
            }
        }
    }

    func bind(lifecycle: DatabaseBrokerProcessLifecycle) {
        let shouldRequestShutdown = stateLock.withLock { () -> Bool in
            guard !state.isCleared else { return false }
            state.lifecycle = lifecycle
            let shouldRequestShutdown = state.shouldRequestLifecycleWhenBound
            state.shouldRequestLifecycleWhenBound = false
            return shouldRequestShutdown
        }
        if shouldRequestShutdown {
            lifecycle.requestShutdown(.requested)
        }
    }

    func lifecycleRequestedShutdown(
        _: DatabaseBrokerShutdownRequest
    ) {
        let runtime = stateLock.withLock { () -> DatabaseBrokerProcessRuntime? in
            guard !state.isCleared else { return nil }
            guard let runtime = state.runtime else {
                state.shouldShutdownRuntimeWhenBound = true
                return nil
            }
            return runtime
        }
        guard let runtime else { return }
        Task {
            await runtime.shutdown()
        }
    }

    func runtimeRequestedShutdown(
        _: DatabaseBrokerRuntimeShutdownReason
    ) {
        let lifecycle = stateLock.withLock { () -> DatabaseBrokerProcessLifecycle? in
            guard !state.isCleared else { return nil }
            guard let lifecycle = state.lifecycle else {
                state.shouldRequestLifecycleWhenBound = true
                return nil
            }
            return lifecycle
        }
        lifecycle?.requestShutdown(.requested)
    }

    func clear() {
        stateLock.withLock {
            state.runtime = nil
            state.lifecycle = nil
            state.shouldShutdownRuntimeWhenBound = false
            state.shouldRequestLifecycleWhenBound = false
            state.isCleared = true
        }
    }
}
