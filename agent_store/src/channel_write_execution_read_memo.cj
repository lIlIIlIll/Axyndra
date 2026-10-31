package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// One shared bounded transcript for ordinary UserDirect channel writes and
// explicit payload-v2 root reads. A private role separates the two validators.
// Switching role evicts the prior proof; the existing single32MiB cap is unchanged.
// Every SQL query is re-executed in the current transaction, including absent
// rows, executing parent/child state, epoch, provenance, handoffs, payload
// metadata, startup receipt and exact ParentIntent authorization. It saves
// parsing only; it never grants admission, approval, a Source or an effect.
// External and managed sources keep their full live validators on every call.
class ChannelWriteExecutionReadMemo {
    private var identity = ""
    private var rootReadProof = false
    private var planText = ""
    private var bindingText = ""
    private var argumentsText = ""
    private var reads: Array<ChannelWriteMemoRead> = []

    func eligible(source: OperationRootSource): Bool {
        let direct = match (source) { case OperationRootSource.Direct(value) => value; case _ => return false }
        match (direct.origin) { case DirectCallOrigin.UserDirect => true; case _ => false }
    }

    func validateRoot(transaction: SqliteTransaction, operation: OperationId,
        run: RunId, thread: ThreadId, epoch: Int64, source: OperationRootSource,
        plan: NormalizedOperationPlan, binding: AgentValue,
        validateFull: (SqliteTransaction, NormalizedOperationPlan, AgentValue, ?AgentValue) -> Unit): Unit {
        validateProof(transaction, operation, operation, run, thread, epoch, source, "",
            plan, binding, validateFull, true)
    }

    func validate(transaction: SqliteTransaction, operation: OperationId, parent: OperationId,
        run: RunId, thread: ThreadId, epoch: Int64, source: OperationRootSource, requestKey: String,
        plan: NormalizedOperationPlan, binding: AgentValue,
        validateFull: (SqliteTransaction, NormalizedOperationPlan, AgentValue, ?AgentValue) -> Unit): Unit {
        validateProof(transaction, operation, parent, run, thread, epoch, source, requestKey,
            plan, binding, validateFull, false)
    }

    private func validateProof(transaction: SqliteTransaction, operation: OperationId, parent: OperationId,
        run: RunId, thread: ThreadId, epoch: Int64, source: OperationRootSource, requestKey: String,
        plan: NormalizedOperationPlan, binding: AgentValue,
        validateFull: (SqliteTransaction, NormalizedOperationPlan, AgentValue, ?AgentValue) -> Unit,
        rootReadProof: Bool): Unit {
        try {
            channelStoreRequire(eligible(source))
            let direct = match (source) { case OperationRootSource.Direct(value) => value
                case _ => throw IllegalStateException("ordinary Direct source required") }
            // AgentValue is mutable. Compare every current value/frame byte
            // against the successful frozen encoding on every reuse. A miss
            // still encodes and validates exact detached copies as before.
            let nextIdentity = encodeStoredValue(listValue([
                textValue(operation.value), textValue(parent.value), textValue(run.value),
                textValue(thread.value), integerValue(epoch), textValue(requestKey),
                textValue(direct.operationId.value), textValue(direct.canonicalItemId.value),
                textValue(direct.threadId.value), textValue(direct.turnId.value), textValue(direct.runId.value),
                integerValue(direct.epoch), textValue(direct.call.callId), textValue(direct.call.name)]))
            let sameInput = !reads.isEmpty() && this.rootReadProof == rootReadProof &&
                identity == nextIdentity && currentStoredValueMatches(storedOperationPlanValue(plan), planText) &&
                currentStoredValueMatches(binding, bindingText) &&
                currentStoredValueMatches(direct.call.arguments, argumentsText)
            if (sameInput) {
                var unchanged = true
                for (read in reads) {
                    // The actual DB owner compares every current column byte
                    // before stepping. Custom/mismatch paths query normally.
                    let exactMatch = transaction.matchesChannelWriteMemoRows(read)
                    if (!exactMatch) { unchanged = false; break }
                }
                if (unchanged) { return }
            }
            clear()
            let nextPlan = encodeOperationPlan(plan)
            let nextBinding = encodeStoredValue(binding)
            let nextArguments = encodeStoredValue(direct.call.arguments)
            // At most one transcript per lease: 32MiB shared immutable bytes, 128 queries, existing
            // 32-column/32-parameter/256-row limits. Oversize proofs still run
            // the full validator and are never retained or reused.
            let recording = ChannelWriteMemoRecording(nextIdentity.size + nextPlan.size + 1,
                nextBinding.size + nextArguments.size, maximumBytes: 33554432, maximumReads: 128)
            let observed = SqliteTransaction(
                { _: String => throw IllegalStateException("channel write proof must remain read-only") },
                { sql => recording.record(sql, [], transaction.query(sql)) },
                { _: String, _: Array<SqlParameter> => throw IllegalStateException("channel write proof must remain read-only") },
                { sql, parameters => recording.record(sql, parameters, transaction.query(sql, parameters)) }, backendOwner:Some(transaction))
            validateFull(observed, decodeOperationPlan(nextPlan), decodeStoredValue(nextBinding),
                Some(decodeStoredValue(nextArguments)))
            if (recording.reusable()) {
                this.rootReadProof = rootReadProof
                identity = nextIdentity; planText = nextPlan; bindingText = nextBinding
                argumentsText = nextArguments; reads = recording.takeReads()
            }
        } catch (error: Exception) { clear(); throw error }
    }

    private func clear(): Unit {
        rootReadProof = false
        identity = ""; planText = ""; bindingText = ""; argumentsText = ""; reads = []
    }
}
