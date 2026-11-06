package tool_runtime

// Opt in to rechecking the already frozen target through the descriptor's
// existing canonicalizer before consuming approval. No executor is invoked,
// and owned canonicalizers keep their original paid copy/frame protocol.
public interface ToolApprovalTargetValidator {
    func requiresFrozenTargetValidation(): Bool
}
