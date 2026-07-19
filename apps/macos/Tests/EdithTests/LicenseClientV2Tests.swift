import Foundation
import Testing

@testable import EdithKit

@Suite struct LicenseClientV2Tests {
    private let baseURL = URL(string: "https://license.test/api/v1")!

    @Test func activationChallengeSendsBodyAndDecodesResponse() async throws {
        let transport = StubV2Transport(
            statusCode: 200,
            body: #"{"challengeId":"ch-1","nonce":"n-1","expiresAt":"2026-07-19T00:05:00Z"}"#)
        let client = LicenseClient(transport: transport, baseURL: baseURL)

        let response = try await client.activationChallenge(
            licenseKey: "EDITH-ABCD-1234-EFGH-5678", deviceId: "device-1",
            devicePublicKey: "spki-b64url")

        #expect(
            response
                == LicenseChallengeResponse(
                    challengeId: "ch-1", nonce: "n-1", expiresAt: "2026-07-19T00:05:00Z"))
        let request = try #require(transport.request)
        #expect(
            request.url?.absoluteString == "https://license.test/api/v2/activation/challenge")
        let payload = try body(of: request)
        #expect(payload["licenseKey"] as? String == "EDITH-ABCD-1234-EFGH-5678")
        #expect(payload["deviceId"] as? String == "device-1")
        #expect(payload["devicePublicKey"] as? String == "spki-b64url")
    }

    @Test func activateV2SendsBodyAndDecodesResponse() async throws {
        let transport = StubV2Transport(statusCode: 200, body: Self.activationSuccessBody)
        let client = LicenseClient(transport: transport, baseURL: baseURL)

        let response = try await client.activateV2(
            licenseKey: "EDITH-ABCD-1234-EFGH-5678", challengeId: "ch-1", nonce: "n-1",
            deviceId: "device-1", devicePublicKey: "spki-b64url", signature: "sig-b64url",
            appVersion: "1.2.3", deviceName: "Test Mac")

        #expect(response.planId == "personal_3")
        #expect(response.machinesUsed == 1)
        #expect(response.maxMachines == 3)
        #expect(response.entitlement == "signed-entitlement")
        #expect(response.refreshCredential == "edithrc_abc")
        #expect(response.accessToken == "token.sig")
        let request = try #require(transport.request)
        #expect(request.url?.absoluteString == "https://license.test/api/v2/activation")
        let payload = try body(of: request)
        #expect(payload["challengeId"] as? String == "ch-1")
        #expect(payload["nonce"] as? String == "n-1")
        #expect(payload["signature"] as? String == "sig-b64url")
        #expect(payload["appVersion"] as? String == "1.2.3")
        #expect(payload["deviceName"] as? String == "Test Mac")
    }

    @Test func migrateV2SendsHardwareUuid() async throws {
        let transport = StubV2Transport(statusCode: 200, body: Self.activationSuccessBody)
        let client = LicenseClient(transport: transport, baseURL: baseURL)

        _ = try await client.migrateV2(
            licenseKey: "EDITH-ABCD-1234-EFGH-5678", hardwareUuid: "hardware-1",
            deviceId: "device-1", devicePublicKey: "spki-b64url", challengeId: "ch-1",
            nonce: "n-1", signature: "sig-b64url", appVersion: "1.2.3")

        let request = try #require(transport.request)
        #expect(request.url?.absoluteString == "https://license.test/api/v2/devices/migrate")
        let payload = try body(of: request)
        #expect(payload["hardwareUuid"] as? String == "hardware-1")
        #expect(payload["nonce"] as? String == "n-1")
        #expect(payload["deviceName"] == nil)
    }

    @Test func refreshChallengeSendsCredentialAndOptionalPurpose() async throws {
        let transport = StubV2Transport(
            statusCode: 200,
            body: #"{"challengeId":"ch-2","nonce":"n-2","expiresAt":"2026-07-19T00:05:00Z"}"#)
        let client = LicenseClient(transport: transport, baseURL: baseURL)

        _ = try await client.refreshChallenge(
            deviceId: "device-1", refreshCredential: "edithrc_abc", purpose: "deactivate")

        let request = try #require(transport.request)
        #expect(
            request.url?.absoluteString
                == "https://license.test/api/v2/devices/refresh/challenge")
        let payload = try body(of: request)
        #expect(payload["refreshCredential"] as? String == "edithrc_abc")
        #expect(payload["purpose"] as? String == "deactivate")
    }

    @Test func refreshV2DecodesRotatedCredentials() async throws {
        let transport = StubV2Transport(
            statusCode: 200,
            body: """
                {"ok":true,"entitlement":"signed-entitlement-2",
                "refreshCredential":"edithrc_def","accessToken":"token2.sig",
                "accessTokenExpiresAt":"2026-07-19T00:30:00Z"}
                """)
        let client = LicenseClient(transport: transport, baseURL: baseURL)

        let response = try await client.refreshV2(
            deviceId: "device-1", challengeId: "ch-2", nonce: "n-2",
            signature: "sig-b64url", appVersion: "1.2.3")

        #expect(response.entitlement == "signed-entitlement-2")
        #expect(response.refreshCredential == "edithrc_def")
        let request = try #require(transport.request)
        #expect(request.url?.absoluteString == "https://license.test/api/v2/devices/refresh")
        let payload = try body(of: request)
        #expect(payload["deviceId"] as? String == "device-1")
        #expect(payload["challengeId"] as? String == "ch-2")
        #expect(payload["nonce"] as? String == "n-2")
    }

    @Test func deactivateV2DecodesAcknowledgement() async throws {
        let transport = StubV2Transport(statusCode: 200, body: #"{"ok":true}"#)
        let client = LicenseClient(transport: transport, baseURL: baseURL)

        let response = try await client.deactivateV2(
            deviceId: "device-1", challengeId: "ch-3", nonce: "n-3", signature: "sig-b64url")

        #expect(response.ok)
        let request = try #require(transport.request)
        #expect(
            request.url?.absoluteString == "https://license.test/api/v2/devices/deactivate")
    }

    @Test func machineLimitErrorCarriesSeatCounts() async {
        let transport = StubV2Transport(
            statusCode: 403,
            body: #"{"error":"machine_limit_reached","machinesUsed":3,"maxMachines":3}"#)
        let client = LicenseClient(transport: transport, baseURL: baseURL)

        await #expect(
            throws: LicenseClientError.machineLimitReached(machinesUsed: 3, maxMachines: 3)
        ) {
            _ = try await client.activateV2(
                licenseKey: "key", challengeId: "ch-1", nonce: "n-1", deviceId: "device-1",
                devicePublicKey: "spki", signature: "sig", appVersion: "1.2.3")
        }
    }

    @Test func invalidCredentialsMapToInvalidKey() async {
        let transport = StubV2Transport(
            statusCode: 403, body: #"{"error":"invalid_credentials"}"#)
        let client = LicenseClient(transport: transport, baseURL: baseURL)

        await #expect(throws: LicenseClientError.invalidKey) {
            _ = try await client.activationChallenge(
                licenseKey: "key", deviceId: "device-1", devicePublicKey: "spki")
        }
    }

    @Test func genericAuthFailuresMapToInvalidKey() async {
        let transport = StubV2Transport(statusCode: 401, body: "{}")
        let client = LicenseClient(transport: transport, baseURL: baseURL)

        await #expect(throws: LicenseClientError.invalidKey) {
            _ = try await client.refreshV2(
                deviceId: "device-1", challengeId: "ch-2", nonce: "n-2", signature: "sig",
                appVersion: "1.2.3")
        }
    }

    @Test func serverErrorsSurfaceStatusCode() async {
        let transport = StubV2Transport(statusCode: 500, body: "{}")
        let client = LicenseClient(transport: transport, baseURL: baseURL)

        await #expect(throws: LicenseClientError.server(statusCode: 500)) {
            _ = try await client.deactivateV2(
                deviceId: "device-1", challengeId: "ch-3", nonce: "n-3", signature: "sig")
        }
    }

    @Test func malformedSuccessBodyMapsToInvalidResponse() async {
        let transport = StubV2Transport(statusCode: 200, body: #"{"unexpected":true}"#)
        let client = LicenseClient(transport: transport, baseURL: baseURL)

        await #expect(throws: LicenseClientError.invalidResponse) {
            _ = try await client.activationChallenge(
                licenseKey: "key", deviceId: "device-1", devicePublicKey: "spki")
        }
    }

    private static let activationSuccessBody = """
        {"ok":true,"planId":"personal_3","machinesUsed":1,"maxMachines":3,
        "entitlement":"signed-entitlement","refreshCredential":"edithrc_abc",
        "accessToken":"token.sig","accessTokenExpiresAt":"2026-07-19T00:30:00Z"}
        """

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class StubV2Transport: LicenseTransport {
    private let statusCode: Int
    private let responseData: Data
    private(set) var request: URLRequest?

    init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        responseData = Data(body.utf8)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (responseData, response)
    }
}
