package persistence_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.convert.*

// The legacy codec does not carry nonempty AttemptFailure/Observation. The
// actual 331 Store mapping has both None. Reject a future shape rather than
// silently erase either of the eight fields, or widen the historical codec.
func requireOwnedOuterErrorCodec333(error:AgentError):Result<Unit>{
    if(error.attemptFailure.isSome() || error.observation.isSome()){
        return ownedOuterErrorConsumerError333("run.owned_outer_error_codec_unsupported")}
    Result.Ok(())
}

func saveSqliteOwnedOuterError333(database:SqliteDatabase,value:OwnedOuterErrorFailure333):Result<Unit>{
    value.withSnapshot({snapshot,fund=>
        let error=snapshot.error.getOrThrow()
        match(requireOwnedOuterErrorCodec333(error)){case Result.Err(failure)=>return Result.Err(failure);case Result.Ok(_)=>()}
        // SUM: summary and error.message are separate serialized occurrences.
        // Conservatively includes full JSON escaping, writer growth/output,
        // parameter UTF8/C input and SQLite TEXT copies, plus all field nodes.
        let text=ownedOuterErrorAdd333(snapshot.summary.size,ownedOuterErrorAdd333(
            ownedOuterErrorScalarBytes333(error),ownedOuterErrorAdd333(snapshot.runId.value.size,snapshot.sessionId.value.size)))
        let peak=ownedOuterErrorAdd333(131072,ownedOuterErrorAdd333(
            ownedOuterErrorMultiply333(text,32),ownedOuterErrorMultiply333(error.fields.size,4096)))
        match(fund(peak)){case Result.Err(failure)=>return Result.Err(failure);case Result.Ok(_)=>()}
        try{database.transaction<Result<Unit>>({tx=>
            let lengths=tx.query("SELECT length(CAST(thread_id AS BLOB)) FROM runs WHERE id=? LIMIT 2",
                [SqlParameter.Text(snapshot.runId.value)])
            if(lengths.size!=1){return sqliteRunMissing<Unit>(snapshot.runId,"canonical Run row is missing")}
            let bytes=Int64.parse(lengths[0].required(0))
            match(fund(ownedOuterErrorAdd333(peak,ownedOuterErrorMultiply333(bytes,4)))){
                case Result.Err(failure)=>return Result.Err(failure);case Result.Ok(_)=>()}
            let rows=tx.query("SELECT thread_id FROM runs WHERE id=? LIMIT 2",[SqlParameter.Text(snapshot.runId.value)])
            if(rows.size!=1 || rows[0].required(0)!=snapshot.sessionId.value){
                return sqliteRunRecovery<Unit>(snapshot.runId,"Run session binding does not match its Thread")}
            // Same existing canonical row and full encodeSnapshot business
            // representation. No ownerless Run, new ledger or small preview.
            tx.execute("UPDATE runs SET app_snapshot=? WHERE id=?",
                [SqlParameter.Text(encodeSnapshot(snapshot)),SqlParameter.Text(snapshot.runId.value)])
            Result.Ok(())})
        }catch(_:Exception){ownedOuterErrorConsumerError333("run.owned_outer_error_snapshot_pending")}
    })
}

func appendSqliteOwnedOuterError333(database:SqliteDatabase,eventCapacity:Int64,
    value:OwnedOuterErrorFailure333):Result<Unit>{
    value.withDiagnostic({event,fund=>
        let error=match(event.payload){case AgentEventPayload.Diagnostic(actual)=>actual
            case _=>return ownedOuterErrorConsumerError333<Unit>("run.owned_outer_error_event_changed")}
        match(requireOwnedOuterErrorCodec333(error)){case Result.Err(failure)=>return Result.Err(failure);case Result.Ok(_)=>()}
        // The original append uses escaped JSON, SQL literal escaping and
        // complete concatenated SQL/C inputs. All coexisting representations
        // remain paid. This conservative bound is not an 8MiB capacity claim.
        let bytes=ownedOuterErrorAdd333(ownedOuterErrorScalarBytes333(error),ownedOuterErrorEventMetadataBytes333(event.meta))
        let peak=ownedOuterErrorAdd333(262144,ownedOuterErrorAdd333(
            ownedOuterErrorMultiply333(bytes,96),ownedOuterErrorMultiply333(error.fields.size,4096)))
        match(fund(peak)){case Result.Err(failure)=>return Result.Err(failure);case Result.Ok(_)=>()}
        try{database.transaction<Result<Unit>>({tx=>
            // Existing disposition checks may read an exact duplicate row.
            // Pay its complete extent under this same TX before that query.
            let lengths=tx.query("SELECT length(CAST(payload AS BLOB)) FROM app_run_events WHERE run_id=? AND sequence=? LIMIT 2",
                [SqlParameter.Text(event.runId.value),SqlParameter.Int64Value(event.sequence)])
            if(lengths.size>1){return runEventConflict<Unit>(event)}
            var prior:Int64=0
            for(row in lengths){prior=ownedOuterErrorAdd333(prior,Int64.parse(row.required(0)))}
            match(fund(ownedOuterErrorAdd333(peak,ownedOuterErrorMultiply333(prior,4)))){
                case Result.Err(failure)=>return Result.Err(failure);case Result.Ok(_)=>()}
            appendRunEventInTransaction(tx,event,eventCapacity,false)})
        }catch(_:Exception){ownedOuterErrorConsumerError333("run.owned_outer_error_diagnostic_pending")}
    })
}
