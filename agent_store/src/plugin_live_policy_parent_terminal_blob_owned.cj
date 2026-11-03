package agent_store

import agent_domain.*

// Only physical metadata payment is borrowed. The prefix keeps its same
// owner and reference invoice through full same-TX metadata/FD/EOF checks.
// No close, Source grant, worker ACK, output lease release or SQL write occurs.
func requireLivePolicyParentTerminalBlobOwned(tx:SqliteTransaction,payload:PluginDocumentPayloadReference,
    owner:LogicalJsonOwnerReservation,extraRetained:Int64,verifyContent:()->Result<Unit>,guard:()->Result<Unit>):Unit{
    if(extraRetained<=0){throw IllegalStateException("terminal Blob borrower requires actual retained prefix payment")}
    payLivePolicyParentTerminalBlobMetadataOwned(tx,payload,owner,extraRetained,guard)
    requireDocumentPayloadMetadata(tx,payload);journalStreamCheck(guard)
    // Host supplies its already adopted exact FD/witness/full EOF hash
    // verifier. A Native pathname or a declared digest cannot open it.
    journalStreamCheck(verifyContent);journalStreamCheck(guard)
    payLivePolicyParentTerminalBlobMetadataOwned(tx,payload,owner,extraRetained,guard)
    requireDocumentPayloadMetadata(tx,payload);journalStreamCheck(guard)
}

// A trusted verifier need not mutate SQL, but the generic data callback can.
// Measure and pay before EACH complete metadata copy, retaining the actual
// caller prefix invoice. This never constructs an unbounded metadata String.
private func payLivePolicyParentTerminalBlobMetadataOwned(tx:SqliteTransaction,payload:PluginDocumentPayloadReference,
    owner:LogicalJsonOwnerReservation,extraRetained:Int64,guard:()->Result<Unit>):Unit{
    journalStreamCheck(guard)
    // Numeric metadata only until the complete original SQL copy is paid.
    // The original decoder retains its 4096-byte metadata boundary.
    let sizes=tx.query("SELECT length(CAST(mime AS BLOB)),length(CAST(size AS BLOB)),"+
        "length(CAST(metadata AS BLOB)),length(CAST(relative_path AS BLOB)) FROM artifacts WHERE hash=?",
        [SqlParameter.Text(payload.digest)])
    if(sizes.size!=1 || sizes[0].size!=4){throw IllegalStateException("terminal output has no unique actual Blob metadata")}
    var bytes:Int64=0
    for(index in 0..4){
        let size=journalStreamInteger(sizes[0].required(index))
        if(size<1){throw IllegalStateException("terminal output metadata cell is empty")}
        bytes=journalStreamAdd(bytes,size)
    }
    if(journalStreamInteger(sizes[0].required(2))>4096){
        throw IllegalStateException("terminal output metadata exceeds its original decoder bound")}
    owner.ensureRetainedPeak(journalStreamAdd(extraRetained,contextReadMetadataRawPeak(bytes)))
}
