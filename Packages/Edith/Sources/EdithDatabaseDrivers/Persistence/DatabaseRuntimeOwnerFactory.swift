import EdithDatabase
import Foundation

enum DatabaseRuntimeOwnerFactory {
    static func claimReadyOwner(
        from store: any DatabaseMetadataStore,
        claimedAt: Date,
        recoveryLimit: Int = DatabaseMetadataMaintenanceBounds.maximumBatchSize
    ) async throws -> DatabaseRuntimeOwnerClaimResult {
        var claim = try await store.claimRuntimeOwner(
            claimedAt: claimedAt,
            recoveryLimit: recoveryLimit)
        if let retiredOwner = claim.retiredOwner {
            await DatabaseExecutor.retireRuntimeOwnerCoordination(retiredOwner)
        }
        var inspected = claim.recovery.inspectedOperationCount
        var recovered = claim.recovery.recoveredOperationCount
        while claim.recovery.hasMore {
            let recovery = try await store.recoverRuntimeOwner(
                claim.owner.token,
                limit: recoveryLimit)
            inspected += recovery.inspectedOperationCount
            recovered += recovery.recoveredOperationCount
            claim = DatabaseRuntimeOwnerClaimResult(
                owner: DatabaseRuntimeOwnerRecord(
                    token: claim.owner.token,
                    claimedAt: claim.owner.claimedAt,
                    recoveryPending: recovery.hasMore),
                retiredOwner: claim.retiredOwner,
                recovery: DatabaseRuntimeRecoveryResult(
                    inspectedOperationCount: inspected,
                    recoveredOperationCount: recovered,
                    hasMore: recovery.hasMore))
        }
        return claim
    }
}
