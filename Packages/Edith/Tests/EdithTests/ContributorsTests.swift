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
    let directories = AppDirectories(platform: .macOS, homeDirectory: directory)
    #expect(Contributors.cached(directories: directories).isEmpty)
}
