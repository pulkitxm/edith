import Testing
@testable import EdithKit

@Suite struct PermissionsStatusTests {
    func needsAttention(
        calendarTab: Bool = false, systemTab: Bool = false, notifyMaster: Bool = false,
        calendar: Bool = true, accessibility: Bool = true, inputMonitoring: Bool = true,
        notifications: Bool = true
    ) -> Bool {
        PermissionsStatus.needsAttention(
            calendarTab: calendarTab, systemTab: systemTab, notifyMaster: notifyMaster,
            calendar: calendar, accessibility: accessibility, inputMonitoring: inputMonitoring,
            notifications: notifications)
    }

    @Test func allGrantedNeedsNothing() {
        #expect(!needsAttention(calendarTab: true, systemTab: true, notifyMaster: true))
    }

    @Test func missingPermissionOnlyWarnsWhenFeatureIsOn() {
        #expect(!needsAttention(calendarTab: false, calendar: false))
        #expect(needsAttention(calendarTab: true, calendar: false))
    }

    @Test func systemTabWarnsWhenEitherKeyboardPermissionMissing() {
        #expect(needsAttention(systemTab: true, accessibility: false))
        #expect(needsAttention(systemTab: true, inputMonitoring: false))
        #expect(!needsAttention(systemTab: true))
    }

    @Test func systemTabOffIgnoresKeyboardPermissions() {
        #expect(!needsAttention(systemTab: false, accessibility: false, inputMonitoring: false))
    }

    @Test func notificationsWarnOnlyWhenMasterIsOn() {
        #expect(!needsAttention(notifyMaster: false, notifications: false))
        #expect(needsAttention(notifyMaster: true, notifications: false))
    }
}
