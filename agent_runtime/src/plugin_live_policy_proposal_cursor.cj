package agent_runtime

import agent_domain.*

// Trusted assembly IO only. Native JSON cannot construct a file cursor, SQL
// selector, cleanup owner or Source through this interface. Actual Store
// proves the immutable Prepared child and every original member pin before
// opening it. finish requires full original group EOF/SHA and checked FD ACK.
public interface PluginLivePolicyProposalCursor {
    func next():Result<Array<Byte>>
    func finish():Result<Unit>
    func close():Result<Unit>
}
