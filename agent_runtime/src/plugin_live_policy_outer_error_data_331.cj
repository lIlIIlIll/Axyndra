package agent_runtime

import agent_domain.*

// Only actual complete typed error DATA and its same-original-bank payment.
// No Source/permission/approval/retry/Receipt/Known/physical-cleanup authority.
// A Result.Err alias, registry snapshot, event or caller frame is NOT retired
// merely because a resource close or callback returns. This initial contract
// is intentionally closed until the actual Core/Tools consumer migration.
public interface PluginLivePolicyOuterErrorDataOwner331 {
    func matchesError(actual:AgentError):Bool
    func withError(consume:(AgentError)->Result<Unit>):Result<Unit>
    func isConsumerRetired():Bool
    func closeAfterConsumerRetirement():Result<Unit>
}
