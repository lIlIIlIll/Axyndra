package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// Called inside the existing executing ContextRead transaction, after the
// complete Source, normalized plan, state register and handoff validation.
// The Tool12 predicate is separate and is never accepted by this function.
func requirePluginDocumentContextWindowReadScope(transaction:SqliteTransaction,source:DirectToolCallRef,
    plan:NormalizedOperationPlan):LaneId{
    if(!isContextReadPlan(plan) || !pluginDocumentContextWindowReadAuthority(plan)){
        throw IllegalStateException("invalid parentless document window authority")}
    let binding=plan.canonicalArguments.field("binding").getOrThrow()
    let origin=match(source.origin){case DirectCallOrigin.ContextRead(value)=>value
        case _=>throw IllegalStateException("document window has another Source kind")}
    let lane=requirePluginDocumentLane(transaction,source.threadId,source.runId,source.epoch)
    if(origin.parentCallItemId!="" || origin.parentKind!="" || origin.parentOperationId!="" ||
        origin.parentDecisionId!="" || origin.parentScopedCallId!="" ||
        httpIntentText(binding,"thread_id")!=source.threadId.value || httpIntentText(binding,"run_id")!=source.runId.value ||
        binding.field("epoch").getOrThrow().asNumberText()!=source.epoch.toString() ||
        httpIntentText(binding,"lane_id")!=lane.value ||
        origin.ownerNamespace!=httpIntentText(binding,"namespace") || origin.packageDigest!=httpIntentText(binding,"package_digest") ||
        origin.configurationDigest!=httpIntentText(binding,"configuration_digest") ||
        origin.projectionDigest!=httpIntentText(plan.canonicalArguments,"projection_digest")){
        throw IllegalStateException("document window lost its exact parentless Run and lane")}
    lane
}
