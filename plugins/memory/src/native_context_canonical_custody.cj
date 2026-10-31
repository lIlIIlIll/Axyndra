package memory_plugin

import agent_domain.*
import yjson.*
import yjson_support.*

// The caller retains the original typed record Strings under its actual
// input/history ancestor. Only new DOM cells and canonical copies belong here.
// Keep the old canonicalAgentValue equality, including every codec field.
func nativeMemoryOwnedContextRecordEqual(left:MemoryV3Record,right:MemoryV3Record,
    ancestor:LogicalJsonOwnerReservation):Bool {
    let scratch=ancestor.deriveRetainedLease()
    var leftValue:?AgentValue=None
    var rightValue:?AgentValue=None
    var leftCanonical:?String=None
    var rightCanonical:?String=None
    try {
        // Both complete record DOMs coexist. This is the original snapshot
        // wrapper/array allowance, SUMmed before either record value is made.
        let leftCells=memoryLiveAdd(128,memoryLiveMul(left.conflictIds.size,4))
        let rightCells=memoryLiveAdd(128,memoryLiveMul(right.conflictIds.size,4))
        let domPeak=memoryLiveAdd(1048576+131072,memoryLiveMul(memoryLiveAdd(leftCells,rightCells),512))
        scratch.ensureRetainedPeak(domPeak)
        leftValue=Some(memoryV3RecordValue(left))
        rightValue=Some(memoryV3RecordValue(right))
        // The existing complete canonical extent walk reads the paid DOM and
        // String sizes; it never materializes a complete canonical String.
        let canonicalBytes=memoryLiveAdd(nativeMemoryReplayCanonicalBytes(leftValue.getOrThrow()),
            nativeMemoryReplayCanonicalBytes(rightValue.getOrThrow()))
        // Preserve both canonical outputs and the old recursive framing,
        // concatenation/encoding temporaries under the SAME child phase lease.
        scratch.ensureRetainedPeak(memoryLiveAdd(domPeak,memoryLiveMul(canonicalBytes,8)))
        leftCanonical=Some(canonicalAgentValue(leftValue.getOrThrow()))
        rightCanonical=Some(canonicalAgentValue(rightValue.getOrThrow()))
        leftCanonical.getOrThrow()==rightCanonical.getOrThrow()
    } finally {
        leftCanonical=None;rightCanonical=None;leftValue=None;rightValue=None
        scratch.close()
    }
}
