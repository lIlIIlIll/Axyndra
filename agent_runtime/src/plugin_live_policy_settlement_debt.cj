package agent_runtime

import agent_domain.*

// Actual resource cleanup only. No Source, Receipt, output, Known tip,
// approval, cancellation decision or retry authority is represented here.
public interface PluginLivePolicySettlementCleanupDebt326 {
    func closeAfterFailure():Result<Unit>
    func isAcknowledged():Bool
}
// Explicit opt-in return carrier; ordinary Result ports are unchanged.
// A cleanup-only failure cannot lose its actual Store resource owner when
// its original typed user-facing error is propagated to the real Kernel.
public class PluginLivePolicyJournalSettlementProgress326 {
    public let result:Result<Unit>
    public let cleanupDebt:?PluginLivePolicySettlementCleanupDebt326
    public let errorData:?PluginLivePolicyOuterErrorDataOwner331
    public init(result:Result<Unit>,cleanupDebt!:?PluginLivePolicySettlementCleanupDebt326=None,
        errorData!:?PluginLivePolicyOuterErrorDataOwner331=None){
        this.result=result;this.cleanupDebt=cleanupDebt;this.errorData=errorData
    }
}
