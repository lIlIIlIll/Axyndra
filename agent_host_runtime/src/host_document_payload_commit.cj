package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.collection.*
import std.fs.*
import std.sync.*

// The existing ContextRead executor retains this inert resource before a file
// can open. The file is selected only by a private Store proof, never by IPC.
// A failed close retains this owner and its fixed buffer in the same 8 slots.
public class HostDocumentPayloadCommitReader <: PluginDocumentPayloadCommitter {
    private let run: RunId
    private let parent: OperationId
    private let operation: OperationId
    private let artifactLock: (() -> Result<Unit>) -> Result<Unit>
    private let path: (PluginDocumentPayloadReference) -> String
    private let guard: () -> Result<Unit>
    private let reservation: LogicalJsonFixedBufferReservation
    private let lock = Mutex()
    private var file: ?File = None
    private var started = false
    private var inCommit = false
    private var finished = false
    private var closed = false
    private var released = false

    public init(run: RunId, parent: OperationId, operation: OperationId,
        artifactLock: (() -> Result<Unit>) -> Result<Unit>, path: (PluginDocumentPayloadReference) -> String,
        guard: () -> Result<Unit>, reservation: LogicalJsonFixedBufferReservation) {
        this.run=run;this.parent=parent;this.operation=operation;this.artifactLock=artifactLock
        this.path=path;this.guard=guard;this.reservation=reservation
    }
    private func closeFile(): Result<Unit> {
        try {
            match(file) { case Some(value) => value.close();file=None;case None => () }
            Result.Ok(())
        } catch(_: Exception) { hostPluginResourceError("plugin.document_payload_cleanup_pending", "document input file remains owned") }
    }
    private func cleanup(): Result<Unit> {
        match(closeFile()) { case Result.Err(error) => return Result.Err(error);case Result.Ok(_) => () }
        if (!released) { reservation.close();released=true }
        Result.Ok(())
    }
    public func collect(): Bool {
        lock.lock();try { finished && cleanup().isOk() } finally { lock.unlock() }
    }
    public func close(): Result<Unit> {
        lock.lock();try { closed=true;finished=true;cleanup() } finally { lock.unlock() }
    }
    // The caller already holds the Host generation lock. Keep lock order
    // generation -> this owner -> artifact -> canonical DB throughout CAS.
    public func runCommit(action: (PluginDocumentPayloadCommitter) -> Result<Unit>): Result<Unit> {
        lock.lock()
        try {
            if (closed || started) { return hostPluginResourceError("plugin.document_payload_reader_closed", "document commit reader is one-shot") }
            started=true;inCommit=true
            let result=try { artifactLock({ => action(this) }) }
                catch(_: Exception) { Result<Unit>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "plugin.document_payload_commit_unknown", "document transaction or content verification was interrupted")) }
                finally { inCommit=false;finished=true }
            match(cleanup()) { case Result.Err(error) => return Result.Err(error);case Result.Ok(_) => () }
            result
        } finally { lock.unlock() }
    }
    public func commit(value: PluginDocumentPayloadCommitProof): Result<Unit> {
        // Synchronous callback under runCommit, not a second reader lock.
        if (!inCommit || closed || file.isSome() || value.runId.value != run.value ||
            value.parentOperationId.value != parent.value || value.operationId.value != operation.value) {
            return hostPluginResourceError("plugin.document_payload_scope_changed", "document replacement belongs to another actual child") }
        // The actual child identity check above also guards the window
        // proof. Its Store transaction pays each copied source separately.
        match(value as SqlitePluginRowJournalCommitProof) {
            case Some(actual) => return actual.materialize({reference=>readContent(reference)})
            case None => () }
        let proof=match(value as SqlitePluginDocumentPayloadCommitProof) {
            case Some(actual) => actual
            case None => return hostPluginResourceError("plugin.document_payload_proof_invalid", "replacement requires the actual supplied Store transaction") }
        proof.materialize({ reference => readContent(reference) })
    }
    private func readContent(reference: PluginDocumentPayloadReference): Result<String> {
        match(guard()) { case Result.Err(error) => return Result.Err(error);case Result.Ok(_) => () }
        try {
            let selected=path(reference)
            let before=FileInfo(Path(selected))
            if (!before.isRegular() || before.isSymbolicLink() || before.size != reference.bytes) {
                return hostPluginResourceError("plugin.document_payload_file_changed", "replacement content size or kind changed") }
            let opened=File(selected,OpenMode.Read);file=Some(opened)
            // Ownership precedes metadata and allocations. Any throw below
            // leaves the actual file reachable for runCommit/host-close retry.
            if (!opened.info.isRegular() || opened.info.size != reference.bytes) {
                return hostPluginResourceError("plugin.document_payload_file_changed", "opened replacement content changed") }
            let buffer=Array<Byte>(16384,repeat:0);let bytes=ArrayList<Byte>()
            while(true) {
                match(guard()) { case Result.Err(error) => return Result.Err(error);case Result.Ok(_) => () }
                let count=opened.read(buffer)
                if(count==0) { break }
                if(count>reference.bytes-bytes.size) { return hostPluginResourceError("plugin.document_payload_file_changed", "replacement exceeds its frozen size") }
                bytes.add(all:buffer[..count])
            }
            if(bytes.size != reference.bytes) { return hostPluginResourceError("plugin.document_payload_file_changed", "replacement is incomplete") }
            let raw=String.fromUtf8(bytes.toArray())
            match(guard()) { case Result.Err(error) => return Result.Err(error);case Result.Ok(_) => () }
            match(closeFile()) { case Result.Err(error) => return Result.Err(error);case Result.Ok(_) => () }
            Result.Ok(raw)
        } catch(_: Exception) { hostPluginResourceError("plugin.document_payload_read_failed", "replacement content could not be read") }
    }
}

public class HostArtifactOperationFailure <: Exception {
    public let failure: AgentError
    public init(failure: AgentError) { super(failure.message);this.failure=failure }
}
