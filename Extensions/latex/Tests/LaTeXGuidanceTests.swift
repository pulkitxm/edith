import Testing
@testable import LaTeXExtension

struct LaTeXGuidanceTests {
    @Test func everyLocationAndCompilerExplainsItself() {
        for location in LaTeXLocation.allCases { #expect(!location.summary.isEmpty) }
        for compiler in LaTeXCompiler.allCases { #expect(!compiler.summary.isEmpty) }
        #expect(LaTeXLocation.disk.summary != LaTeXLocation.github.summary)
    }
}
