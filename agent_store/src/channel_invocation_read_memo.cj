package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// Only the ordinary UserDirect v1 row proof is memoized. External, managed,
// ContextRead, Committed and payload-reference sources keep their original
// validators, including every time-sensitive and artifact-specific check.
// This is one <=64KiB read transcript per Store, not authority or a SQL cache:
// every recorded SELECT is re-executed in the same current transaction and all
// rows/columns/NULLs/absence must match. No I/O, handoff or mutation uses it.
class ChannelInvocationReadMemo {
    private var key = ""
    private var reads: Array<ChannelStartupMemoRead> = []

    func eligible(source: OperationRootSource, plan: NormalizedOperationPlan): Bool {
        let direct = match (source) { case OperationRootSource.Direct(value) => value; case _ => return false }
        match (direct.origin) { case DirectCallOrigin.UserDirect => (); case _ => return false }
        httpIntentText(plan.canonicalArguments.field("host_plan") ?? nullValue(), "version") == HOST_CHANNEL_INTENT_VERSION
    }

    func validate(transaction: SqliteTransaction, operation: OperationId, run: RunId, thread: ThreadId,
        epoch: Int64, source: OperationRootSource, plan: NormalizedOperationPlan, binding: AgentValue): Unit {
        try {
            channelStoreRequire(eligible(source, plan))
            let direct = match (source) { case OperationRootSource.Direct(value) => value
                case _ => throw IllegalStateException("ordinary Direct source required") }
            // These fields are immutable lets. AgentValue arguments/plan/binding
            // are mutable, so encode each once and validate decoded copies of
            // those exact bytes. No first-validation/key aliasing is possible.
            let planText = encodeOperationPlan(plan)
            let bindingText = encodeStoredValue(binding)
            let argumentsText = encodeStoredValue(direct.call.arguments)
            let nextKey = encodeStoredValue(listValue([
                textValue(operation.value), textValue(run.value), textValue(thread.value), integerValue(epoch),
                textValue(direct.operationId.value), textValue(direct.canonicalItemId.value),
                textValue(direct.threadId.value), textValue(direct.turnId.value), textValue(direct.runId.value),
                integerValue(direct.epoch), textValue(direct.call.callId), textValue(direct.call.name),
                textValue(planText), textValue(bindingText), textValue(argumentsText)]))
            if (!reads.isEmpty() && key == nextKey) {
                var unchanged = true
                for (read in reads) {
                    if (!read.matches(transaction.query(read.sql, read.parameters))) { unchanged = false; break }
                }
                if (unchanged) { return }
            }
            clear()
            let recording = ChannelStartupMemoRecording(nextKey.size, 0)
            let observed = SqliteTransaction(
                { _: String => throw IllegalStateException("channel proof must remain read-only") },
                { sql => recording.record(sql, [], transaction.query(sql)) },
                { _: String, _: Array<SqlParameter> => throw IllegalStateException("channel proof must remain read-only") },
                { sql, parameters => recording.record(sql, parameters, transaction.query(sql, parameters)) }, backendOwner:Some(transaction))
            // Deliberately do not nest the startup memo: record its full SQL
            // transcript along with the current root proof on this validation.
            requireChannelInvocationRoot(observed, operation, run, thread, epoch, source,
                decodeOperationPlan(planText), decodeStoredValue(bindingText),
                frozenDirectArguments: Some(decodeStoredValue(argumentsText)))
            if (recording.reusable()) { key = nextKey; reads = recording.takeReads() }
        } catch (error: Exception) { clear(); throw error }
    }
    func clear(): Unit { key = ""; reads = [] }
}
