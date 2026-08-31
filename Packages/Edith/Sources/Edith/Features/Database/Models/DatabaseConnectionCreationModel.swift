import AppKit
import EdithDatabase
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

@MainActor
@Observable
final class DatabaseConnectionCreationModel: Identifiable {
    let id = UUID()
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
    var readOnlyPolicy = DatabaseReadOnlyPolicy.required
    var productionPolicy = DatabaseProductionPolicy.requireMutationPreview
    private(set) var phase = DatabaseConnectionCreationPhase.editing

    private let sender: any DatabaseBrokerCommandSending
    private let secretStore: any DatabaseSecretStore
    private let currentDate: @Sendable () -> Date
    private let connectionID = DatabaseConnectionID()
    private let reference = DatabaseSecretReference(identifier: UUID(), purpose: .password)
    private var testedDraft: DatabaseConnectionDraft?
    private var testedPassword: String?
    private var storedSecret = false
    private var didSave = false

    init(
        sender: any DatabaseBrokerCommandSending = DatabaseBrokerCommandClient(),
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
        product == .postgresql || product == .mongoDB
    }

    var databaseLabel: String {
        switch product {
        case .redis, .valkey: "Logical database"
        default: "Database"
        }
    }

    var usernameRequired: Bool {
        product == .postgresql || product == .mongoDB && !password.isEmpty
    }

    var canTest: Bool {
        phase != .testing && phase != .saving
    }

    var canSave: Bool {
        guard case .tested = phase,
            let testedDraft,
            let draft = try? makeDraft()
        else { return false }
        return testedDraft == draft && testedPassword == password
    }

    func selectProduct(_ nextProduct: DatabaseProduct) {
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

    func selectEnvironment(_ environment: DatabaseEnvironmentKind) {
        environmentKind = environment
        environmentLabel = environment.title
        if environment == .production {
            environmentProtection = .confirmationRequired
            readOnlyPolicy = .required
            productionPolicy = .prohibitMutations
        }
        invalidateTest()
    }

    func chooseSQLiteFile() {
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
        phase = .testing
        do {
            let draft = try makeDraft()
            try await synchronizeSecret(for: draft)
            let definition = try draft.definition(createdAt: currentDate())
            let response = try await sender.send(
                .connectionTest(DatabaseConnectionTestRequest(connection: definition)))
            guard case .connectionTest(let result) = response,
                result.status == .succeeded,
                let payload = result.payload
            else {
                throw DatabaseConnectionCreationError.brokerFailure(
                    response.connectionTestResult?.error?.message)
            }
            testedDraft = draft
            testedPassword = password
            let version = payload.productIdentity.version.map { " \($0.string)" } ?? ""
            phase = .tested(
                "Connected to \(payload.productIdentity.product.displayName)\(version) in \(payload.latencyMilliseconds) ms.")
        } catch {
            await discardSecret()
            testedDraft = nil
            testedPassword = nil
            phase = .failed(Self.message(for: error))
        }
    }

    func saveConnection() async -> DatabaseConnectionDefinition? {
        guard canSave else {
            phase = .failed("Test the current connection details before saving.")
            return nil
        }
        phase = .saving
        do {
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
            phase = .saved
            return payload.connection
        } catch {
            phase = .failed(Self.message(for: error))
            return nil
        }
    }

    func invalidateTest() {
        if case .testing = phase { return }
        if case .saving = phase { return }
        testedDraft = nil
        testedPassword = nil
        phase = .editing
    }

    func discardUnsavedCredential() async {
        guard !didSave else { return }
        await discardSecret()
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
        guard storedSecret else { return }
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
            message ?? "The database broker could not complete this request."
        }
    }
}
