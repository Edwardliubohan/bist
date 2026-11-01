import Foundation
import CloudKit

@main
struct CloudKitPolicyTests {
    @MainActor static func main() {
        let retryable: [CKError.Code] = [.networkFailure, .networkUnavailable, .requestRateLimited, .notAuthenticated,
                                        .accountTemporarilyUnavailable, .zoneBusy, .serviceUnavailable, .operationCancelled]
        for code in retryable {
            precondition(CloudKitFailurePolicy.isRetryable(code), "CKSyncEngine must retain its automatic retry for \(code)")
        }
        for code: CKError.Code in [.permissionFailure, .quotaExceeded, .badContainer, .serverRejectedRequest] {
            precondition(!CloudKitFailurePolicy.isRetryable(code), "Configuration and quota errors need visible recovery")
        }
        precondition(CloudKitReplicaTransport.configuredContainer("") == nil)
        precondition(CloudKitReplicaTransport.configuredContainer("$(BIST_CLOUDKIT_CONTAINER)") == nil)
        print("PASS CloudKit retry and unsigned configuration policies")
    }
}
