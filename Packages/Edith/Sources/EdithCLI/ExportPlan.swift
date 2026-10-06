import Foundation

struct ExportPlan<Card: Equatable>: Equatable {
    let cards: [Card]
    let explicitFile: URL?
    let directory: URL
    let stamp: String

    init(cards: [Card], output: String?, workingDirectory: URL, now: Date) throws {
        let target =
            output.map {
                URL(
                    fileURLWithPath: NSString(string: $0).expandingTildeInPath,
                    relativeTo: workingDirectory
                ).standardizedFileURL
            } ?? workingDirectory
        let file = target.pathExtension.lowercased() == "png" ? target : nil
        if file != nil, cards.count != 1 {
            throw CLIFailure.usage(
                "a PNG output path can only be used when exporting one card",
                hint: "pass one --card value or use a directory with --output")
        }
        self.cards = cards
        explicitFile = file
        directory = file?.deletingLastPathComponent() ?? target
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        stamp = formatter.string(from: now)
    }
}
