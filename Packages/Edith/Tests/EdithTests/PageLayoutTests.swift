import Testing
@testable import Edith

@Suite struct PageLayoutTests {
    @Test func fluidContentNeverAddsAnArtificialMaximum() {
        #expect(PageContentWidth.fluid.maximum(compact: false) == nil)
        #expect(PageContentWidth.fluid.maximum(compact: true) == nil)
    }

    @Test func readableContentIsLeadingBoundedOnlyWhenSpaceAllows() {
        #expect(PageContentWidth.readable.maximum(compact: false) != nil)
        #expect(PageContentWidth.readable.maximum(compact: true) == nil)
    }
}
