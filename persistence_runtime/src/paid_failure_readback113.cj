package persistence_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.convert.*

// This reader publishes DATA only. A callback which queues any metadata/error
// must first retain its OWN publication consumer; the local reader ACK cannot
// retire that share. The actual read owner outlives SQL text, grammar, decoded
// snapshot and both consumer construction/callback frames.
func readSqlitePaidFailureSnapshot113(database: SqliteDatabase, run: RunId, event: EventMeta,
    allocate: (Int64) -> LogicalJsonOwnerReservation,
    consume: (OwnedFailureRunPublication113) -> Unit): OwnedFailureDataOutcome113<Unit> {
    let owner = allocate(65536)
    try { readSqlitePaidFailureFrame113(database,run,event,allocate,consume,owner) }
    finally { owner.close() }
}
func readSqlitePaidFailureFrame113(database: SqliteDatabase, run: RunId, event: EventMeta,
    allocate: (Int64) -> LogicalJsonOwnerReservation, consume: (OwnedFailureRunPublication113) -> Unit,
    owner: LogicalJsonOwnerReservation): OwnedFailureDataOutcome113<Unit> {
    try {
        // Invoice actual identifiers/event fields before the FIRST SQL
        // parameter array or downstream metadata copy is constructed.
        let metadataPeak=ownedOuterErrorAdd333(1048576,ownedOuterErrorMultiply333(
            ownedOuterErrorAdd333(run.value.size,ownedOuterErrorEventMetadataBytes333(event)),8))
        owner.ensureRetainedPeak(metadataPeak)
        if (event.runId.value != run.value) { throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.InvalidInput,
            "data.failure_read_run_mismatch", "error data metadata must match the actual Run")) }
        // Never materialize the full column before its numeric extent is paid.
        let source = database.transaction<String> { tx: SqliteTransaction =>
            let lengths=tx.query("SELECT length(CAST(app_snapshot AS BLOB)),length(CAST(thread_id AS BLOB)) " +
                "FROM runs WHERE id=? LIMIT 2",[SqlParameter.Text(run.value)])
            if(lengths.size!=1 || lengths[0][0].isNone()) { throw OwnedCanonicalDataFailure113(
                AgentError(AgentErrorKind.Conflict,"persistence.sqlite_run_missing","Run has no product snapshot")) }
            let bytes=Int64.parse(lengths[0].required(0));let threadBytes=Int64.parse(lengths[0].required(1))
            if(bytes<0 || bytes>67108864 || threadBytes<0){throw OwnedCanonicalDataFailure113(AgentError(
                AgentErrorKind.RecoveryRequired,"data.failure_read_extent_changed","Run snapshot extent is invalid"))}
            owner.ensureRetainedPeak(ownedOuterErrorAdd333(metadataPeak,
                ownedOuterErrorMultiply333(ownedOuterErrorAdd333(bytes,threadBytes),8)))
            let rows=tx.query("SELECT app_snapshot,thread_id FROM runs WHERE id=? LIMIT 2",[SqlParameter.Text(run.value)])
            if(rows.size!=1 || rows[0].required(0).size!=bytes || rows[0].required(1).size!=threadBytes) {
                throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.RecoveryRequired,
                    "data.failure_read_extent_changed","Run snapshot extent changed inside its read transaction")) }
            let result=rows[0].required(0)
            // Exact original lexical grammar scan before constructing the DOM.
            // Three complete node representations cover the decoder, typed
            // attachment projection and immutable Observation constructor.
            let nodes=logicalJsonNodeCount(result)
            owner.ensureRetainedPeak(ownedOuterErrorAdd333(metadataPeak,ownedOuterErrorAdd333(
                ownedOuterErrorMultiply333(ownedOuterErrorAdd333(bytes,threadBytes),8),
                ownedOuterErrorMultiply333(nodes,1536))))
            let snapshot=match(decodeFailureSnapshot113(result)){case Result.Ok(v)=>v
                case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error)}
            if(snapshot.runId.value!=run.value || snapshot.sessionId.value!=rows[0].required(1)){
                throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.RecoveryRequired,
                    "data.failure_read_identity_changed","Run snapshot canonical Thread binding changed"))}
            result
        }
        // The complete canonical row/identity was proved above. Decode again
        // under the same still-live owner, after the SQL lock has released;
        // user data consumption never runs under the database mutex.
        let snapshot=match(decodeFailureSnapshot113(source)){case Result.Ok(v)=>v
            case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error)}
        let error=match(snapshot.error){case Some(v)=>v;case None=>throw OwnedCanonicalDataFailure113(
            AgentError(AgentErrorKind.InvalidInput,"data.failure_read_absent","Run snapshot has no failure data"))}
        let original=match(captureOwnedFailureData113<Unit>(error,allocate)){
            case OwnedFailureDataOutcome113.Failure(v)=>v
            case OwnedFailureDataOutcome113.Value(_)=>throw IllegalStateException("failure reader returned a value")}
        let publication = try {
            OwnedFailureRunPublication113(original,RunSnapshot(snapshot.runId,snapshot.sessionId,snapshot.status,
                sequence:snapshot.sequence,modelRequests:snapshot.modelRequests,usage:Some(snapshot.usage),
                lastInputTokens:snapshot.lastInputTokens,lastOutputTokens:snapshot.lastOutputTokens,
                lastRequestDurationMillis:snapshot.lastRequestDurationMillis,toolCalls:snapshot.toolCalls,
                turns:snapshot.turns,kind:snapshot.kind),event)
        } finally { original.acknowledgeAfterConsumption().value().getOrThrow() }
        try {
            try { consume(publication); OwnedFailureDataOutcome113<Unit>.Value(()) }
            catch(failure:OwnedCanonicalPaidFailure113){
                // The actual producer already paid and retained ALL eight
                // fields. Move its single consumer, without another clone or
                // generic exception-message replacement.
                OwnedFailureDataOutcome113<Unit>.Failure(failure.takeConsumer())}
            catch(failure:OwnedCanonicalDataFailure113){captureOwnedFailureData113<Unit>(failure.error,allocate)}
            catch(failure:Exception){captureOwnedFailureData113<Unit>(AgentError(AgentErrorKind.RecoveryRequired,
                "data.failure_read_consumer_failed",failure.message),allocate)}
        } finally { publication.acknowledgeAfterConsumption().value().getOrThrow() }
    } catch(failure:OwnedCanonicalPaidFailure113) {
        OwnedFailureDataOutcome113<Unit>.Failure(failure.takeConsumer()) }
    catch(failure:OwnedCanonicalDataFailure113) { captureOwnedFailureData113<Unit>(failure.error,allocate) }
    catch(failure:Exception) { captureOwnedFailureData113<Unit>(AgentError(AgentErrorKind.RecoveryRequired,
        "persistence.sqlite_run_read",failure.message),allocate) }
}
