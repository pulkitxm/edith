import Foundation
import Testing

@testable import EdithDocsWorker

@Suite struct DocsAskQuestionTests {
    static let answered: [(String, String)] = [
        ("merge two pdfs", "ed studio run"),
        ("compress a pdf", "ed studio run"),
        ("split a pdf into separate pages", "ed studio run"),
        ("convert a pdf to word", "ed studio run"),
        ("make a scanned pdf searchable", "ed studio run"),
        ("convert heic photos to jpg", "ed studio run"),
        ("resize an image", "ed studio run"),
        ("strip gps location from photos", "ed studio run"),
        ("compress a video", "ed studio run"),
        ("turn a video into a gif", "ed studio run"),
        ("extract the audio from a video", "ed studio run"),
        ("trim a video", "ed studio run"),
        ("convert wav to mp3", "ed studio run"),
        ("remove silence from a recording", "ed studio run"),
        ("transcribe a podcast", "ed studio run"),
        ("zip a folder", "ed studio run"),
        ("list studio tools for pdf files", "ed studio tools"),
        ("what settings does a studio tool take", "ed studio info"),
        ("record my screen", "ed studio record start"),
        ("stop the screen recording", "ed studio record stop"),
        ("squash merge the pull request for my latex project", "ed latex merge"),
        ("compile my latex document", "ed latex compile"),
        ("list quinjet worktrees for a project", "ed quinjet worktrees"),
        ("add a new server", "ed machines add"),
        ("reboot a server", "ed machines power reboot"),
        ("wake a machine with wake on lan", "ed machines power wake"),
        ("upload a file to a server", "ed machines files put"),
        ("download a file from a server", "ed machines files get"),
        ("show docker containers on a server", "ed machines docker ps"),
        ("prune unused docker images on a machine", "ed machines docker prune"),
        ("restart a systemd service", "ed machines services restart"),
        ("forward a port from a machine", "ed machines forwards add"),
        ("mount a server filesystem on my mac", "ed machines mount"),
        ("show my rate limits", "ed usage limits"),
        ("token usage per model", "ed usage models"),
        ("daily cost of coding agents", "ed usage daily"),
        ("collect usage from a remote machine", "ed usage machines collect"),
        ("clean developer caches", "ed cleaner clean"),
        ("install a homebrew package", "ed brew install"),
        ("upgrade homebrew packages", "ed brew upgrade"),
        ("search homebrew for a formula", "ed brew search"),
        ("uninstall a homebrew cask", "ed brew uninstall"),
        ("snooze an app update", "ed maintenance snooze"),
        ("skip this song", "ed music next"),
        ("pause the music", "ed music pause"),
        ("set the music volume to half", "ed music volume"),
        ("shuffle my music library", "ed music shuffle"),
        ("show clipboard history", "ed clipboard ls"),
        ("clear the clipboard history", "ed clipboard clear"),
        ("retry a failed download", "ed download retry"),
        ("run a sql query", "ed database query"),
        ("add a postgres connection", "ed database connections add"),
        ("export my settings to another mac", "ed config export"),
        ("join my next meeting", "ed calendar join"),
        ("show my calendar events", "ed calendar ls"),
        ("request screen recording permission", "ed permissions request"),
        ("how full are my disks", "ed system disks"),
        ("quit a running app", "ed apps quit"),
        ("pick a color from the screen", "ed color pick"),
        ("insert an emoji", "ed emoji insert"),
        ("put a file on the notch shelf", "ed shelf add"),
        ("turn on the virtual camera", "ed camera on"),
        ("start a site audit", "ed seo start"),
        ("create a site audit project", "ed seo create"),
        ("search my memories", "ed companion search"),
        ("attach to a running agent session", "ed herdr attach"),
        ("send a message to a running agent", "ed herdr send"),
        ("install edith skills into my agents", "ed skills install"),
        ("set up shell completions", "ed completions install"),
        ("show background agent logs", "ed agent logs"),
        ("convert units", "ed bifrost convert"),
        ("calculate a math expression", "ed bifrost calc"),
        ("mute an app", "ed audio mute"),
        ("start a focus session", "ed attention focus start"),
        ("list running containers on my server", "ed machines docker ps"),
        ("open a shell in a docker container", "ed machines docker shell"),
        ("list extensions", "ed extensions ls"),
        ("install an extension", "ed extensions install"),
        ("enable an extension", "ed extensions enable"),
        ("disable an extension", "ed extensions disable"),
        ("remove an extension", "ed extensions remove"),
        ("rotate the pages of a pdf", "ed studio run"),
        ("convert powerpoint to pdf", "ed studio run"),
        ("add a watermark to my images", "ed studio run"),
        ("blur faces in a photo", "ed studio run"),
        ("make a video play backwards", "ed studio run"),
        ("add subtitles to a video", "ed studio run"),
        ("stabilize shaky footage", "ed studio run"),
        ("unlock a password protected pdf", "ed studio run"),
        ("make an animated gif from images", "ed studio run"),
        ("save a saved chain of studio tools", "ed studio workflow save"),
        ("stop a docker container on a machine", "ed machines docker stop"),
        ("shut down a server", "ed machines power shutdown"),
        ("show logs of a docker container", "ed machines docker logs"),
        ("bring up a docker compose project", "ed machines docker compose up"),
        ("go back to the previous song", "ed music previous"),
        ("copy a clipboard entry again", "ed clipboard copy"),
        ("cancel a download", "ed download cancel"),
        ("test a database connection", "ed database connections test"),
        ("open edith main window", "ed app open"),
        ("export usage cards as images", "ed usage export"),
        ("empty the shelf", "ed shelf clear"),
        ("set the emoji skin tone", "ed emoji tone"),
    ]

    static let unanswered: [(String, String)] = [
        ("add a password to a pdf", "ed studio run"),
        ("remove the background from a photo", "ed studio run"),
        ("count lines of code in my repositories", "ed code-stats run"),
        ("list my ssh machines", "ed machines ls"),
        ("run a command on every machine", "ed machines broadcast"),
        ("how much did my coding agents cost this week", "ed usage summary"),
        ("how much disk space can i reclaim", "ed cleaner scan"),
        ("update my mac apps", "ed maintenance update"),
        ("download a youtube video", "ed download add"),
        ("list the tables in a database", "ed database browse"),
        ("change a setting from the terminal", "ed config set"),
        ("show cpu and memory usage", "ed system stats"),
        ("import notes and recordings into memory", "ed companion ingest"),
        ("keep my mac awake with the lid closed", "ed lid-awake on"),
        ("restart edith", "ed app relaunch"),
        ("check for edith updates", "ed app check-updates"),
        ("is ffmpeg installed", "ed tools ls"),
        ("change the volume of one app", "ed audio volume"),
        ("how much time did i spend in each app", "ed attention breakdown"),
        ("show free space on a server", "ed machines metrics"),
        ("convert a webpage to pdf", "ed studio run"),
        ("rename a machine", "ed machines edit"),
        ("copy a file between two machines", "ed machines files transfer"),
        ("list homebrew packages", "ed brew ls"),
        ("reset a setting to its default", "ed config unset"),
        ("take a screenshot of the edith window", "ed app snapshot"),
        ("how close am i to my claude limit", "ed usage limits"),
        ("list the colors i picked", "ed color ls"),
    ]

    static let minimumTopOneRate = 0.78

    static func top(_ request: String) -> String? {
        DocsFixture.library.search.rank(request, limit: 3).first?.command.path
    }

    @Test(arguments: answered) func ranksTheExpectedCommandFirst(
        _ request: String, _ expected: String
    ) {
        let picks = DocsFixture.library.search.rank(request, limit: 3).map(\.command.path)
        #expect(picks.first == expected, "\(request) -> \(picks)")
    }

    @Test func topOneRateHoldsAcrossTheWholeReference() {
        let questions = Self.answered + Self.unanswered
        let misses = questions.filter { Self.top($0.0) != $0.1 }
        let rate = Double(questions.count - misses.count) / Double(questions.count)
        #expect(rate >= Self.minimumTopOneRate, "\(rate) misses: \(misses.map(\.0))")
    }
}
