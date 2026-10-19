package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import agent_extension_runtime.*
import std.sync.*

// One real ContextRead owns this object before it can open a temporary file.
// Callers must retain close() failures in that executor's existing cleanup
// collection. No new artifact registry, source, budget or worker handle exists.
public class HostDocumentPayloadReader <: PluginDocumentPayloadMaterializer {
    private let lock = Mutex()
    private let invoke: (PluginDocumentPayloadMaterializer) -> Result<AgentValue>
    private let createWriter: () -> Result<HostServiceArtifactWriter>
    private let publish: (SqliteTransaction, HostServiceArtifactWriter) -> Result<AgentValue>
    private let guard: () -> Result<Unit>
    private var active: ?HostServiceArtifactWriter = None
    private var started = false
    private var inRead = false
    private var closed = false

    public init(invoke: (PluginDocumentPayloadMaterializer) -> Result<AgentValue>,
        createWriter: () -> Result<HostServiceArtifactWriter>,
        publish: (SqliteTransaction, HostServiceArtifactWriter) -> Result<AgentValue>, guard: () -> Result<Unit>) {
        this.invoke = invoke; this.createWriter = createWriter; this.publish = publish; this.guard = guard
    }
    private func cleanup(): Result<Unit> {
        match (active) {
            case Some(value) => match (value.close()) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => active = None }
            case None => () }
        Result.Ok(())
    }
    public func close(): Result<Unit> {
        lock.lock(); try { closed = true; cleanup() } finally { lock.unlock() }
    }
    public func read(): Result<AgentValue> {
        lock.lock()
        try {
            if (closed || started) { return hostPluginResourceError("plugin.document_payload_reader_closed", "document reader is one-shot") }
            started = true; inRead = true
            let result = try { invoke(this) } catch (_: Exception) {
                Result<AgentValue>.Err(AgentError(AgentErrorKind.Internal, "plugin.document_payload_materialize_failed",
                    "the canonical document payload could not be materialized")) }
            finally { inRead = false }
            match (cleanup()) {
                case Result.Err(_) => return hostPluginResourceError("plugin.document_payload_cleanup_pending", "document writer cleanup remains owned")
                case Result.Ok(_) => () }
            result
        } finally { lock.unlock() }
    }
    public func materialize(value: PluginDocumentPayloadReadProof): Result<AgentValue> {
        // Invoked synchronously only by invoke() under the same owner mutex.
        // A later callback cannot reopen a completed/failed reader or writer.
        if (!inRead || closed || active.isSome()) {
            return hostPluginResourceError("plugin.document_payload_window_closed", "document materialization window is closed") }
        // A new Store proof is accepted only inside the same already-open
        // materialization window. The default proof path remains unchanged.
        match (value as SqlitePluginDocumentWindowReadProof) {
            case Some(actual) => return materializeWindow(actual)
            case None => () }
        let proof = match (value as SqlitePluginDocumentPayloadReadProof) {
            case Some(actual) => actual
            case None => return hostPluginResourceError("plugin.document_payload_proof_invalid", "document materialization requires its actual Store proof") }
        match (guard()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        // Reserve before proof.materialize can select/copy the raw row. One
        // document's byte lease ends before the next row, not after all keys.
        let reservation = try { reserveNativeDocumentPayload(proof.bytes) }
            catch (_: Exception) { return hostPluginResourceError("plugin.document_payload_capacity", "shared payload allocation budget is exhausted") }
        try {
            proof.materialize({ transaction, snapshot, digest =>
                match (guard()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                let writer = match (createWriter()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(created) => created }
                active = Some(writer)
                match (writer.open()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                let bytes = snapshot.encoded.toArray()
                var offset: Int64 = 0
                while (offset < bytes.size) {
                    match (guard()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    let end = min(bytes.size, offset + 16384)
                    match (writer.appendBytes(offset, bytes[offset..end], max(1, bytes.size))) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    offset = end
                }
                match (writer.finish(bytes.size, digest)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                let result = publish(transaction, writer)
                match (guard()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                match (cleanup()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                result
            })
        } finally {
            // A failed File close retains only its writer/fixed workspace.
            // The raw row and all parsing/hash copies cannot escape this call.
            reservation.close()
        }
    }
    private func materializeWindow(proof: SqlitePluginDocumentWindowReadProof): Result<AgentValue> {
        match (guard()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        // Reserve before proof.materialize can select/copy the raw row. One
        // document's byte lease ends before the next row, not after all keys.
        let reservation = try { reserveNativeDocumentPayload(proof.bytes) }
            catch (_: Exception) { return hostPluginResourceError("plugin.document_payload_capacity", "shared payload allocation budget is exhausted") }
        try {
            proof.materialize({ transaction, snapshot, digest =>
                match (guard()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                let writer = match (createWriter()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(created) => created }
                active = Some(writer)
                match (writer.open()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                let bytes = snapshot.encoded.toArray()
                var offset: Int64 = 0
                while (offset < bytes.size) {
                    match (guard()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    let end = min(bytes.size, offset + 16384)
                    match (writer.appendBytes(offset, bytes[offset..end], max(1, bytes.size))) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    offset = end
                }
                match (writer.finish(bytes.size, digest)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                let result = publish(transaction, writer)
                match (guard()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                match (cleanup()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                result
            })
        } finally {
            // A failed File close retains only its writer/fixed workspace.
            // The raw row and all parsing/hash copies cannot escape this call.
            reservation.close()
        }
    }
}
