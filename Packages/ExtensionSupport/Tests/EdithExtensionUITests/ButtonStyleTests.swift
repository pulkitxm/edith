import Testing

@testable import EdithExtensionUI

struct ButtonStyleTests {
    @Test func toolbarAndIconButtonsKeepTheirHitTargetAndFeedbackChrome() {
        for role in [EdithButtonRole.toolbar, .iconOnly] {
            #expect(!role.usesFeatureAppearance)
            #expect(
                EdithButtonMetrics.metrics(for: role)
                    == EdithButtonMetrics(
                        horizontalPadding: 6, verticalPadding: 4, minimumWidth: 28,
                        minimumHeight: 28, cornerRadius: 6))
        }
        #expect(EdithButtonRole.borderless.usesFeatureAppearance)
    }
}
