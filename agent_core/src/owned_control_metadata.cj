package agent_core

import agent_domain.*
import agent_runtime.*

// Pure control metadata, not a conversation snapshot. Every caller reads
// only thread ID, epoch or next sequence. Full history remains explicit paid
// ordered readback; this cannot attest Source from IDs or admit any effect.
func coreOwnedControlMetadata(runtime: AgentThreadRuntime): AgentThreadSnapshot {
    if (runtime.ownedCanonicalReadback().isSome()) { runtime.threadMetadataSnapshot() }
    else { runtime.threadSnapshot() }
}
