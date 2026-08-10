import Foundation
import Testing

@testable import EdithKit

@Suite struct RsyncProgressTests {
    @Test func readsARealProgressLine() {
        let sample = RsyncProgress.parse("     32,604,160  25%   29.33MB/s    0:00:03  ")
        #expect(sample?.bytesTransferred == 32_604_160)
        #expect(sample?.percent == 25)
        #expect(sample?.bytesPerSecond == 29_330_000)
        #expect(sample?.filesRemaining == nil)
    }

    @Test func readsTheFileCounterWhenAFileFinishes() {
        let sample = RsyncProgress.parse(
            "     41,943,040  33%   31.25MB/s    0:00:01 (xfr#1, to-chk=2/4)")
        #expect(sample?.bytesTransferred == 41_943_040)
        #expect(sample?.percent == 33)
        #expect(sample?.filesRemaining == 2)
        #expect(sample?.filesTotal == 4)
    }

    @Test func splitsTheCarriageReturnStream() {
        let chunk =
            "         32,768   0%    0.00kB/s    0:00:00  \r"
            + "    125,829,120 100%   29.61MB/s    0:00:04 (xfr#3, to-chk=0/4)\r"
        let samples = RsyncProgress.lines(from: chunk)
        #expect(samples.count == 2)
        #expect(samples.first?.percent == 0)
        #expect(samples.last?.percent == 100)
        #expect(samples.last?.filesRemaining == 0)
    }

    @Test func ignoresEverythingThatIsNotAProgressRecord() {
        #expect(RsyncProgress.parse("") == nil)
        #expect(RsyncProgress.parse("sending incremental file list") == nil)
        #expect(RsyncProgress.parse("created directory /tmp/dst") == nil)
        #expect(RsyncProgress.parse("total size is 125,829,120  speedup is 1.00") == nil)
        #expect(RsyncProgress.parse("rsync: command not found") == nil)
    }

    @Test func understandsEveryRateUnit() {
        #expect(RsyncProgress.rate("0.00kB/s") == 0)
        #expect(RsyncProgress.rate("512B/s") == 512)
        #expect(RsyncProgress.rate("1.50kB/s") == 1500)
        #expect(RsyncProgress.rate("29.33MB/s") == 29_330_000)
        #expect(RsyncProgress.rate("1.39GB/s") == 1_390_000_000)
        #expect(RsyncProgress.rate("nonsense") == 0)
    }
}

@Suite struct ThroughputEstimatorTests {
    @Test func reportsNothingUntilItHasASample() {
        let estimator = ThroughputEstimator()
        let estimate = estimator.estimate(bytesRemaining: 1000)
        #expect(estimate.bytesPerSecond == 0)
        #expect(estimate.secondsRemaining == nil)
    }

    @Test func smoothsSpikesInsteadOfFollowingThem() {
        var estimator = ThroughputEstimator(weight: 0.25)
        estimator.record(bytesPerSecond: 1000)
        estimator.record(bytesPerSecond: 9000)
        let estimate = estimator.estimate(bytesRemaining: 6000)
        #expect(estimate.bytesPerSecond == 3000)
        #expect(estimate.secondsRemaining == 2)
    }

    @Test func aStalledSampleDoesNotWipeTheEstimate() {
        var estimator = ThroughputEstimator()
        estimator.record(bytesPerSecond: 2000)
        estimator.record(bytesPerSecond: 0)
        #expect(estimator.estimate(bytesRemaining: 4000).bytesPerSecond == 2000)
    }
}

@Suite struct RsyncDialectTests {
    @Test func readsTheOpenrsyncSpelling() {
        let sample = RsyncProgress.parse(
            "      629145600 100%  390.67MB/s   00:00:01 (xfer#1, to-check=0/1)")
        #expect(sample?.bytesTransferred == 629_145_600)
        #expect(sample?.filesRemaining == 0)
        #expect(sample?.filesTotal == 1)
        #expect(sample?.totalIsEstimate == false)
    }

    @Test func anIncrementalScanMarksTheTotalAsAnEstimate() {
        let growing = RsyncProgress.parse(
            "     41,943,040  33%   31.25MB/s    0:00:01 (xfr#1, ir-chk=1010/1050)")
        #expect(growing?.totalIsEstimate == true)
        #expect(growing?.filesTotal == 1050)
        let settled = RsyncProgress.parse(
            "     41,943,040  33%   31.25MB/s    0:00:01 (xfr#1, to-chk=2/4)")
        #expect(settled?.totalIsEstimate == false)
    }

    @Test func rejectsHumanReadableByteFieldsRatherThanMisreadingThem() {
        #expect(RsyncProgress.parse("        188.74M  33%   31.25MB/s    0:00:01") == nil)
        #expect(RsyncProgress.parse("          1.23G 100%   1.00GB/s    0:00:00") == nil)
    }
}

@Suite struct TransferLineSplitterTests {
    @Test func reassemblesRecordsSplitAtArbitraryBoundaries() {
        let stream =
            "\r      2,326,528   0%    1.99MB/s    0:05:06  "
            + "\r    629,145,600 100%   20.24MB/s    0:00:29 (xfr#1, to-chk=0/1)\n"
        var whole = TransferLineSplitter()
        let expected = whole.receive(stream)
        #expect(expected.count == 2)

        var piecemeal = TransferLineSplitter()
        var rebuilt: [String] = []
        for character in stream {
            rebuilt += piecemeal.receive(String(character))
        }
        rebuilt += piecemeal.flush()
        #expect(rebuilt == expected)
    }

    @Test func holdsBackATrailingFragmentUntilItIsTerminated() {
        var splitter = TransferLineSplitter()
        #expect(splitter.receive("EDITH PID ").isEmpty)
        #expect(splitter.receive("4321\n") == ["EDITH PID 4321"])
    }
}

@Suite struct TransferMarkerTests {
    @Test func readsEachMarker() {
        #expect(TransferMarkers.parse("EDITH PID 4321") == .pid(4321))
        #expect(TransferMarkers.parse("EDITH SCAN 12 4096") == .scan(files: 12, bytes: 4096))
        #expect(TransferMarkers.parse("EDITH ITEM 3 0") == .item(index: 3, exitStatus: 0))
    }

    @Test func aFilenameCannotImpersonateAMarker() {
        #expect(TransferMarkers.parse("      1,024   0%  1MB/s  0:00:01 EDITH ITEM 3 0") == nil)
        #expect(TransferMarkers.parse("cp: 'EDITH ITEM 3 0' -> '/dst'") == nil)
        #expect(TransferMarkers.parse("EDITH ITEM three 0") == nil)
        #expect(TransferMarkers.parse("EDITH UNKNOWN 1 2") == nil)
    }
}

@Suite struct MachineTransferFactsTests {
    @Test func classifiesEachRsyncFlavour() {
        let gnu = MachineTransferFacts.parse(
            "rsync=rsync  version 3.2.7  protocol version 31\npv=no\nuid=1000")
        #expect(gnu.rsync == .gnu(major: 3, minor: 2))
        #expect(gnu.tier == .rsyncProgress2)
        #expect(!gnu.isRoot)

        let open = MachineTransferFacts.parse("rsync=openrsync: protocol version 29\npv=no")
        #expect(open.rsync == .openrsync)
        #expect(open.tier == .rsyncClassic)

        let bare = MachineTransferFacts.parse("rsync=none\npv=no")
        #expect(bare.tier == .verboseCopy)
        let withPv = MachineTransferFacts.parse("rsync=none\npv=yes")
        #expect(withPv.tier == .tarPipe)
    }

    @Test func readsTheRemainingProbeLines() {
        let facts = MachineTransferFacts.parse(
            "rsync=none\npv=yes\nfindprintf=yes\nuid=0")
        #expect(facts.hasPv)
        #expect(facts.findSupportsPrintf)
        #expect(facts.isRoot)
    }
}

@Suite struct TransferCommandTests {
    @Test func routesEverySourceAndDestinationPairing() {
        let a = UUID()
        let b = UUID()
        #expect(TransferRoute.route(from: .localMac, to: .localMac) == .localFile)
        #expect(TransferRoute.route(from: .machine(a), to: .machine(a)) == .remoteLocal(a))
        #expect(TransferRoute.route(from: .machine(a), to: .machine(b)) == .relay(from: a, to: b))
        #expect(TransferRoute.route(from: .localMac, to: .machine(b)) == .push(b))
        #expect(TransferRoute.route(from: .machine(a), to: .localMac) == .pull(a))
    }

    @Test func theRunnerRefusesToCopyAFileOverItself() {
        let runner = TransferCommands.remoteRunner(
            pairs: [(source: "/a/x", target: "/b/x")], tier: .rsyncProgress2, scanBytes: nil)
        #expect(runner.contains("[ \"$s\" -ef \"$t\" ]"))
        #expect(runner.contains("EDITH ITEM $i 200"))
        #expect(runner.contains("echo \"EDITH PID $$\""))
    }

    @Test func itemsAreIdentifiedByIndexNotName() {
        let runner = TransferCommands.remoteRunner(
            pairs: [(source: "/a/one", target: "/b/one"), (source: "/a/two", target: "/b/two")],
            tier: .rsyncProgress2, scanBytes: nil)
        #expect(runner.contains("copy_one /a/one /b/one 0"))
        #expect(runner.contains("copy_one /a/two /b/two 1"))
    }

    @Test func partialsNeverLandAtTheVisibleDestination() {
        for tier in [TransferTier.rsyncProgress2, .rsyncClassic] {
            let body = TransferCommands.copyBody(tier: tier, scanBytes: nil)
            #expect(body.contains("--partial-dir=.edith-partial"))
            #expect(body.contains("--exclude=.edith-partial"))
            #expect(!body.contains(" --partial "))
        }
    }

    @Test func everyPositionalPathIsGuardedAndQuoted() {
        let awkward = "/tmp/-weird name's/*.txt"
        let runner = TransferCommands.remoteRunner(
            pairs: [(source: awkward, target: "/dst/x")], tier: .verboseCopy, scanBytes: nil)
        #expect(runner.contains(ShellQuote.quote(awkward)))
        #expect(TransferCommands.copyBody(tier: .verboseCopy, scanBytes: nil).contains("-- "))
        #expect(TransferCommands.scanCommand(paths: [awkward], gnuFind: true).contains("find -- "))
        #expect(TransferCommands.byteCount(path: awkward).contains(ShellQuote.quote(awkward)))
    }

    @Test func cancelResumesAStoppedProcessBeforeTerminatingIt() {
        let cancel = TransferCommands.cancel(pid: 4321)
        let cont = cancel.range(of: "-CONT")
        let term = cancel.range(of: "-TERM")
        #expect(cont != nil)
        #expect(term != nil)
        #expect(cont!.lowerBound < term!.lowerBound)
        #expect(TransferCommands.pause(pid: 4321).contains("-STOP -4321"))
    }

    @Test func finalizeNeverRemovesTheTargetBeforeTheReplacementIsInPlace() {
        let file = TransferCommands.finalizeReplacingFile(part: "/d/.p", target: "/d/x")
        #expect(file == "mv -f /d/.p /d/x")
        #expect(!file.contains("rm"))

        let directory = TransferCommands.finalizeReplacingDirectory(part: "/d/.p", target: "/d/x")
        let retire = directory.range(of: "mv /d/x /d/x.edith-old")
        let remove = directory.range(of: "rm -rf")
        #expect(retire != nil)
        #expect(remove != nil)
        #expect(retire!.lowerBound < remove!.lowerBound)
    }

    @Test func resumeCountsFromTheRightByte() {
        #expect(TransferCommands.resumeRead(path: "/a/b", fromByte: 0) == "cat -- /a/b")
        #expect(TransferCommands.resumeRead(path: "/a/b", fromByte: 100) == "tail -c +101 -- /a/b")
    }
}

@Suite struct EtaPhrasingTests {
    @Test func usesCoarseBucketsRatherThanASecondsCountdown() {
        #expect(EtaPhrasing.bucket(seconds: 12) == "Less than a minute")
        #expect(EtaPhrasing.bucket(seconds: 61) == "About a minute")
        #expect(EtaPhrasing.bucket(seconds: 200) == "About 3 minutes")
        #expect(EtaPhrasing.bucket(seconds: 3500) == "About 58 minutes")
        #expect(EtaPhrasing.bucket(seconds: 3600) == "About an hour")
        #expect(EtaPhrasing.bucket(seconds: 7500) == "About 2 hours")
        #expect(EtaPhrasing.bucket(seconds: 90000) == "About a day")
    }

    @Test func saysNothingWhenThereIsNoEstimate() {
        #expect(EtaPhrasing.bucket(seconds: nil) == nil)
        #expect(EtaPhrasing.bucket(seconds: .infinity) == nil)
        #expect(EtaPhrasing.bucket(seconds: -1) == nil)
    }
}
