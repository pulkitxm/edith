import Foundation
import MongoClient
import MongoCore
import MongoKitten
import Testing

@testable import EdithDatabase

private struct MongoDBDatabaseFoundationUnknownFailure: Error {}

private enum MongoDBDatabaseFoundationFixtures {
    static let objectIDs = [
        ObjectId("64b7abdecf2160b649ab6085")!,
        ObjectId("64b7abdecf2160b649ab6086")!,
        ObjectId("64b7abdecf2160b649ab6087")!,
    ]

    static func document(index: Int) -> Document {
        var document = Document()
        document["_id"] = objectIDs[index]
        document["sequence"] = Int32(index)
        document["name"] = "event-\(index)"
        return document
    }

    static func binary(_ data: Data, subtype: Binary.SubType = .generic) -> Binary {
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return Binary(subType: subtype, buffer: buffer)
    }

    static func genericError(code: Int) throws -> MongoGenericErrorReply {
        try JSONDecoder().decode(
            MongoGenericErrorReply.self,
            from: Data("{\"ok\":0,\"errmsg\":\"fixture\",\"code\":\(code)}".utf8))
    }
}

@Test func mongoFoundationConnectionPlanRetainsTypedSettings() {
    let settings = ConnectionSettings(
        authentication: .auto(username: "reader", password: "fixture-password"),
        authenticationSource: "edith_scale",
        hosts: [ConnectionSettings.Host(hostname: "127.0.0.1", port: 57_017)],
        targetDatabase: "edith_scale",
        useSSL: true,
        verifySSLCertificates: true,
        maximumNumberOfConnections: 4,
        connectTimeout: 2,
        socketTimeout: 3,
        applicationName: "Edith")
    let plan = MongoDBDatabaseConnectionPlan(settings: settings)
    #expect(plan.settings.hosts.count == 1)
    #expect(plan.settings.hosts[0].hostname == "127.0.0.1")
    #expect(plan.settings.hosts[0].port == 57_017)
    #expect(plan.settings.authenticationSource == "edith_scale")
    #expect(plan.settings.targetDatabase == "edith_scale")
    #expect(plan.settings.useSSL)
    #expect(plan.settings.verifySSLCertificates)
    #expect(plan.settings.maximumNumberOfConnections == 4)
    #expect(plan.settings.connectTimeout == 2)
    #expect(plan.settings.socketTimeout == 3)
    #expect(plan.settings.applicationName == "Edith")
    guard case let .auto(username, password) = plan.settings.authentication else {
        Issue.record("Expected automatic SCRAM authentication")
        return
    }
    #expect(username == "reader")
    #expect(password == "fixture-password")
}

@Test func mongoFoundationReadPlanRetainsBoundedCommandInputs() {
    let projection: Document = ["name": 1, "_id": 1]
    let filter: Document = ["sequence": ["$gte": 10]]
    let sort: Document = ["_id": 1]
    let plan = MongoDBDatabaseReadPlan(
        database: "edith_scale",
        collection: "events",
        filter: filter,
        projection: projection,
        sort: sort,
        limit: 101,
        batchSize: 64,
        maximumTimeMilliseconds: 2_000)
    #expect(plan.database == "edith_scale")
    #expect(plan.collection == "events")
    #expect(plan.filter == filter)
    #expect(plan.projection == projection)
    #expect(plan.sort == sort)
    #expect(plan.limit == 101)
    #expect(plan.batchSize == 64)
    #expect(plan.maximumTimeMilliseconds == 2_000)
}

@Test func mongoFoundationBSONConversionIsDeterministicAndBounded() throws {
    var document = Document()
    document["_id"] = MongoDBDatabaseFoundationFixtures.objectIDs[0]
    document["null"] = Null()
    document["bool"] = true
    document["int32"] = Int32(7)
    document["int64"] = Int(9)
    document["double"] = 1.25
    document["date"] = Date(timeIntervalSince1970: 1_700_000_000.125)
    document["binary"] = MongoDBDatabaseFoundationFixtures.binary(
        Data(repeating: 7, count: 20_000))
    document["regex"] = RegularExpression(pattern: "^a", options: "i")
    document["timestamp"] = Timestamp(increment: 2, timestamp: 10)
    document["min"] = MinKey()
    document["max"] = MaxKey()
    document["long"] = String(repeating: "é", count: 10_000)
    let first = try MongoDBDatabaseValueCodec.convertedRecord(
        document,
        hidesObjectID: false)
    let second = try MongoDBDatabaseValueCodec.convertedRecord(
        document,
        hidesObjectID: false)
    #expect(first.record == second.record)
    #expect(first.objectID == MongoDBDatabaseFoundationFixtures.objectIDs[0])
    #expect(first.truncated)
    #expect(first.record.metadata == [
        DatabaseStringAttribute(name: "mongodb.truncated", value: "true")
    ])
    guard case let .binary(binary) = first.record.fields.first(where: {
        $0.name == "binary"
    })?.value else {
        Issue.record("Expected binary preview")
        return
    }
    #expect(!binary.isComplete)
    #expect(binary.byteCount == 20_000)
    guard case let .productSpecific(preview) = first.record.fields.first(where: {
        $0.name == "long"
    })?.value else {
        Issue.record("Expected string preview")
        return
    }
    #expect(preview.typeName == "stringPreview")
    #expect(preview.textRepresentation?.utf8.count ?? 0 <= 8_192)
}

@Test func mongoFoundationAccumulatorSaturatesAndMarksWithinBatchCutoff() {
    let first = MongoDBDatabaseFoundationFixtures.document(index: 0)
    var second = MongoDBDatabaseFoundationFixtures.document(index: 1)
    second["payload"] = String(repeating: "x", count: 2_048)
    let third = MongoDBDatabaseFoundationFixtures.document(index: 2)
    let retainedLimit = first.makeData().count + second.makeData().count - 1
    var accumulator = MongoDBDatabaseReadAccumulator(
        limit: 10,
        retainedByteLimit: retainedLimit)
    let stopped = accumulator.append([first, second, third], cursorHasMore: false)
    #expect(stopped)
    #expect(accumulator.documents.count == 1)
    #expect(accumulator.hasMore)
    #expect(
        accumulator.bytesReceived
            == UInt64(first.makeData().count + second.makeData().count + third.makeData().count))
    #expect(MongoDBDatabaseReadAccumulator.saturatingAdd(UInt64.max - 2, 10) == UInt64.max)
}

@Test func mongoFoundationAccumulatorHasExactLimitBoundary() {
    let documents = [
        MongoDBDatabaseFoundationFixtures.document(index: 0),
        MongoDBDatabaseFoundationFixtures.document(index: 1),
    ]
    var exact = MongoDBDatabaseReadAccumulator(limit: 2, retainedByteLimit: 10_000)
    let exactStopped = exact.append(documents, cursorHasMore: false)
    #expect(exactStopped)
    #expect(!exact.hasMore)
    var additional = MongoDBDatabaseReadAccumulator(limit: 1, retainedByteLimit: 10_000)
    let additionalStopped = additional.append(documents, cursorHasMore: false)
    #expect(additionalStopped)
    #expect(additional.hasMore)
}

@Test func mongoFoundationDriverErrorsAreClassifiedWithoutLosingCancellation() throws {
    #expect(
        try MongoDBDatabaseDriverErrorClassifier.classify(
            MongoError(.authenticationFailure, reason: nil)) == .authentication)
    #expect(
        try MongoDBDatabaseDriverErrorClassifier.classify(
            MongoError(.queryTimeout, reason: nil)) == .timeout)
    #expect(
        try MongoDBDatabaseDriverErrorClassifier.classify(
            MongoError(.cannotConnect, reason: nil)) == .connection)
    #expect(
        try MongoDBDatabaseDriverErrorClassifier.classify(
            MongoDBDatabaseFoundationFixtures.genericError(code: 13)) == .permission(13))
    #expect(
        try MongoDBDatabaseDriverErrorClassifier.classify(
            MongoDBDatabaseFoundationFixtures.genericError(code: 18)) == .authentication)
    #expect(
        try MongoDBDatabaseDriverErrorClassifier.classify(
            MongoDBDatabaseFoundationFixtures.genericError(code: 50)) == .timeout)
    #expect(
        try MongoDBDatabaseDriverErrorClassifier.classify(
            MongoDBDatabaseFoundationFixtures.genericError(code: 91)) == .server(91))
    #expect(
        try MongoDBDatabaseDriverErrorClassifier.classify(
            MongoDBDatabaseFoundationUnknownFailure()) == .connection)
    #expect(throws: CancellationError.self) {
        _ = try MongoDBDatabaseDriverErrorClassifier.classify(CancellationError())
    }
}
