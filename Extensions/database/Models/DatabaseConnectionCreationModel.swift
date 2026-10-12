import AppKit
import DatabaseCore
import Foundation
import Observation

enum DatabaseConnectionCreationPhase: Equatable {
    case editing
    case testing
    case tested(String)
    case saving
    case failed(String)
    case saved
}

enum DatabaseConnectionURLImportPhase: Equatable {
    case editing
    case applied
    case failed(String)
}

@MainActor
@Observable
final class DatabaseConnectionCreationModel: Identifiable {
    let id = UUID()
    var connectionURL = ""
    var displayName = ""
    var product = DatabaseProduct.postgresql
    var host = "127.0.0.1"
    var port = String(DatabaseConnectionDraft.defaultPort(for: .postgresql))
    var path = ""
    var username = ""
    var database = ""
    var authenticationDatabase = "admin"
    var password = ""
    var tlsEnabled = false
    var environmentKind = DatabaseEnvironmentKind.development
    var environmentLabel = "Development"
    var environmentProtection = DatabaseEnvironmentProtection.confirmationRequired
    var readOnlyPolicy = DatabaseReadOnlyPolicy.disabled
    var productionPolicy = DatabaseProductionPolicy.requireMutationPreview
    private(set) var savedConnection: DatabaseConnectionDefinition?
    private(set) var isDrained = false
    private(set) var phase = DatabaseConnectionCreationPhase.editing
    private(set) var urlImportPhase = DatabaseConnectionURLImportPhase.editing

    private let sender: any DatabaseBrokerCommandSending
    private let secretStore: any DatabaseSecretStore
    private let currentDate: @Sendable () -> Date
    private let connectionID = DatabaseConnectionID()
    private let reference = DatabaseSecretReference(identifier: UUID(), purpose: .password)
    private var testedDraft: DatabaseConnectionDraft?
    private var testedPassword: String?
    private var storedSecret = false
    private var didSave = false
    private let commandTasks = DatabaseTaskOwner()
    private var operationInProgress = false
    private var cleanupTask: Task<Void, Never>?

    init(
        sender: any DatabaseBrokerCommandSending = DatabaseWorkerClient(),
        secretStore: (any DatabaseSecretStore)? = nil,
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sender = sender
        self.secretStore = secretStore ?? (try! DatabaseKeychainSecretStore())
        self.currentDate = currentDate
    }

    var supportedProducts: [DatabaseProduct] {
        DatabaseConnectionDraft.supportedProducts
    }

    var usesNetwork: Bool {
        product != .sqlite
    }

    var supportsTLS: Bool {
        product == .postgresql || product == .mysql || product == .mariaDB
            || product == .mongoDB
            || product == .elasticsearch
            || product == .openSearch || product == .clickHouse
    }

    var databaseLabel: String {
        switch product {
        case .redis, .valkey: "Logical database"
        default: "Database"
        }
    }

    var usernameRequired: Bool {
        product == .postgresql || product == .mysql || product == .mariaDB
            || product == .clickHouse
            || (product == .mongoDB || product == .elasticsearch || product == .openSearch)
                && !password.isEmpty
    }

    var canTest: Bool {
        !commandTasks.closed && !didSave && !operationInProgress
            && phase != .testing && phase != .saving
    }

    var canApplyConnectionURL: Bool {
        canTest && !connectionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && phase != .testing
            && phase != .saving
    }

    var canSave: Bool {
        guard !commandTasks.closed, !didSave, !operationInProgress,
            case .tested = phase,
            let testedDraft,
            let draft = try? makeDraft()
        else { return false }
        return testedDraft == draft && testedPassword == password
    }

    func selectProduct(_ nextProduct: DatabaseProduct) {
        guard canTest else { return }
        product = nextProduct
        port = String(DatabaseConnectionDraft.defaultPort(for: nextProduct))
        if nextProduct == .sqlite {
            host = ""
            username = ""
            password = ""
            database = ""
            tlsEnabled = false
        } else if nextProduct == .redis || nextProduct == .valkey {
            database = "0"
            tlsEnabled = false
        } else {
            host = host.isEmpty ? "127.0.0.1" : host
            if database == "0" { database = "" }
        }
        invalidateTest()
    }

    func updateConnectionURL(_ value: String) {
        guard canTest else { return }
        connectionURL = value
        urlImportPhase = .editing
        invalidateTest()
    }

    func applyConnectionURL() {
        guard canTest else { return }
        do {
            let parsed = try DatabaseConnectionURLParser.parse(
                connectionURL,
                preferredProduct: product)
            product = parsed.product
            host = parsed.host
            port = String(parsed.port)
            path = parsed.path
            username = parsed.username
            password = parsed.password
            database = parsed.database
            authenticationDatabase = parsed.authenticationDatabase
            tlsEnabled = parsed.tlsEnabled
            if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displayName = parsed.suggestedName
            }
            connectionURL = ""
            urlImportPhase = .applied
            invalidateTest()
        } catch {
            urlImportPhase = .failed(Self.message(for: error))
        }
    }

    func selectEnvironment(_ environment: DatabaseEnvironmentKind) {
        guard canTest else { return }
        environmentKind = environment
        environmentLabel = environment.title
        if environment == .production {
            environmentProtection = .confirmationRequired
            readOnlyPolicy = .required
            productionPolicy = .prohibitMutations
        } else {
            environmentProtection = .confirmationRequired
            readOnlyPolicy = .disabled
            productionPolicy = .requireMutationPreview
        }
        invalidateTest()
    }

    func testAndSaveConnection(applyPendingURL: Bool) async -> DatabaseConnectionDefinition? {
        guard canTest else { return nil }
        if applyPendingURL, canApplyConnectionURL {
            applyConnectionURL()
            if case .failed = urlImportPhase { return nil }
        }
        if !canSave {
            await testConnection()
        }
        guard !Task.isCancelled, canSave else { return nil }
        return await saveConnection()
    }

    func chooseSQLiteFile() {
        guard canTest else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            path = panel.url?.path ?? path
            if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displayName = panel.url?.deletingPathExtension().lastPathComponent ?? displayName
            }
            invalidateTest()
        }
    }

    func testConnection() async {
        guard canTest else { return }
        operationInProgress = true
        defer { operationInProgress = false }
        _ = try? await commandTasks.perform {
            await self.performTestConnection()
        }
    }

    private func performTestConnection() async {
        phase = .testing
        do {
            let draft = try makeDraft()
            let testedPassword = password
            try await synchronizeSecret(for: draft)
            try Task.checkCancellation()
            let definition = try draft.definition(createdAt: currentDate())
            let response = try await sender.send(
                .connectionTest(DatabaseConnectionTestRequest(connection: definition)))
            try Task.checkCancellation()
            guard case .connectionTest(let result) = response,
                result.status == .succeeded,
                let payload = result.payload
            else {
                throw DatabaseConnectionCreationError.brokerFailure(
                    response.connectionTestResult?.error?.message)
            }
            testedDraft = draft
            self.testedPassword = testedPassword
            let version = payload.productIdentity.version.map { " \($0.string)" } ?? ""
            phase = .tested(
                "Connected to \(payload.productIdentity.product.displayName)\(version) in \(payload.latencyMilliseconds) ms."
            )
        } catch is CancellationError {
            await discardSecret()
            testedDraft = nil
            testedPassword = nil
            phase = .editing
        } catch {
            await discardSecret()
            testedDraft = nil
            testedPassword = nil
            phase = .failed(Self.message(for: error))
        }
    }

    func saveConnection() async -> DatabaseConnectionDefinition? {
        guard !commandTasks.closed, !didSave, !operationInProgress else { return nil }
        guard canSave else {
            phase = .failed("Test the current connection details before saving.")
            return nil
        }
        operationInProgress = true
        defer { operationInProgress = false }
        return try? await commandTasks.perform {
            await self.performSaveConnection()
        }
    }

    private func performSaveConnection() async -> DatabaseConnectionDefinition? {
        phase = .saving
        do {
            try Task.checkCancellation()
            let draft = try makeDraft()
            let definition = try draft.definition(createdAt: currentDate())
            let response = try await sender.send(
                .connectionSave(DatabaseConnectionSaveRequest(connection: definition)))
            guard case .connectionSave(let result) = response,
                result.status == .succeeded,
                let payload = result.payload
            else {
                throw DatabaseConnectionCreationError.brokerFailure(
                    response.connectionSaveResult?.error?.message)
            }
            didSave = true
            savedConnection = payload.connection
            phase = .saved
            return payload.connection
        } catch {
            phase = .failed(Self.message(for: error))
            return nil
        }
    }

    func invalidateTest() {
        guard !commandTasks.closed, !didSave else { return }
        if case .testing = phase { return }
        if case .saving = phase { return }
        testedDraft = nil
        testedPassword = nil
        phase = .editing
    }

    func cancelPendingCommands() {
        commandTasks.cancel()
    }

    func cancelAndWait() async {
        cancelPendingCommands()
        if cleanupTask == nil {
            cleanupTask = Task {
                await commandTasks.drain()
                if !didSave { await discardSecret() }
                isDrained = true
            }
        }
        await cleanupTask?.value
    }

    func discardUnsavedCredential() async {
        await cancelAndWait()
    }

    private func makeDraft() throws -> DatabaseConnectionDraft {
        guard let parsedPort = Int(port) else {
            throw DatabaseBoundedValueError.port(0)
        }
        return DatabaseConnectionDraft(
            id: connectionID,
            displayName: displayName,
            product: product,
            host: host,
            port: parsedPort,
            path: path,
            username: username,
            database: database,
            authenticationDatabase: authenticationDatabase,
            passwordReference: password.isEmpty ? nil : reference,
            tlsMode: tlsEnabled ? .required : .disabled,
            environmentKind: environmentKind,
            environmentLabel: environmentLabel,
            environmentProtection: environmentProtection,
            readOnlyPolicy: readOnlyPolicy,
            productionPolicy: productionPolicy)
    }

    private func synchronizeSecret(for draft: DatabaseConnectionDraft) async throws {
        guard draft.passwordReference != nil else {
            await discardSecret()
            return
        }
        try await secretStore.store(Data(password.utf8), for: reference)
        storedSecret = true
    }

    private func discardSecret() async {
        guard storedSecret, !didSave else { return }
        try? await secretStore.delete(reference)
        storedSecret = false
    }

    private static func message(for error: Error) -> String {
        if let error = error as? LocalizedError, let detail = error.errorDescription {
            return detail
        }
        if case let DatabaseBoundedValueError.port(value) = error {
            return "Port \(value) is outside the valid range from 1 through 65535."
        }
        return "The database connection could not be completed."
    }
}

private enum DatabaseConnectionCreationError: LocalizedError {
    case brokerFailure(String?)

    var errorDescription: String? {
        switch self {
        case let .brokerFailure(message):
            message ?? "The database service could not complete this request."
        }
    }
}
