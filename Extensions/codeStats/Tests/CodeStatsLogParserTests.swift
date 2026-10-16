@testable import CodeStatsExtension
import EdithExtensionSupport
import Foundation
import Testing

@Suite struct CodeStatsLogParserTests {
    private let everyone: (String, String) -> Bool = { _, _ in true }

    private func commit(_ sha: String, _ day: String, _ body: String) -> String {
        "C\t\(sha)\t\(day)T12:00:00+05:30\tPulkit\tp@x.com\n\(body)"
    }

    private func parse(_ text: String) -> [CodeStatsCommit] {
        CodeStatsLogParser.parse(text, repository: "octo/demo", isMine: everyone)
    }

    @Test func pureAdditionsInANewFile() {
        let commits = parse(
            commit(
                "a1", "2026-06-01",
                """
                diff --git a/src/app.ts b/src/app.ts
                new file mode 100644
                index 0000000..1111111
                --- /dev/null
                +++ b/src/app.ts
                @@ -0,0 +1,3 @@
                +line1
                +line2
                +line3
                """))
        #expect(commits.count == 1)
        #expect(commits[0].languages["TypeScript"] == CodeStatsLanguageCounts(added: 3))
        #expect(commits[0].day == "2026-06-01")
        #expect(commits[0].hour == 12)
        #expect(commits[0].repository == "octo/demo")
    }

    @Test func anEditCountsAsUpdatedLines() {
        let commits = parse(
            commit(
                "a2", "2026-06-02",
                """
                diff --git a/src/app.ts b/src/app.ts
                index 1111111..2222222 100644
                --- a/src/app.ts
                +++ b/src/app.ts
                @@ -1,2 +1,2 @@
                -old1
                -old2
                +new1
                +new2
                """))
        #expect(commits[0].languages["TypeScript"] == CodeStatsLanguageCounts(updated: 2))
    }

    @Test func aMixedHunkSplitsIntoUpdatedAndAdded() {
        let commits = parse(
            commit(
                "a3", "2026-06-03",
                """
                diff --git a/x.py b/x.py
                index 1..2 100644
                --- a/x.py
                +++ b/x.py
                @@ -1 +1,3 @@
                -old
                +a
                +b
                +c
                """))
        #expect(commits[0].languages["Python"] == CodeStatsLanguageCounts(added: 2, updated: 1))
    }

    @Test func aDeletedFileUsesTheOldPath() {
        let commits = parse(
            commit(
                "a4", "2026-06-04",
                """
                diff --git a/gone.go b/gone.go
                deleted file mode 100644
                index 1..0
                --- a/gone.go
                +++ /dev/null
                @@ -1,2 +0,0 @@
                -one
                -two
                """))
        #expect(commits[0].languages["Go"] == CodeStatsLanguageCounts(deleted: 2))
    }

    @Test func aDeletedContentLineStartingWithDashesIsNotAHeader() {
        let commits = parse(
            commit(
                "a5", "2026-06-05",
                """
                diff --git a/m.sql b/m.sql
                index 1..2 100644
                --- a/m.sql
                +++ b/m.sql
                @@ -1 +1 @@
                --- AlterTable
                +-- CreateTable
                """))
        #expect(commits[0].languages["SQL"] == CodeStatsLanguageCounts(updated: 1))
    }

    @Test func aPureRenameCountsNothing() {
        let commits = parse(
            commit(
                "a6", "2026-06-06",
                """
                diff --git a/old.ts b/new.ts
                similarity index 100%
                rename from old.ts
                rename to new.ts
                """))
        #expect(commits.count == 1)
        #expect(commits[0].languages.isEmpty)
    }

    @Test func aGeneratedFileIsSkipped() {
        let commits = parse(
            commit(
                "a7", "2026-06-06",
                """
                diff --git a/package-lock.json b/package-lock.json
                index 1..2 100644
                --- a/package-lock.json
                +++ b/package-lock.json
                @@ -1,0 +1,500 @@
                +lots
                """))
        #expect(commits[0].languages.isEmpty)
    }

    @Test func aMultiFileCommitAggregatesPerLanguage() {
        let commits = parse(
            commit(
                "a8", "2026-06-06",
                """
                diff --git a/a.ts b/a.ts
                index 1..2 100644
                --- a/a.ts
                +++ b/a.ts
                @@ -0,0 +1,2 @@
                +x
                +y
                diff --git a/b.py b/b.py
                index 1..2 100644
                --- a/b.py
                +++ b/b.py
                @@ -0,0 +1 @@
                +z
                """))
        #expect(commits[0].languages["TypeScript"]?.added == 2)
        #expect(commits[0].languages["Python"]?.added == 1)
    }

    @Test func aBinaryFileCountsNothing() {
        let commits = parse(
            commit(
                "a9", "2026-06-06",
                """
                diff --git a/img.png b/img.png
                index 1..2 100644
                Binary files a/img.png and b/img.png differ
                """))
        #expect(commits[0].languages.isEmpty)
    }

    @Test func theIdentityFilterExcludesOtherAuthors() {
        let text = """
            C\tb1\t2026-06-06T12:00:00Z\tStranger\ts@x.com
            diff --git a/a.ts b/a.ts
            index 1..2 100644
            --- a/a.ts
            +++ b/a.ts
            @@ -0,0 +1 @@
            +x
            """
        let commits = CodeStatsLogParser.parse(
            text, repository: "octo/demo", isMine: { _, email in email == "p@x.com" })
        #expect(commits.isEmpty)
    }

    @Test func quotedPathsAreUnquotedBeforeClassification() {
        let commits = parse(
            commit(
                "b2", "2026-06-07",
                """
                diff --git "a/sp ace.rs" "b/sp ace.rs"
                --- "a/sp ace.rs"
                +++ "b/sp ace.rs"
                @@ -0,0 +1 @@
                +fn main() {}
                """))
        #expect(commits[0].languages["Rust"] == CodeStatsLanguageCounts(added: 1))
    }

    private static let sample = """
        C\ta1\t2026-06-01T12:00:00+05:30\tPulkit\tp@x.com
        diff --git a/src/app.ts b/src/app.ts
        index 1..2 100644
        --- a/src/app.ts
        +++ b/src/app.ts
        @@ -1,2 +1,3 @@
        -old
        +new
        +extra
        diff --git a/x.py b/x.py
        index 1..2 100644
        --- a/x.py
        +++ b/x.py
        @@ -0,0 +1 @@
        +z
        C\ta2\t2026-06-02T09:00:00Z\tPulkit\tp@x.com
        diff --git a/m.sql b/m.sql
        index 1..2 100644
        --- a/m.sql
        +++ b/m.sql
        @@ -1 +1 @@
        --- AlterTable
        +-- CreateTable

        """

    private func parseChunked(_ text: String, size: Int) -> [CodeStatsCommit] {
        var parser = CodeStatsLogParser(repository: "octo/demo", isMine: everyone)
        let characters = Array(text)
        var buffer = ""
        var index = 0
        while index < characters.count {
            buffer += String(characters[index..<min(index + size, characters.count)])
            index += size
            var parts = buffer.split(separator: "\n", omittingEmptySubsequences: false)
            buffer = String(parts.removeLast())
            for line in parts { parser.push(line) }
        }
        if !buffer.isEmpty { parser.push(buffer) }
        return parser.finish()
    }

    @Test func streamingInTinyChunksEqualsParsingTheWholeText() {
        let whole = parse(Self.sample)
        for size in [1, 3, 7, 16, 64, 1_024] {
            #expect(parseChunked(Self.sample, size: size) == whole)
        }
    }

    @Test func countsSurviveChunkBoundaries() {
        let commits = parseChunked(Self.sample, size: 5)
        #expect(commits.count == 2)
        #expect(commits[0].languages["TypeScript"] == CodeStatsLanguageCounts(added: 1, updated: 1))
        #expect(commits[0].languages["Python"] == CodeStatsLanguageCounts(added: 1))
        #expect(commits[1].languages["SQL"] == CodeStatsLanguageCounts(updated: 1))
        #expect(commits[1].hour == 9)
    }
}

@Suite struct CodeStatsClassifierTests {
    @Test func mapsCommonExtensionsToLanguages() {
        #expect(CodeStatsLanguage.classify("src/app.ts") == "TypeScript")
        #expect(CodeStatsLanguage.classify("src/app.tsx") == "TSX")
        #expect(CodeStatsLanguage.classify("main.py") == "Python")
        #expect(CodeStatsLanguage.classify("lib.rs") == "Rust")
        #expect(CodeStatsLanguage.classify("index.js") == "JavaScript")
        #expect(CodeStatsLanguage.classify("style.css") == "CSS")
        #expect(CodeStatsLanguage.classify("README.md") == "Markdown")
    }

    @Test func recognizesSpecialBasenames() {
        #expect(CodeStatsLanguage.classify("Dockerfile") == "Dockerfile")
        #expect(CodeStatsLanguage.classify("path/to/Makefile") == "Makefile")
    }

    @Test func unknownExtensionsStillCountAsOther() {
        #expect(CodeStatsLanguage.classify("data.weirdext") == "Other")
        #expect(CodeStatsLanguage.classify("LICENSE") == "Other")
    }

    @Test func generatedAndVendoredFilesAreExcluded() {
        for path in [
            "package-lock.json", "frontend/yarn.lock", "a/bun.lockb", "Cargo.lock",
            "app/dist/bundle.js", "x/node_modules/y/z.js", "public/app.min.js", "vendor/foo.go",
        ] {
            #expect(CodeStatsLanguage.classify(path) == nil, "\(path)")
        }
    }

    @Test func isGeneratedIsExposedForReuse() {
        #expect(CodeStatsLanguage.isGenerated("a/b/.next/c.js"))
        #expect(!CodeStatsLanguage.isGenerated("src/app.ts"))
        #expect(CodeStatsLanguage.excludedPathspecs.contains(":(exclude,glob)**/*.lock"))
    }
}

@Suite struct CodeStatsIdentityTests {
    private let identity = CodeStatsIdentity(substrings: ["octocat"], emails: ["you@example.com"])

    @Test func matchesBySubstringInNameOrEmailIgnoringCase() {
        let isMine = identity.matcher()
        #expect(isMine("Octocat Smith", "whatever@x.com"))
        #expect(isMine("someone", "12345+octocat@users.noreply.github.com"))
        #expect(isMine("OCTOCAT", "X@Y.com"))
    }

    @Test func matchesByExactEmail() {
        #expect(identity.matcher()("Old Name", "YOU@example.com"))
    }

    @Test func doesNotMatchUnrelatedAuthors() {
        #expect(!identity.matcher()("Jarred Sumner", "jarred@jarredsumner.com"))
        #expect(!CodeStatsIdentity().matcher()("anyone", "a@b.c"))
    }

    @Test func authorPatternsEscapeRegexMetacharacters() {
        #expect(identity.authorPatterns.contains("octocat"))
        #expect(identity.authorPatterns.contains("you@example\\.com"))
        #expect(CodeStatsIdentity.escapeRegex("a(b)+c") == "a\\(b\\)\\+c")
    }

    @Test func seedingFromAProfileUsesTheLoginAndEmails() {
        let seeded = CodeStatsIdentity.seeded(
            login: "octocat", emails: ["1+octocat@users.noreply.github.com"])
        #expect(seeded.substrings == ["octocat"])
        #expect(seeded.labels == ["1+octocat@users.noreply.github.com", "*octocat*"])
    }

    @Test func theFingerprintIgnoresOrderAndCaseButNotContent() {
        let reordered = CodeStatsIdentity(substrings: ["OctoCat"], emails: ["you@example.com"])
        #expect(identity.fingerprint == reordered.fingerprint)
        #expect(identity.fingerprint.count == 64)
        let edited = CodeStatsIdentity(substrings: ["octocat", "pk"], emails: identity.emails)
        #expect(identity.fingerprint != edited.fingerprint)
    }
}
