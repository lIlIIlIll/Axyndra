package agent_store

import agent_domain.*
import agent_runtime.*
import std.convert.*
import yjson.*
import yjson_support.*

// Called after the existing complete executing ContextRead Source, plan,
// state-register and handoff check, in the same canonical transaction. The
// original pending-Tool-parent scope validator is intentionally separate.
func requirePluginDocumentContextReadScope(transaction: SqliteTransaction, source: DirectToolCallRef,
    plan: NormalizedOperationPlan): LaneId {
    if(!isContextReadPlan(plan) || !pluginDocumentReadAuthority(plan) ||
        !pluginDocumentContextReadRequestValid(plan.canonicalArguments)){
        throw IllegalStateException("invalid document context read authority")}
    let binding=plan.canonicalArguments.field("binding").getOrThrow()
    let origin=match(source.origin){case DirectCallOrigin.ContextRead(value)=>value
        case _=>throw IllegalStateException("document context read has another Source kind")}
    let lane=requirePluginDocumentLane(transaction,source.threadId,source.runId,source.epoch)
    if(origin.parentCallItemId!="" || origin.parentKind!="" || origin.parentOperationId!="" ||
        httpIntentText(binding,"thread_id")!=source.threadId.value || httpIntentText(binding,"run_id")!=source.runId.value ||
        Int64.parse(binding.field("epoch").getOrThrow().asNumberText())!=source.epoch ||
        httpIntentText(binding,"lane_id")!=lane.value ||
        origin.ownerNamespace!=httpIntentText(binding,"namespace") ||
        origin.packageDigest!=httpIntentText(binding,"package_digest") ||
        origin.configurationDigest!=httpIntentText(binding,"configuration_digest") ||
        origin.projectionDigest!=httpIntentText(plan.canonicalArguments,"projection_digest")){
        throw IllegalStateException("document context read lost its exact initial/update Root scope")}
    lane
}
