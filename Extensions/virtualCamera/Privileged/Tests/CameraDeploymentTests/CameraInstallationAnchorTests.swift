import Darwin
import Testing
@testable import CameraDeployment

@Suite struct CameraInstallationAnchorTests {
    @Test func standardPlatformPermissionsRequireAnUnlinkProtectedPrivateRoot() {
        var platform = stat(), anchor = stat()
        platform.st_uid = 0; platform.st_gid = 80; platform.st_mode = S_IFDIR | 0o775
        anchor.st_uid = 0; anchor.st_gid = 0; anchor.st_mode = S_IFDIR | 0o755
        #expect(!CameraSealedInstallation.admitsApplicationsParent(platform, anchor: anchor))
        anchor.st_flags = UInt32(SF_NOUNLINK)
        #expect(CameraSealedInstallation.admitsApplicationsParent(platform, anchor: anchor))
        platform.st_mode = S_IFDIR | 0o755
        #expect(CameraSealedInstallation.admitsApplicationsParent(platform, anchor: anchor))
        platform.st_mode = S_IFDIR | 0o777
        #expect(!CameraSealedInstallation.admitsApplicationsParent(platform, anchor: anchor))
    }
    @Test func wrongOwnersGroupsLinksAndWritableRootsAreRejected() {
        var platform = stat(), anchor = stat()
        platform.st_uid = 0; platform.st_gid = 80; platform.st_mode = S_IFDIR | 0o775
        anchor.st_uid = 0; anchor.st_mode = S_IFDIR | 0o755
        anchor.st_flags = UInt32(SF_NOUNLINK)
        for owner: uid_t in [1, 501] {
            var changed = anchor; changed.st_uid = owner
            #expect(!CameraSealedInstallation.admitsApplicationsParent(platform, anchor: changed))
        }
        for mode: mode_t in [S_IFDIR | 0o775, S_IFLNK | 0o755, S_IFREG | 0o644] {
            var changed = anchor; changed.st_mode = mode
            #expect(!CameraSealedInstallation.admitsApplicationsParent(platform, anchor: changed))
        }
        platform.st_gid = 0
        #expect(!CameraSealedInstallation.admitsApplicationsParent(platform, anchor: anchor))
        platform.st_gid = 80; platform.st_uid = 501
        #expect(!CameraSealedInstallation.admitsApplicationsParent(platform, anchor: anchor))
        platform.st_uid = 0; platform.st_mode = S_IFLNK | 0o775
        #expect(!CameraSealedInstallation.admitsApplicationsParent(platform, anchor: anchor))
    }
}
