package tool_runtime

import agent_domain.*
import yjson.*
import yjson_support.*

// This callback can only be attached by the actual in-process catalog
// assembly. A Read result is still powerless data until the original Runtime,
// policy, approval, budget and canonical ContextRead handoff all succeed.
public enum ToolPreparationReadNext { Read(ToolPreparationRead) | Ready(AgentValue) }
public class ToolPreparationReadSequence {
    public let maximumReads:Int64
    private let advanceFn:(ToolInvocationContext,Array<ContextReadFact>)->Result<ToolPreparationReadNext>
    public init(maximumReads:Int64,advance:(ToolInvocationContext,Array<ContextReadFact>)->Result<ToolPreparationReadNext>){
        if(maximumReads<1 || maximumReads>8){throw IllegalArgumentException("tool read sequence requires 1..8 stages")}
        this.maximumReads=maximumReads;this.advanceFn=advance
    }
    public func advance(context: ToolInvocationContext, facts: Array<ContextReadFact>): Result<ToolPreparationReadNext> {
        let view = context.beginInvocationView159()
        try { advanceScope159(view, facts) } finally { view.endInvocationView159() }
    }

    private func advanceScope159(context:ToolInvocationContext,facts:Array<ContextReadFact>):Result<ToolPreparationReadNext>{
        if(facts.size<1 || facts.size>maximumReads || context.cancellation.isCancelled()){
            return Result.Err(AgentError(AgentErrorKind.Conflict,"context.read_sequence_stage_limit","tool read sequence lost its bounded active owner"))}
        try{advanceFn(context,facts.clone())}catch(_:Exception){Result.Err(AgentError(AgentErrorKind.InvalidInput,
            "context.read_sequence_invalid","trusted read continuation failed to produce its next stage"))}
    }
}
