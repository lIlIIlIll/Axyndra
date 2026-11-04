package agent_core

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// Filtering changes only request visibility. Frozen registry identities and
// the original independent request-copy DATA owner remain authoritative.
func coreModelToolsForRequest159(runtime: AgentThreadRuntime, thread: ThreadId,
    state: ?AgentValue, reviewControl: Bool, pipeline: ToolPipeline): Result<(?OwnedModelTools159, Array<ModelToolDefinition>)> {
    let view = runtime.activeRunOwned159()
    try { corePlanModelToolsActive159(view, thread, state, reviewControl, pipeline) }
    finally { match (view) { case Some(value) => value.returnActiveRunFrame159(); case None => () } }
}

private func corePlanModelToolsActive159(view: ?OwnedActiveRunFrame159, thread: ThreadId,
    state: ?AgentValue, reviewControl: Bool, pipeline: ToolPipeline): Result<(?OwnedModelTools159, Array<ModelToolDefinition>)> {
    let active = match (view) { case Some(value) => value.snapshot159()
        case None => return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
            "run.model_lane_snapshot_missing", "active Run has no immutable ModelLane tool snapshot")) }
    match (validateCoreModelLane159(active.lane, thread)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    if (!reviewControl && state.isSome()) {
        let selection = active.lane.reserveModelToolSelection204()
        let result = try { corePlanSelectedModelTools204(active.lane, state.getOrThrow()) }
        catch (error: Exception) {
            // The whole private selection helper has returned. It exports no
            // name/schema alias on failure; independently created output
            // owners retain their own original unknown-copy obligations.
            match (selection) { case Some(value) => value.close(); case None => () }
            throw error
        }
        match (selection) { case Some(value) => value.close(); case None => () }
        return result
    }
    let owned = active.lane.ownedModelTools159()
    if (!reviewControl && state.isNone()) {
        return Result.Ok((owned, match (owned) { case Some(value) => value.definitionsForPreparedRequest159()
            case None => coreModelToolDefinitions(active.lane.toolSet) }))
    }
    let selection = match (owned) { case Some(value) => Some(value.reserveToolSelection159())
        case None => None<LogicalJsonOwnerReservation> }
    // Only this outer caller closes scratch, after the complete inner helper
    // that held arrays, copied names and frozen snapshot loans has returned.
    let result = try { corePlanModelToolsSelection159(active.lane, owned, thread, state, reviewControl, pipeline) }
    catch (error: Exception) { match (owned) { case Some(value) => value.holdUnknownRequestConsumer159(); case None => () }; throw error }
    match (selection) { case Some(value) => value.close(); case None => () }
    result
}

private func corePlanModelToolsSelection159(lane: ModelLane, owned: ?OwnedModelTools159, thread: ThreadId,
    state: ?AgentValue, reviewControl: Bool, pipeline: ToolPipeline): Result<(?OwnedModelTools159, Array<ModelToolDefinition>)> {
    let names = ArrayList<String>()
    if (reviewControl) {
        let shared = lane.forkOwnedToolSetSnapshot159()
        let selected = try { match (shared) {
            case Some(snapshot) => pipeline.reviewControlToolNames(snapshot, thread)
            case None => pipeline.reviewControlToolNames(lane.legacyToolSetSnapshot159().getOrThrow(), thread)
        } } finally { match (shared) { case Some(value) => value.close159(); case None => () } }
        for (name in selected) { names.add(name) }
    } else {
        match (state.getOrThrow().field("allowed_tools")) {
            case Some(values) => if (values.unifiedKind == ValueKind.List) {
                for (value in values.items where value.unifiedKind == ValueKind.Text) { names.add(value.text) }
            }
            case None => ()
        }
    }
    match (owned) {
        case Some(value) =>
            value.restrictPreparedDefinitions159(names.toArray())
            Result.Ok((owned, value.definitionsForPreparedRequest159()))
        case None =>
            let selected = ArrayList<ModelToolDefinition>()
            for (definition in coreModelToolDefinitions(lane.legacyToolSetSnapshot159().getOrThrow())) {
                if (planContains(names.toArray(), definition.name)) { selected.add(definition) }
            }
            Result.Ok((owned, selected.toArray()))
    }
}

private func corePlanSelectedModelTools204(lane: ModelLane, state: AgentValue): Result<(?OwnedModelTools159, Array<ModelToolDefinition>)> {
    let names = ArrayList<String>()
    match (state.field("allowed_tools")) {
        case Some(values) => if (values.unifiedKind == ValueKind.List) {
            for (value in values.items where value.unifiedKind == ValueKind.Text) { names.add(value.text) }
        }
        case None => ()
    }
    let owned = lane.selectedOwnedModelTools204(names.toArray())
    match (owned) {
        case Some(value) => Result.Ok((owned, value.definitionsForPreparedRequest159()))
        case None => planExecutionError("plan.model_tools_data_missing",
            "supervised request tools require their actual owned frozen snapshot")
    }
}
