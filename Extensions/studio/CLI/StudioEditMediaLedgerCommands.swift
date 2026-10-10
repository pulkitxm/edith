import ArgumentParser
import EdithExtensionSupport
import EdithExtensionCommands
import Foundation

struct StudioMediaReserve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reserve",
        abstract:
            "Atomically reserve used original sources in a shared ledger; retain the entire JSON receipt.",
        discussion: """
            Atomically reserve used original sources in a shared ledger; retain the
            entire JSON receipt.

            Changes the state this command names.

            ed studio edit media reserve web --ledger ledger --reel reel
            """, )
    @Argument(help: "Source .openscreen project; it is not modified.") var project: String
    @Option(help: "Shared local .json ledger across every reel.") var ledger: String
    @Option(help: "Reservation owner ID, 1 to 1000 characters.") var reel: String
    @OptionGroup var options: StudioMediaReadOptions
    func run() async throws {
        try await StudioMediaBridge.run(json: options.json) {
            try await VideoEditorService.mediaReserve(
                StudioEditBridge.url(project), ledger: StudioEditBridge.url(ledger), reelID: reel)
        }
    }
}

struct StudioMediaReservations: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reservations",
        abstract: "List shared-ledger receipts in stable token order with bounded pagination.",
        discussion: """
            List shared-ledger receipts in stable token order with bounded pagination.

            Reads the current state. Does not change it.

            ed studio edit media reservations --ledger ledger
            """, )
    @Option(help: "Shared local .json ledger.") var ledger: String
    @Option(help: "Nonnegative receipt offset.") var offset = 0
    @Option(help: "Maximum receipts, 1 to 100.") var limit = 100
    @OptionGroup var options: StudioMediaReadOptions
    func run() async throws {
        try await StudioMediaBridge.run(json: options.json) {
            try await VideoEditorService.mediaReservations(
                StudioEditBridge.url(ledger), offset: offset, limit: limit)
        }
    }
}

struct StudioMediaRelease: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release",
        abstract: "Release only the exact successful reservation receipt from this ledger.",
        discussion: """
            Release only the exact successful reservation receipt from this ledger.

            Changes the state this command names.

            ed studio edit media release --ledger ledger --receipt receipt
            """, )
    @Option(help: "Shared local .json ledger.") var ledger: String
    @Option(help: "File containing the complete reserve JSON output, at most 1 MiB.") var receipt:
        String
    @OptionGroup var options: StudioMediaReadOptions
    func run() async throws {
        try await StudioMediaBridge.run(json: options.json) {
            try await VideoEditorService.mediaRelease(
                StudioEditBridge.url(ledger), receiptFile: StudioEditBridge.url(receipt))
        }
    }
}
