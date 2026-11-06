import AppKit
import EdithExtensionTestSupport
import SwiftUI
import Testing
@testable import EdithExtensionUI

@MainActor
@Suite(.exclusiveScale) struct LoadingContainerTests {
    @Test func placeholdersWaitLongerThanFastLoadsAndRefreshHintsDoNotFlash() {
        #expect(ContentActivityTiming.placeholderDelay >= .milliseconds(200))
        #expect(ContentActivityTiming.revealDelay >= .milliseconds(150))
        #expect(ContentActivityTiming.placeholderDelay > ContentActivityTiming.revealDelay)
    }

    @Test func defaultPlaceholderIsALayoutMatchedSkeleton() {
        for layout in PageSkeletonLayout.allCases {
            let container = LoadingContainer(state: .loading, layout: layout) { Text("Body") }
            #expect(type(of: container) == LoadingContainer<Text, PageSkeleton>.self)
        }
    }

    @Test func loadingContainerRendersEveryStateWithoutAPlaceholderClosure() async throws {
        for state in [
            ContentLoadingState.loading, .content, .empty, .error, .offline, .cancelled,
        ] {
            let host = NSHostingView(
                rootView: LoadingContainer(state: state, layout: .cards, refreshing: true) {
                    Text("Body")
                }
                .frame(width: 400, height: 300))
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width > 0)
        }
    }

    @Test func activityResolvesUpdatingBeforeRefreshing() {
        #expect(ContentActivity.resolve(updating: true, refreshing: true) == .updating)
        #expect(ContentActivity.resolve(updating: false, refreshing: true) == .refreshing)
        #expect(ContentActivity.resolve(updating: false, refreshing: false) == .idle)
        #expect(ContentActivity.idle.label == nil)
    }
}
