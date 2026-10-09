import EdithExtensionSupport
import Testing
@testable import SEOAuditExtension

@MainActor @Suite struct SEOAuditPrivacyTests {
    @Test func dedicatedSiteAuditOverrideMatchesSharedCardPrivacy() {
        for (values, expected) in [
            (["active": "0", "blurSiteAudit": "1"], false),
            (["active": "1", "blurSiteAudit": "1", "blurShelf": "0"], true),
            (["active": "1", "blurSiteAudit": "0", "blurShelf": "1"], false),
            (["active": "1"], true),
        ] {
            #expect(SEOAuditPrivacyState.hidden(values: values) == expected)
            #expect(SurfacePrivacyState.hides(.ability("seoAudit"), values: values) == expected)
        }
    }
}
