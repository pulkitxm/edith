import EdithCore
import Foundation
import Testing

@testable import EdithKit

private let payload = """
    [
      {
        "id": 1,
        "login": "github-actions[bot]",
        "avatar_url": "https://avatars.githubusercontent.com/u/1?v=4",
        "html_url": "https://github.com/apps/github-actions",
        "contributions": 900
      },
      {
        "id": 2,
        "login": "someone",
        "avatar_url": "https://avatars.githubusercontent.com/u/2?v=4",
        "html_url": "https://github.com/someone",
        "contributions": 3
      },
      {
        "id": 3,
        "login": "builder",
        "avatar_url": "https://avatars.githubusercontent.com/u/3?v=4",
        "html_url": "https://github.com/builder",
        "contributions": 40
      }
    ]
    """

private final class CountingFileManager: FileManager, @unchecked Sendable {
    private(set) var contentReads = 0

    override func contents(atPath path: String) -> Data? {
        contentReads += 1
        return super.contents(atPath: path)
    }
}

private final class FailingContributorURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }

    override func stopLoading() {}
}

@Test func botsAreDroppedAndPeopleComeBackMostActiveFirst() throws {
    let people = try Contributors.people(from: Data(payload.utf8))
    #expect(people.map(\.login) == ["builder", "someone"])
    #expect(people.first?.profileURL.absoluteString == "https://github.com/builder")
}

@Test func aContributorSurvivesACacheRoundTrip() throws {
    let people = try Contributors.people(from: Data(payload.utf8))
    let encoded = try JSONEncoder().encode(people)
    let decoded = try JSONDecoder().decode([Contributor].self, from: encoded)
    #expect(decoded == people)
}

@Test func aMissingContributionCountDoesNotFailTheDecode() throws {
    let minimal = """
        [{
          "id": 4,
          "login": "quiet",
          "avatar_url": "https://avatars.githubusercontent.com/u/4?v=4",
          "html_url": "https://github.com/quiet"
        }]
        """
    let people = try Contributors.people(from: Data(minimal.utf8))
    #expect(people.count == 1)
    #expect(people[0].contributions == 0)
}

@Test func theCacheIsEmptyWhenNothingHasBeenWritten() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    let directories = AppDirectories(homeDirectory: directory)
    #expect(Contributors.cached(directories: directories).isEmpty)
}

@Test func anInvalidFreshCacheIsReadOnceBeforeNetworkFallback() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let directories = AppDirectories(homeDirectory: home)
    try directories.prepare()
    try Data("invalid".utf8).write(
        to: directories.cache.appendingPathComponent("contributors.json"))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FailingContributorURLProtocol.self]
    let fileManager = CountingFileManager()

    let people = await Contributors.load(
        directories: directories, fileManager: fileManager,
        session: URLSession(configuration: configuration))

    #expect(people.isEmpty)
    #expect(fileManager.contentReads == 1)
}
