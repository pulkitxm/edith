import Foundation

@testable import UsageExtension

extension UsageNativeArchive {
    func events() throws -> [UsageNativeEvent] {
        var result: [UsageNativeEvent] = []
        try database.forEachRow("SELECT path,identity,payload FROM records ORDER BY sequence") {
            row in
            let payload = UsageNativeDatabase.text(row, 2) ?? ""
            var event = try JSONDecoder().decode(UsageNativeEvent.self, from: Data(payload.utf8))
            if event.identity == nil {
                event.identity =
                    "anonymous:" + UsageNativeJSON.hash(UsageNativeDatabase.text(row, 0) ?? "")
                    + ":" + (UsageNativeDatabase.text(row, 1) ?? "") + ":"
                    + UsageNativeJSON.hash(payload)
            }
            result.append(event)
        }
        return result
    }
}
