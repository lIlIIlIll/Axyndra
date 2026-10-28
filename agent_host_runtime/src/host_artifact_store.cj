package agent_host_runtime

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_runtime.*
import agent_store.*
import agent_store as input_store
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.process.*
import std.sync.*
import stdx.crypto.digest.*

public let HOST_ARTIFACT_PREVIEW_BYTES: Int64 = 1048576
public let HOST_ARTIFACT_CONTENT_TYPE = "text/plain; charset=utf-8"
public let HOST_ARTIFACT_PREFIX = "blob:sha256:"

public class HostArtifact {
    public let reference: String
    public let sha256: String
    public let bytes: Int64
    public let contentType: String

    public init(
        reference: String,
        sha256: String,
        bytes: Int64,
        contentType!: String = HOST_ARTIFACT_CONTENT_TYPE
    ) {
        this.reference = reference
        this.sha256 = sha256
        this.bytes = bytes
        this.contentType = contentType
    }

    public func value(stream!: String = ""): AgentValue {
        let fields = ArrayList<ValueField>()
        if (stream != "") {
            fields.add(ValueField("stream", textValue(stream)))
        }
        fields.add(ValueField("ref", textValue(reference)))
        fields.add(ValueField("sha256", textValue(sha256)))
        fields.add(ValueField("bytes", integerValue(bytes)))
        fields.add(ValueField("content_type", textValue(contentType)))
        objectValue(fields.toArray())
    }
}

public class HostArtifactRead {
    public let reference: String
    public let content: String
    public let bytes: Int64
    public let offset: Int64
    public let returnedBytes: Int64
    public let truncated: Bool
    public let contentType: String

    public init(
        reference: String,
        content: String,
        bytes: Int64,
        offset: Int64,
        returnedBytes: Int64,
        truncated: Bool,
        contentType!: String = HOST_ARTIFACT_CONTENT_TYPE
    ) {
        this.reference = reference
        this.content = content
        this.bytes = bytes
        this.offset = offset
        this.returnedBytes = returnedBytes
        this.truncated = truncated
        this.contentType = contentType
    }

    public func value(): AgentValue {
        objectValue(
            [
                ValueField("path", textValue(reference)),
                ValueField("artifact_ref", textValue(reference)),
                ValueField("content", textValue(content)),
                ValueField("bytes", integerValue(bytes)),
                ValueField("returned_bytes", integerValue(returnedBytes)),
                ValueField("offset", integerValue(offset)),
                ValueField("truncated", boolValue(truncated)),
                ValueField("content_type", textValue(contentType)),
                ValueField("immutable", boolValue(true))
            ]
        )
    }
}

public class HostArtifactCapture {
    public let stream: String
    public let preview: String
    public let bytes: Int64
    public let truncated: Bool
    public let artifact: ?HostArtifact
    public let error: ?AgentError

    public init(
        stream: String,
        preview: String,
        bytes: Int64,
        truncated: Bool,
        artifact!: ?HostArtifact = None,
        error!: ?AgentError = None
    ) {
        this.stream = stream
        this.preview = preview
        this.bytes = bytes
        this.truncated = truncated
        this.artifact = artifact
        this.error = error
    }
}

// Content-addressed storage for complete textual tool output. The store never
// accepts a filesystem path from a model: callers provide either text or a
// strictly validated blob:sha256 reference.
public class HostArtifactStore {
    private let root: String
    private let previewBytes: Int64
    private let database: ?SqliteDatabase
    private let operations: ?DurableOperationStore
    private let lock = Mutex()

    public init(
        stateRoot: String,
        previewBytes!: Int64 = HOST_ARTIFACT_PREVIEW_BYTES,
        database!: ?SqliteDatabase = None,
        operations!: ?DurableOperationStore = None
    ) {
        if (stateRoot.trimAscii() == "") {
            throw IllegalArgumentException("artifact state root must not be empty")
        }
        if (previewBytes < 256 || previewBytes > HOST_ARTIFACT_PREVIEW_BYTES) {
            throw IllegalArgumentException("artifact preview limit must be between 256 bytes and 1 MiB")
        }
        this.root = Path(stateRoot).normalize().toString() + "/blobs"
        this.previewBytes = previewBytes
        this.database = database
        this.operations = operations
    }

    public func capture(stream: String, content: String): HostArtifactCapture {
        let bytes = content.toArray()
        if (bytes.size <= previewBytes) {
            return HostArtifactCapture(stream, content, bytes.size, false)
        }
        let preview = hostArtifactPreview(bytes, previewBytes)
        match (persistText(content)) {
            case Result.Ok(artifact) => HostArtifactCapture(
                stream,
                preview,
                bytes.size,
                true,
                artifact: Some(artifact)
            )
            case Result.Err(error) => HostArtifactCapture(
                stream,
                preview,
                bytes.size,
                true,
                error: Some(error)
            )
        }
    }

    // Explicit persistence is also the user-facing API used before exporting
    // a small value; normal Bash/Eval capture only calls it for oversized
    // streams.
    public func persistText(content: String): Result<HostArtifact> {
        let bytes = content.toArray()
        let hash = hostArtifactSha256(bytes)
        let artifact = HostArtifact(
            HOST_ARTIFACT_PREFIX + hash,
            hash,
            bytes.size
        )
        lock.lock()
        try {
            match (ensureArtifactRoot()) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            match (persistArtifactFile(artifact, bytes)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            match (persistArtifactMetadata(artifact)) {
                case Result.Ok(_) => Result.Ok(artifact)
                case Result.Err(error) => Result.Err(error)
            }
        } finally {
            lock.unlock()
        }
    }

    // Creates an inert owner: no file exists until its actual ContextRead
    // executor has retained the returned reader and calls read(). The lock
    // order is artifact store -> canonical DB, matching existing artifact GC
    // pin paths; no callback acquires this lock from inside a DB transaction.
    public func documentPayloadReader(operations: OperationRuntimePort, source: DirectToolCallRef,
        plan: NormalizedOperationPlan, guard: () -> Result<Unit>,
        observer: ?PluginDocumentReadObserver): HostDocumentPayloadReader {
        HostDocumentPayloadReader({ materializer =>
            lock.lock()
            try {
                match (guard()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                match (ensureArtifactRoot()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                operations.readPluginDocuments(source, plan, guard, observer, Some(materializer))
            } finally { lock.unlock() }
        }, { =>
            var reserved: ?LogicalJsonFixedBufferReservation = None
            try {
                let charge = reserveNativeObservationBuffer(); reserved = Some(charge)
                Result.Ok(HostServiceArtifactWriter(root, charge))
            } catch (_: Exception) {
                match (reserved) { case Some(charge) => charge.close(); case None => () }
                hostArtifactError<HostServiceArtifactWriter>(AgentErrorKind.Internal,
                    "artifact.document_reservation_failed", "document writer reservation failed", "")
            }
        }, { transaction, writer =>
            let artifact = writer.completedArtifact()
            match (guard()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (writer.publish(blobPath(artifact.sha256))) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            // The original read owns this supplied transaction. Do not call
            // persistArtifactMetadata(), which would open another DB scope.
            transaction.execute("INSERT OR IGNORE INTO artifacts(hash,mime,size,metadata,relative_path) VALUES(?,?,?,?,?)",
                [SqlParameter.Text(artifact.sha256), SqlParameter.Text(artifact.contentType),
                    SqlParameter.Int64Value(artifact.bytes), SqlParameter.Text(hostArtifactMetadata(artifact)),
                    SqlParameter.Text("blobs/" + artifact.sha256 + ".txt")])
            let rows = transaction.query("SELECT mime,size,metadata,relative_path FROM artifacts WHERE hash=?",
                [SqlParameter.Text(artifact.sha256)])
            if (rows.size != 1 || rows[0].required(0) != artifact.contentType || rows[0].required(1) != artifact.bytes.toString() ||
                rows[0].required(2) != hostArtifactMetadata(artifact) || rows[0].required(3) != "blobs/" + artifact.sha256 + ".txt") {
                return hostArtifactError<AgentValue>(AgentErrorKind.Conflict, "artifact.document_metadata_conflict",
                    "existing artifact has different MIME, bytes, path or metadata", artifact.reference) }
            match (guard()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            Result.Ok(objectValue([ValueField("schema", textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),
                ValueField("artifact_ref", textValue(artifact.reference)), ValueField("encoding", textValue("utf8")),
                ValueField("bytes", integerValue(artifact.bytes)), ValueField("sha256", textValue(artifact.sha256)),
                ValueField("content_type", textValue(artifact.contentType))]))
        }, guard)
    }

    // Inert separate dialect: the executor retains this owner before read.
    // Lock order stays artifacts -> DB; its SQL guard must only inspect
    // atomic/immutable/pure configuration state, never reacquire Host locks.
    public func journalStreamPayloadReader(operations:OperationRuntimePort,source:DirectToolCallRef,
        plan:NormalizedOperationPlan,guard:()->Result<Unit>):HostJournalStreamPayloadReader{
        HostJournalStreamPayloadReader({materializer=>
            lock.lock()
            try{
                match(guard()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
                match(ensureArtifactRoot()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
                operations.readPluginDocumentJournalStream(source,plan,guard,materializer)
            }finally{lock.unlock()}
        },{=>
            var reserved:?LogicalJsonFixedBufferReservation=None
            try{
                let charge=reserveNativeObservationBuffer();reserved=Some(charge)
                Result<HostServiceArtifactWriter>.Ok(HostServiceArtifactWriter(root,charge))
            }catch(_:Exception){
                match(reserved){case Some(charge)=>charge.close();case None=>()}
                hostArtifactError<HostServiceArtifactWriter>(AgentErrorKind.Internal,
                    "artifact.journal_stream_reservation_failed","shared stream writer reservation failed","")}
        },{transaction,writer=>
            let completed=writer.completedArtifact()
            let artifact=HostArtifact(completed.reference,completed.sha256,completed.bytes,
                contentType:PLUGIN_DOCUMENT_JOURNAL_STREAM_CONTENT_TYPE)
            match(guard()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            match(writer.publish(blobPath(artifact.sha256),guard:guard)){
                case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            // Same actual ContextRead transaction; no second DB/write scope.
            let metadata=hostArtifactMetadata(artifact)
            transaction.execute("INSERT OR IGNORE INTO artifacts(hash,mime,size,metadata,relative_path) VALUES(?,?,?,?,?)",
                [SqlParameter.Text(artifact.sha256),SqlParameter.Text(artifact.contentType),SqlParameter.Int64Value(artifact.bytes),
                    SqlParameter.Text(metadata),SqlParameter.Text("blobs/"+artifact.sha256+".txt")])
            let rows=transaction.query("SELECT mime,size,metadata,relative_path FROM artifacts WHERE hash=?",[SqlParameter.Text(artifact.sha256)])
            if(rows.size!=1 || rows[0].required(0)!=artifact.contentType || rows[0].required(1)!=artifact.bytes.toString() ||
                rows[0].required(2)!=metadata || rows[0].required(3)!="blobs/"+artifact.sha256+".txt"){
                return hostArtifactError<AgentValue>(AgentErrorKind.Conflict,"artifact.journal_stream_metadata_conflict",
                    "stream artifact metadata differs from its actual immutable file",artifact.reference)}
            match(guard()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            let value=objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_JOURNAL_STREAM_REFERENCE_SCHEMA)),
                ValueField("artifact_ref",textValue(artifact.reference)),ValueField("encoding",textValue(PLUGIN_DOCUMENT_JOURNAL_STREAM_ENCODING)),
                ValueField("bytes",integerValue(artifact.bytes)),ValueField("sha256",textValue(artifact.sha256)),
                ValueField("content_type",textValue(artifact.contentType))])
            match(parsePluginDocumentJournalStreamReference(value)){
                case Result.Err(error)=>Result<AgentValue>.Err(error);case Result.Ok(_)=>Result<AgentValue>.Ok(value)}
        },guard)
    }

    // Inert separate dialect: the executor retains this owner before read.
    // Lock order stays artifacts -> DB; its SQL guard must only inspect
    // atomic/immutable/pure configuration state, never reacquire Host locks.
    public func latestJournalStreamPayloadReader(operations:OperationRuntimePort,source:DirectToolCallRef,
        plan:NormalizedOperationPlan,guard:()->Result<Unit>):HostLatestJournalStreamPayloadReader{
        HostLatestJournalStreamPayloadReader({materializer=>
            lock.lock()
            try{
                match(guard()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
                match(ensureArtifactRoot()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
                operations.readPluginDocumentLatestJournalStream(source,plan,guard,materializer)
            }finally{lock.unlock()}
        },{=>
            var reserved:?LogicalJsonFixedBufferReservation=None
            try{
                let charge=reserveNativeObservationBuffer();reserved=Some(charge)
                Result<HostServiceArtifactWriter>.Ok(HostServiceArtifactWriter(root,charge))
            }catch(_:Exception){
                match(reserved){case Some(charge)=>charge.close();case None=>()}
                hostArtifactError<HostServiceArtifactWriter>(AgentErrorKind.Internal,
                    "artifact.journal_stream_reservation_failed","shared stream writer reservation failed","")}
        },{transaction,writer=>
            let completed=writer.completedArtifact()
            let artifact=HostArtifact(completed.reference,completed.sha256,completed.bytes,
                contentType:PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_CONTENT_TYPE)
            match(guard()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            match(writer.publish(blobPath(artifact.sha256),guard:guard)){
                case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            // Same actual ContextRead transaction; no second DB/write scope.
            let metadata=hostArtifactMetadata(artifact)
            transaction.execute("INSERT OR IGNORE INTO artifacts(hash,mime,size,metadata,relative_path) VALUES(?,?,?,?,?)",
                [SqlParameter.Text(artifact.sha256),SqlParameter.Text(artifact.contentType),SqlParameter.Int64Value(artifact.bytes),
                    SqlParameter.Text(metadata),SqlParameter.Text("blobs/"+artifact.sha256+".txt")])
            let rows=transaction.query("SELECT mime,size,metadata,relative_path FROM artifacts WHERE hash=?",[SqlParameter.Text(artifact.sha256)])
            if(rows.size!=1 || rows[0].required(0)!=artifact.contentType || rows[0].required(1)!=artifact.bytes.toString() ||
                rows[0].required(2)!=metadata || rows[0].required(3)!="blobs/"+artifact.sha256+".txt"){
                return hostArtifactError<AgentValue>(AgentErrorKind.Conflict,"artifact.journal_stream_metadata_conflict",
                    "stream artifact metadata differs from its actual immutable file",artifact.reference)}
            match(guard()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            let value=objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_REFERENCE_SCHEMA)),
                ValueField("artifact_ref",textValue(artifact.reference)),ValueField("encoding",textValue(PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_ENCODING)),
                ValueField("bytes",integerValue(artifact.bytes)),ValueField("sha256",textValue(artifact.sha256)),
                ValueField("content_type",textValue(artifact.contentType))])
            match(parsePluginDocumentLatestJournalStreamReference(value)){
                case Result.Err(error)=>Result<AgentValue>.Err(error);case Result.Ok(_)=>Result<AgentValue>.Ok(value)}
        },guard)
    }

    public func documentWindowPayloadReader(operations: OperationRuntimePort, source: DirectToolCallRef,
        plan: NormalizedOperationPlan, guard: () -> Result<Unit>,
        observer: ?PluginDocumentReadObserver): HostDocumentPayloadReader {
        HostDocumentPayloadReader({ materializer =>
            lock.lock()
            try {
                match (guard()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                match (ensureArtifactRoot()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                operations.readPluginDocumentWindows(source, plan, guard, materializer)
            } finally { lock.unlock() }
        }, { =>
            var reserved: ?LogicalJsonFixedBufferReservation = None
            try {
                let charge = reserveNativeObservationBuffer(); reserved = Some(charge)
                Result.Ok(HostServiceArtifactWriter(root, charge))
            } catch (_: Exception) {
                match (reserved) { case Some(charge) => charge.close(); case None => () }
                hostArtifactError<HostServiceArtifactWriter>(AgentErrorKind.Internal,
                    "artifact.document_reservation_failed", "document writer reservation failed", "")
            }
        }, { transaction, writer =>
            let artifact = writer.completedArtifact()
            match (guard()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (writer.publish(blobPath(artifact.sha256))) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            // The original read owns this supplied transaction. Do not call
            // persistArtifactMetadata(), which would open another DB scope.
            transaction.execute("INSERT OR IGNORE INTO artifacts(hash,mime,size,metadata,relative_path) VALUES(?,?,?,?,?)",
                [SqlParameter.Text(artifact.sha256), SqlParameter.Text(artifact.contentType),
                    SqlParameter.Int64Value(artifact.bytes), SqlParameter.Text(hostArtifactMetadata(artifact)),
                    SqlParameter.Text("blobs/" + artifact.sha256 + ".txt")])
            let rows = transaction.query("SELECT mime,size,metadata,relative_path FROM artifacts WHERE hash=?",
                [SqlParameter.Text(artifact.sha256)])
            if (rows.size != 1 || rows[0].required(0) != artifact.contentType || rows[0].required(1) != artifact.bytes.toString() ||
                rows[0].required(2) != hostArtifactMetadata(artifact) || rows[0].required(3) != "blobs/" + artifact.sha256 + ".txt") {
                return hostArtifactError<AgentValue>(AgentErrorKind.Conflict, "artifact.document_metadata_conflict",
                    "existing artifact has different MIME, bytes, path or metadata", artifact.reference) }
            match (guard()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            Result.Ok(objectValue([ValueField("schema", textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),
                ValueField("artifact_ref", textValue(artifact.reference)), ValueField("encoding", textValue("utf8")),
                ValueField("bytes", integerValue(artifact.bytes)), ValueField("sha256", textValue(artifact.sha256)),
                ValueField("content_type", textValue(artifact.contentType))]))
        }, guard)
    }

    // The caller already owns this completed writer. Artifact bytes and the
    // exact pending-parent preparation witness become retained in one supplied
    // canonical transaction. A failed transaction leaves only a collectible
    // content-addressed orphan, never a prepared document authority.
    public func retainDocumentPayloadReplacement(link: ContextReadFactLink, intent: AgentValue,
        writer: HostServiceArtifactWriter, guard: () -> Result<Unit>): Result<Unit> {
        lock.lock()
        try {
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let selected=parsePluginDocumentIntent(intent).value().getOrThrow()
            if(!selected.referencesPayload || !selected.compareExchange || database.isNone()) {
                return hostResourceError("plugin.document_payload_preparation_invalid") }
            let expected=selected.nextPayload.getOrThrow();let artifact=writer.completedArtifact()
            if(expected.digest!=artifact.sha256 || expected.bytes!=artifact.bytes) {
                return hostResourceError("plugin.document_payload_preparation_changed") }
            match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let destination=blobPath(artifact.sha256)
            match(writer.publish(destination,guard:guard)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            database.getOrThrow().transaction { transaction =>
                transaction.execute("INSERT OR IGNORE INTO artifacts(hash,mime,size,metadata,relative_path) VALUES(?,?,?,?,?)",
                    [SqlParameter.Text(artifact.sha256),SqlParameter.Text(artifact.contentType),SqlParameter.Int64Value(artifact.bytes),
                        SqlParameter.Text(hostArtifactMetadata(artifact)),SqlParameter.Text("blobs/"+artifact.sha256+".txt")])
                match(guard()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
                match(retainPreparedPluginDocumentPayload(transaction,link,intent,{ bytes=>reserveNativeDocumentPayload(bytes) },
                    {=>writer.verifyCanonicalDocument(destination,guard)})) {
                    case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
                match(guard()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
            }
            Result.Ok(())
        } catch(error: HostArtifactOperationFailure){Result.Err(error.failure)}
        catch(_: Exception){hostResourceError("plugin.document_payload_preparation_failed")}
        finally{lock.unlock()}
    }

    public func retainDocumentWindowPayload(links: Array<ContextReadFactLink>, intent: AgentValue,
        writer: HostServiceArtifactWriter, guard: () -> Result<Unit>): Result<Unit> {
        lock.lock()
        try {
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let selected=parsePluginDocumentRowJournalIntent(intent).value().getOrThrow()
            if(!selected.append || links.isEmpty() || links.size>8 || database.isNone()) {
                return hostResourceError("plugin.document_payload_preparation_invalid") }
            let expected=selected.nextPayload.getOrThrow();let artifact=writer.completedArtifact()
            if(expected.digest!=artifact.sha256 || expected.bytes!=artifact.bytes) {
                return hostResourceError("plugin.document_payload_preparation_changed") }
            match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let destination=blobPath(artifact.sha256)
            match(writer.publish(destination,guard:guard)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            database.getOrThrow().transaction { transaction =>
                transaction.execute("INSERT OR IGNORE INTO artifacts(hash,mime,size,metadata,relative_path) VALUES(?,?,?,?,?)",
                    [SqlParameter.Text(artifact.sha256),SqlParameter.Text(artifact.contentType),SqlParameter.Int64Value(artifact.bytes),
                        SqlParameter.Text(hostArtifactMetadata(artifact)),SqlParameter.Text("blobs/"+artifact.sha256+".txt")])
                match(guard()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
                match(retainPreparedPluginDocumentWindowPayload(transaction,links,intent,{ bytes=>reserveNativeDocumentPayload(bytes) },
                    {=>writer.verifyCanonicalDocument(destination,guard)})) {
                    case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
                match(guard()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
            }
            Result.Ok(())
        } catch(error: HostArtifactOperationFailure){Result.Err(error.failure)}
        catch(_: Exception){hostResourceError("plugin.document_payload_preparation_failed")}
        finally{lock.unlock()}
    }

    public func documentPayloadCommitReader(run: RunId, parent: OperationId, operation: OperationId,
        guard: () -> Result<Unit>): HostDocumentPayloadCommitReader {
        // Fixed workspace only. Store reserves the actual raw/decoded content
        // before this reader's callback, so there is no duplicate 8x charge.
        let reservation=reserveNativeObservationBuffer()
        try { HostDocumentPayloadCommitReader(run,parent,operation,{ action =>
            lock.lock();try {
                match(ensureArtifactRoot()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                action()
            } finally { lock.unlock() }
        },{ reference => blobPath(reference.digest) },guard,reservation) }
        catch(error: Exception) { reservation.close();throw error }
    }

    // The outer trusted worker loan already owns entry.invokeLock. Capture
    // no Host/Runtime locks here: Artifact mutex -> actual SQL -> fixed fd and
    // zero-services captured-worker RPC. No authorize-only result escapes TX.
    public func latestJournalInputReader(link:ContextReadFactLink,binding:AgentValue,data:AgentValue,
        current:()->Result<Unit>,consume:(Int64,Array<Byte>)->Result<Unit>,end:(Int64)->Result<Bool>):HostLatestJournalStreamInputReader{
        HostLatestJournalStreamInputReader({reader=>
            lock.lock()
            try{
                match(ensureArtifactRoot()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                if(database.isNone()){return hostResourceError<Unit>("plugin.document_query_store_missing")}
                match(current()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                database.getOrThrow().readTransaction<Unit>({tx=>
                    match(consumePreparedPluginDocumentLatestJournalInput(tx,link,binding,data,current,{proof=>reader.materialize(proof)})){
                        case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
                    match(current()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}})
                Result<Unit>.Ok(())
            }catch(error:HostArtifactOperationFailure){Result<Unit>.Err(error.failure)}
            catch(_:Exception){hostResourceError<Unit>("plugin.document_latest_input_stale")}
            finally{lock.unlock()}
        },{digest=>blobPath(digest)},current,consume,end)
    }

    public func documentDataSession(): HostDocumentDataSession {HostDocumentDataSession(this)}
    // Only the session's prior canonical authorization permits upload(). This
    // method rechecks metadata, freezes a no-follow identity, and adopts the
    // handle owner before opening. No pathname is subsequently opened by File.
    public func openDocumentDataInput(reference:PluginDocumentPayloadReference,adopt:(HostVerifiedArtifactInput)->Result<Unit>):Result<Unit>{
        lock.lock()
        try{
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(database.isNone()){return hostResourceError("plugin.document_query_store_missing")}
            database.getOrThrow().readTransaction<Unit>({tx=>match(verifyPluginDocumentPayloadMetadata(tx,reference)){
                case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}})
            let path=blobPath(reference.digest)
            let witness=match(hostReadResourceWitness(path)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let reader=HostVerifiedArtifactInput(witness,reference.bytes)
            match(adopt(reader)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            reader.open(path)
        }catch(_:Exception){hostResourceError("plugin.document_payload_read_failed")}
        finally{lock.unlock()}
    }
    public func authorizeDocumentDataInput(link:ContextReadFactLink,binding:AgentValue,data:AgentValue,current:()->Result<Unit>):Result<Unit>{
        lock.lock()
        try{
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(database.isNone()){return hostResourceError("plugin.document_query_store_missing")}
            match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            database.getOrThrow().readTransaction<Unit>({tx=>
                match(verifyPreparedPluginDocumentPayloadInput(tx,link,binding,data)){
                    case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
                match(current()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}})
            Result.Ok(())
        }catch(error:HostArtifactOperationFailure){Result.Err(error.failure)}
        catch(_:Exception){hostResourceError("plugin.document_query_input_stale")}
        finally{lock.unlock()}
    }
    public func authorizeDocumentWindowDataInput(links:Array<ContextReadFactLink>,binding:AgentValue,dataList:AgentValue,current:()->Result<Unit>):Result<Unit>{
        lock.lock()
        try{
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(database.isNone()){return hostResourceError("plugin.document_query_store_missing")}
            match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            database.getOrThrow().readTransaction<Unit>({tx=>
                match(verifyPreparedPluginDocumentWindowInput(tx,links,binding,dataList)){
                    case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
                match(current()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}})
            Result.Ok(())
        }catch(error:HostArtifactOperationFailure){Result.Err(error.failure)}
        catch(_:Exception){hostResourceError("plugin.document_query_input_stale")}
        finally{lock.unlock()}
    }
    public func authorizeDocumentWindowPrefix(links:Array<ContextReadFactLink>,binding:AgentValue,dataList:AgentValue,current:()->Result<Unit>):Result<Unit>{
        lock.lock()
        try{
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(database.isNone()){return hostResourceError("plugin.document_query_store_missing")}
            match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            database.getOrThrow().readTransaction<Unit>({tx=>
                match(verifyObservedPluginDocumentWindowPrefix(tx,links,binding,dataList)){
                    case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
                match(current()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}})
            Result.Ok(())
        }catch(error:HostArtifactOperationFailure){Result.Err(error.failure)}
        catch(_:Exception){hostResourceError("plugin.document_query_input_stale")}
        finally{lock.unlock()}
    }
    // Called only with an actually adopted, finished preparation writer.
    // Artifact mutex -> same SQL transaction -> fixed FD integrity check.
    // The callback must check only captured files/atomic caller state here.
    // The new audit retains data; it grants no Root, read or execution right.
    // Artifact mutex -> one read TX. The Store Unit reader does not
    // publish a pin, open a file or create an execution authorization.
    // Physical data custody only. The actual Store terminal Port proves
    // Source/prefix/pin/Receipt inside consume; this callback opens no SQL.
    // Same Session -> Artifact mutex -> fixed FD -> Store TX. No caller can
    // choose a pathname, substitute a reopened handle or ACK an unrelated FD.
    // Created only from the actual adopted, finished writer after its
    // complete decode. No Native reference/path can create this data carrier.
    // This publication records no approval, execution or canonical terminal.
    func publishManagedChannelTerminal(writer:HostServiceArtifactWriter,guard:()->Result<Unit>):Result<HostManagedChannelTerminalFile>{
        lock.lock();try{
            let expected=writer.completedArtifact()
            if(expected.bytes<1 || expected.bytes>8388608){return hostResourceError("managed_channel.terminal_file_bound")}
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(writer.publish(blobPath(expected.sha256),guard:guard)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            Result.Ok(HostManagedChannelTerminalFile(expected))
        }catch(_:Exception){hostResourceError("managed_channel.terminal_file_publish_failed")}
        finally{lock.unlock()}
    }

    // Same Session -> Artifact mutex -> original fixed FD -> Store TX.
    // The supplied carrier is actual private writer data, never a Source.
    // Failure leaves the opened FD with the same Session for cleanup retries.
    func withManagedChannelTerminalFile(retained:HostManagedChannelTerminalFile,
        adopt:(HostVerifiedArtifactInput)->Result<Unit>,release:(HostVerifiedArtifactInput)->Result<Unit>,
        guard:()->Result<Unit>,consume:(()->Result<Unit>)->Unit):Result<Unit>{
        lock.lock();try{
            let expected=retained.artifact
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let path=blobPath(expected.sha256)
            let witness=match(hostReadResourceWitness(path)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let file=HostVerifiedArtifactInput(witness,expected.bytes)
            match(adopt(file)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(file.open(path)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let verify:()->Result<Unit>={=>
                match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                match(file.rewind()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                let buffer=Array<Byte>(16384,repeat:0);let hash=SHA256();var count:Int64=0
                while(true){
                    match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    let size=match(file.read(buffer)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                    if(size==0){break}
                    if(size>expected.bytes-count){return hostResourceError<Unit>("managed_channel.terminal_file_changed")}
                    hash.write(buffer[..size]);count+=size
                }
                if(count!=expected.bytes || hostArtifactHex(hash.finish())!=expected.sha256){
                    return hostResourceError<Unit>("managed_channel.terminal_file_changed")}
                guard()}
            match(verify()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            consume(verify)
            match(verify()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(release(file)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            guard()
        }catch(error:HostArtifactOperationFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){hostResourceError("managed_channel.terminal_file_unverified")}
        finally{lock.unlock()}
    }

    func withLivePolicyTerminalFile(descriptor:AgentValue,adopt:(HostVerifiedArtifactInput)->Result<Unit>,
        release:(HostVerifiedArtifactInput)->Result<Unit>,guard:()->Result<Unit>,
        consume:(()->Result<Unit>)->Unit):Result<Unit>{
        lock.lock();try{
            let expected=parsePluginDocumentPayloadReference(descriptor.field("result_payload").getOrThrow()).value().getOrThrow()
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let path=blobPath(expected.digest)
            let witness=match(hostReadResourceWitness(path)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let file=HostVerifiedArtifactInput(witness,expected.bytes)
            match(adopt(file)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(file.open(path)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let verify:()->Result<Unit>={=>
                match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                match(file.rewind()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                let buffer=Array<Byte>(16384,repeat:0);let hash=SHA256();var bytes:Int64=0
                while(true){
                    match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    let size=match(file.read(buffer)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                    if(size==0){break}
                    if(size>expected.bytes-bytes){return hostPluginResourceError<Unit>("plugin.live_terminal_file_changed","terminal file exceeded its actual complete size")}
                    hash.write(buffer[..size]);bytes+=size
                }
                if(bytes!=expected.bytes || hostArtifactHex(hash.finish())!=expected.digest){
                    return hostPluginResourceError<Unit>("plugin.live_terminal_file_changed","terminal file failed complete fixed-FD hash/EOF")}
                guard()}
            match(verify()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            consume(verify)
            match(verify()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(release(file)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            guard()
        }catch(error:HostArtifactOperationFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){hostResourceError("plugin.live_terminal_file_unverified")}
        finally{lock.unlock()}
    }

    func retainLivePolicyParentOutput(context:ToolInvocationContext,parent:PreparedToolInvocation,descriptor:AgentValue,
        writer:HostServiceArtifactWriter,owner:LogicalJsonOwnerReservation,peak:Int64,guard:()->Result<Unit>):Result<Unit>{
        lock.lock();try{
            if(database.isNone() || parent.source.operationRoot.isNone()){
                return hostResourceError("plugin.live_terminal_source_missing")}
            let payload=parsePluginDocumentPayloadReference(descriptor.field("result_payload").getOrThrow()).value().getOrThrow()
            let artifact=writer.completedArtifact()
            if(artifact.bytes!=payload.bytes || artifact.sha256!=payload.digest){return hostResourceError("plugin.live_terminal_output_changed")}
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let path=blobPath(artifact.sha256)
            match(writer.publish(path,guard:guard)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            database.getOrThrow().transaction{tx=>
                tx.execute("INSERT OR IGNORE INTO artifacts(hash,mime,size,metadata,relative_path) VALUES(?,?,?,?,?)",
                    [SqlParameter.Text(artifact.sha256),SqlParameter.Text(artifact.contentType),SqlParameter.Int64Value(artifact.bytes),
                        SqlParameter.Text(hostArtifactMetadata(artifact)),SqlParameter.Text("blobs/"+artifact.sha256+".txt")])
                let rejected=tx.query("SELECT 1 FROM operations WHERE id=? AND run_id=? AND state='rejected' LIMIT 1",
                    [SqlParameter.Text(parent.operationId.value),SqlParameter.Text(context.runId.value)])
                let verify:()->Result<Unit>={=>writer.verifyPublished(path,guard:guard)}
                if(rejected.size==1){
                    let expected=match(parent.approval){case Some(value)=>value
                        case None=>throw IllegalStateException("actual rejected parent lost its original approval")}
                    retainPluginLivePolicyRejectedParentTerminal(tx,parent.source.operationRoot.getOrThrow(),parent.operationId,
                        context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,expected,descriptor,
                        {bytes=>reserveNativeRowJournalPayload(bytes)},verify,guard,retainedDescriptorOwner:Some(owner),
                        retainedDescriptorPeak:peak,streamedSource:true)
                }else{
                    retainPluginLivePolicyParentTerminal(tx,parent.source.operationRoot.getOrThrow(),parent.operationId,
                        context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,descriptor,
                        {bytes=>reserveNativeRowJournalPayload(bytes)},verify,guard,retainedDescriptorOwner:Some(owner),
                        retainedDescriptorPeak:peak,streamedSource:true)
                }
                match(guard()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
            }
            guard()
        }catch(error:HostArtifactOperationFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){hostResourceError("plugin.live_terminal_retention_unverified")}
        finally{lock.unlock()}
    }

    // The actual output lease remains owned by the caller through both
    // complete terminal checks. This only reads the already reserved child
    // Receipt; no canonical Item/Receipt/ACK or effect is created here.
    func withLivePolicySettledChildTip(context:ToolInvocationContext,parent:PreparedToolInvocation,
        child:PreparedToolInvocation,result:ToolResult,guard:()->Result<Unit>,consume:(AgentValue)->Unit):Result<Unit>{
        lock.lock();try{
            if(database.isNone() || parent.source.operationRoot.isNone() || parent.source.runId.value!=context.runId.value ||
                parent.source.sessionId.value!=context.sessionId.value || parent.source.epoch!=context.epoch ||
                child.source.runId.value!=context.runId.value || child.source.sessionId.value!=context.sessionId.value || child.source.epoch!=context.epoch){
                return hostResourceError("plugin.live_child_tip_source_missing")}
            match(guard()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            database.getOrThrow().readTransaction<Unit>({tx=>
                withPluginLivePolicySettledChildTip(tx,parent.source.operationRoot.getOrThrow(),parent.operationId,
                    child.operationId,context.runId,ThreadId(context.sessionId.value),context.epoch,
                    parent.operationPlan,child.operationPlan,child.source.requestKey,child.call.callId,child.approval,result,
                    {bytes=>reserveNativeRowJournalPayload(bytes)},guard,consume,streamedSource:true)
                match(guard()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}})
            Result<Unit>.Ok(())
        }catch(error:HostArtifactOperationFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){hostResourceError("plugin.live_child_tip_unverified")}
        finally{lock.unlock()}
    }
    // Only an actual retained reviewed child may use the distinct real
    // User-no-effect path. No rejected ToolResult or payload lease is made.
    func withLivePolicyRejectedChildTip(context:ToolInvocationContext,parent:PreparedToolInvocation,
        child:PreparedToolInvocation,guard:()->Result<Unit>,consume:(AgentValue)->Unit):Result<Unit>{
        lock.lock();try{
            if(database.isNone() || parent.source.operationRoot.isNone() || child.approval.isNone() ||
                parent.source.runId.value!=context.runId.value || parent.source.sessionId.value!=context.sessionId.value || parent.source.epoch!=context.epoch ||
                child.source.runId.value!=context.runId.value || child.source.sessionId.value!=context.sessionId.value || child.source.epoch!=context.epoch){
                return hostResourceError("plugin.live_child_tip_source_missing")}
            match(guard()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            database.getOrThrow().readTransaction<Unit>({tx=>
                withPluginLivePolicyRejectedChildTip(tx,parent.source.operationRoot.getOrThrow(),parent.operationId,
                    child.operationId,context.runId,ThreadId(context.sessionId.value),context.epoch,
                    parent.operationPlan,child.operationPlan,child.source.requestKey,child.call.callId,child.approval.getOrThrow(),
                    {bytes=>reserveNativeRowJournalPayload(bytes)},guard,consume,streamedSource:true)
                match(guard()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}})
            Result<Unit>.Ok(())
        }catch(error:HostArtifactOperationFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){hostResourceError("plugin.live_child_tip_unverified")}
        finally{lock.unlock()}
    }

    func withLivePolicyInputReadRequest(parentTool:String,input:AgentValue,guard:()->Result<Unit>,
        consume:(AgentValue)->Unit):Result<Unit>{
        lock.lock()
        try{
            if(database.isNone()){return hostResourceError("plugin.document_query_store_missing")}
            match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            database.getOrThrow().readTransaction<Unit>({tx=>
                withPluginLivePolicyInputReadBinding(tx,parentTool,input,{bytes=>reserveNativeDocumentPayload(bytes)},guard,consume)
                match(guard()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}})
            Result<Unit>.Ok(())
        }catch(error:HostArtifactOperationFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){hostResourceError("plugin.live_input_binding_stale")}
        finally{lock.unlock()}
    }

    func reuseLivePolicyInput(parent:AgentValue,adopt:(HostVerifiedArtifactInput)->Result<Unit>,
        verify:(HostVerifiedArtifactInput,PluginDocumentPayloadReference)->Result<Unit>,guard:()->Result<Unit>):Result<Bool>{
        lock.lock()
        try{
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(database.isNone()){return hostResourceError("plugin.document_query_store_missing")}
            if(!pluginLivePolicyParentValueValid(parent)){return hostResourceError("plugin.live_input_parent")}
            let host=parent.field("host_plan").getOrThrow()
            let contribution=httpIntentText(host.field("binding").getOrThrow(),"contribution")
            let reference=parsePluginDocumentPayloadReference(host.field("input_payload").getOrThrow()).value().getOrThrow()
            match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            Result<Bool>.Ok(database.getOrThrow().readTransaction<Bool>({tx=>
                let reused=match(reusePluginLivePolicyInputPayload(tx,contribution,parent,{bytes=>reserveNativeDocumentPayload(bytes)},guard)){
                    case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(value)=>value}
                if(!reused){return false}
                // No caller chooses a path. The actual pin was checked before
                // a no-follow fixed hash pathname is frozen and opened.
                let path=blobPath(reference.digest)
                let witness=match(hostReadResourceWitness(path)){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(value)=>value}
                let reader=HostVerifiedArtifactInput(witness,reference.bytes)
                match(adopt(reader)){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
                match(guard()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
                match(reader.open(path)){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
                match(verify(reader,reference)){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
                let after=match(reusePluginLivePolicyInputPayload(tx,contribution,parent,{bytes=>reserveNativeDocumentPayload(bytes)},guard)){
                    case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(value)=>value}
                if(!after){throw IllegalStateException("same existing input pin vanished during its fixed FD verification")}
                match(guard()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
                true}))
        }catch(error:HostArtifactOperationFailure){Result<Bool>.Err(error.failure)}
        catch(_:Exception){hostResourceError("plugin.live_input_reuse_failed")}
        finally{lock.unlock()}
    }

    func retainLivePolicyInput(parent:AgentValue,writer:HostServiceArtifactWriter,
        guard:()->Result<Unit>):Result<Unit>{
        lock.lock()
        try{
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(database.isNone() || !pluginLivePolicyParentValueValid(parent)){
                return hostResourceError("plugin.live_input_parent")}
            let reference=match(parsePluginDocumentPayloadReference(parent.field("host_plan").getOrThrow().field("input_payload").getOrThrow())){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let artifact=writer.completedArtifact()
            if(reference.digest!=artifact.sha256 || reference.bytes!=artifact.bytes){
                return hostResourceError("plugin.live_input_changed")}
            match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let path=blobPath(artifact.sha256)
            match(writer.publishLivePolicyInput(path,guard)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            database.getOrThrow().transaction{tx=>
                tx.execute("INSERT OR IGNORE INTO artifacts(hash,mime,size,metadata,relative_path) VALUES(?,?,?,?,?)",
                    [SqlParameter.Text(artifact.sha256),SqlParameter.Text(artifact.contentType),SqlParameter.Int64Value(artifact.bytes),
                        SqlParameter.Text(hostArtifactMetadata(artifact)),SqlParameter.Text("blobs/"+artifact.sha256+".txt")])
                match(retainPluginLivePolicyInputPayload(tx,httpIntentText(parent.field("host_plan").getOrThrow().field("binding").getOrThrow(),"contribution"),
                    parent,{bytes=>reserveNativeDocumentPayload(bytes)},{=>writer.verifyPublished(path,guard:guard)},guard)){
                    case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
                match(guard()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}}
            Result<Unit>.Ok(())
        }catch(error:HostArtifactOperationFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){hostResourceError("plugin.live_input_preparation_failed")}
        finally{lock.unlock()}
    }

    // Exact same Session writers only. The original Artifact lock serializes
    // publication, actual metadata and the GC pin transaction. No worker path
    // or digest can select another file. This method creates no child/Receipt.
    func retainLivePolicyStep(context:ToolInvocationContext,parent:PreparedToolInvocation,
        descriptor:AgentValue,selected:Array<HostServiceArtifactWriter>,guard:()->Result<Unit>,streamedSource!:Bool=false):Result<Unit>{
        lock.lock()
        try{
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let rootSource=match(parent.source.operationRoot){case Some(value)=>value;case None=>return hostResourceError("plugin.live_step_root_missing")}
            if(database.isNone() || selected.isEmpty() || !isPluginLivePolicyParentPlan(parent.operationPlan) ||
                parent.source.runId.value!=context.runId.value || parent.source.sessionId.value!=context.sessionId.value || parent.source.epoch!=context.epoch){
                return hostResourceError("plugin.live_step_parent_changed")}
            let payloads=descriptor.field("payloads").getOrThrow()
            if(payloads.unifiedKind!=ValueKind.List || payloads.items.size!=selected.size){
                return hostResourceError("plugin.live_step_writer_set")}
            let actual=database.getOrThrow()
            match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            actual.readTransaction<Unit>({tx=>
                verifyPluginLivePolicyStepDataParent(tx,rootSource,parent.operationId,context.runId,ThreadId(context.sessionId.value),
                    context.epoch,parent.operationPlan,descriptor,{bytes=>reserveNativeRowJournalPayload(bytes)},guard,streamedSource:streamedSource)
            })
            for(index in 0..selected.size){
                let reference=parsePluginDocumentPayloadReference(payloads.items[index]).value().getOrThrow()
                let artifact=selected[index].completedArtifact()
                if(reference.digest!=artifact.sha256 || reference.bytes!=artifact.bytes){
                    return hostResourceError("plugin.live_step_writer_changed")}
                match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                match(selected[index].publish(blobPath(artifact.sha256),guard:guard)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            }
            actual.transaction{tx=>
                for(writer in selected){
                    let artifact=writer.completedArtifact()
                    tx.execute("INSERT OR IGNORE INTO artifacts(hash,mime,size,metadata,relative_path) VALUES(?,?,?,?,?)",
                        [SqlParameter.Text(artifact.sha256),SqlParameter.Text(artifact.contentType),SqlParameter.Int64Value(artifact.bytes),
                            SqlParameter.Text(hostArtifactMetadata(artifact)),SqlParameter.Text("blobs/"+artifact.sha256+".txt")])}
                let verify:(PluginDocumentPayloadReference)->Result<Unit>={reference=>
                    for(writer in selected){
                        let artifact=writer.completedArtifact()
                        if(artifact.sha256==reference.digest && artifact.bytes==reference.bytes){
                            return writer.verifyPublished(blobPath(artifact.sha256),guard:guard)}}
                    hostResourceError<Unit>("plugin.live_step_foreign_writer")}
                retainPluginLivePolicyStepData(tx,rootSource,parent.operationId,context.runId,ThreadId(context.sessionId.value),context.epoch,
                    parent.operationPlan,descriptor,{bytes=>reserveNativeRowJournalPayload(bytes)},verify,guard,streamedSource:streamedSource)
                match(guard()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
            }
            Result<Unit>.Ok(())
        }catch(error:HostArtifactOperationFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){hostResourceError<Unit>("plugin.live_step_not_retained")}
        finally{lock.unlock()}
    }
    // Artifact lock precedes the actual Store transaction. The real private
    // proof alone selects member refs before this fixed hash path is opened.
    func executeLivePolicyJournalNativeAbortEffect328(context:ToolInvocationContext,parent:PreparedToolInvocation,
        child:PreparedToolInvocation,session:HostDocumentDataSession,operations:OperationRuntimePort,
        guard:()->Result<Unit>,loan:LogicalJsonOwnerReservation,loanPeak:Int64,consumeTip:(AgentValue)->Unit):PluginLivePolicyJournalSettlementProgress326{
        executeLivePolicyJournalNativeAbortEffectFrame334(context,parent,child,session,operations,guard,
            loan,loanPeak,consumeTip,None<PluginLivePolicyOuterErrorFrame334>)
    }
    func executeLivePolicyJournalNativeAbortEffectFrame334(context:ToolInvocationContext,parent:PreparedToolInvocation,
        child:PreparedToolInvocation,session:HostDocumentDataSession,operations:OperationRuntimePort,
        guard:()->Result<Unit>,loan:LogicalJsonOwnerReservation,loanPeak:Int64,consumeTip:(AgentValue)->Unit,frame:?PluginLivePolicyOuterErrorFrame334):PluginLivePolicyJournalSettlementProgress326{
        lock.lock()
        try{
            if(database.isNone() || parent.source.operationRoot.isNone() ||
                parent.source.runId.value!=context.runId.value || parent.source.sessionId.value!=context.sessionId.value ||
                parent.source.epoch!=context.epoch || child.source.runId.value!=context.runId.value ||
                child.source.sessionId.value!=context.sessionId.value || child.source.epoch!=context.epoch ||
                child.source.parentOperationId.isNone() || child.source.parentOperationId.getOrThrow().value!=parent.operationId.value ||
                !pluginLivePolicyStreamingChildWithinCeiling(parent.operationPlan,child.operationPlan)){
                return PluginLivePolicyJournalSettlementProgress326(hostResourceError<Unit>("plugin.live_effect_actual_scope_changed"))}
            match(ensureArtifactRoot()){case Result.Err(error)=>return PluginLivePolicyJournalSettlementProgress326(Result<Unit>.Err(error));case Result.Ok(_)=>()}
            match(guard()){case Result.Err(error)=>return PluginLivePolicyJournalSettlementProgress326(Result<Unit>.Err(error));case Result.Ok(_)=>()}
            let committer=HostLivePolicyNativeAbortJournalCommitter325(session,{reference,current=>
                let path=blobPath(reference.digest)
                let witness=match(hostReadResourceWitness(path)){
                    case Result.Err(error)=>return Result<HostVerifiedArtifactInput>.Err(error);case Result.Ok(value)=>value}
                let reader=HostVerifiedArtifactInput(witness,reference.bytes)
                match(session.adoptLivePolicyEffectInput306(reader)){
                    case Result.Err(error)=>return Result<HostVerifiedArtifactInput>.Err(error);case Result.Ok(_)=>()}
                match(current()){case Result.Err(error)=>return Result<HostVerifiedArtifactInput>.Err(error);case Result.Ok(_)=>()}
                match(reader.open(path)){case Result.Err(error)=>return Result<HostVerifiedArtifactInput>.Err(error);case Result.Ok(_)=>()}
                Result<HostVerifiedArtifactInput>.Ok(reader)
            })
            match(frame){case None=>
                operations.settlePluginLivePolicyJournalNativeAbortChild328(parent.source.operationRoot.getOrThrow(),parent.operationId,child.operationId,
                    context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,child.operationPlan,
                    child.source.requestKey,child.call.callId,child.approval,guard,committer,loan,loanPeak,consumeTip)
                case Some(actual)=>operations.settlePluginLivePolicyJournalNativeAbortChild334(parent.source.operationRoot.getOrThrow(),parent.operationId,child.operationId,
                    context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,child.operationPlan,
                    child.source.requestKey,child.call.callId,child.approval,guard,committer,loan,loanPeak,consumeTip,actual)}
        }catch(error:HostArtifactOperationFailure){PluginLivePolicyJournalSettlementProgress326(Result<Unit>.Err(error.failure))}
        catch(_:Exception){PluginLivePolicyJournalSettlementProgress326(hostResourceError<Unit>("plugin.live_effect_store_closed"))}
        finally{lock.unlock()}
    }

    func executeLivePolicyJournalEffect307(context:ToolInvocationContext,parent:PreparedToolInvocation,
        child:PreparedToolInvocation,session:HostDocumentDataSession,operations:OperationRuntimePort,
        guard:()->Result<Unit>,consumeTip:(AgentValue)->Unit):Result<Unit>{
        lock.lock()
        try{
            if(database.isNone() || parent.source.operationRoot.isNone() ||
                parent.source.runId.value!=context.runId.value || parent.source.sessionId.value!=context.sessionId.value ||
                parent.source.epoch!=context.epoch || child.source.runId.value!=context.runId.value ||
                child.source.sessionId.value!=context.sessionId.value || child.source.epoch!=context.epoch ||
                child.source.parentOperationId.isNone() || child.source.parentOperationId.getOrThrow().value!=parent.operationId.value ||
                !pluginLivePolicyStreamingChildWithinCeiling(parent.operationPlan,child.operationPlan)){
                return hostResourceError("plugin.live_effect_actual_scope_changed")}
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let committer=HostLivePolicyJournalCommitter306(session,{reference,current=>
                let path=blobPath(reference.digest)
                let witness=match(hostReadResourceWitness(path)){
                    case Result.Err(error)=>return Result<HostVerifiedArtifactInput>.Err(error);case Result.Ok(value)=>value}
                let reader=HostVerifiedArtifactInput(witness,reference.bytes)
                match(session.adoptLivePolicyEffectInput306(reader)){
                    case Result.Err(error)=>return Result<HostVerifiedArtifactInput>.Err(error);case Result.Ok(_)=>()}
                match(current()){case Result.Err(error)=>return Result<HostVerifiedArtifactInput>.Err(error);case Result.Ok(_)=>()}
                match(reader.open(path)){case Result.Err(error)=>return Result<HostVerifiedArtifactInput>.Err(error);case Result.Ok(_)=>()}
                Result<HostVerifiedArtifactInput>.Ok(reader)
            })
            operations.settlePluginLivePolicyJournalChild307(parent.source.operationRoot.getOrThrow(),parent.operationId,child.operationId,
                context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,child.operationPlan,
                child.source.requestKey,child.call.callId,child.approval,guard,committer,consumeTip)
        }catch(error:HostArtifactOperationFailure){Result.Err(error.failure)}
        catch(_:Exception){hostResourceError("plugin.live_effect_store_closed")}
        finally{lock.unlock()}
    }

    // This is trusted same-Session assembly. Native receives bytes only;
    // every path is derived from the actual immutable member's full digest.
    func consumeLivePolicyKnownProposalPayloadsNativeAbort328(context:ToolInvocationContext,parent:PreparedToolInvocation,
        sequence:Int64,through:Int64,ledger:AgentValue,metadataOwner:LogicalJsonOwnerReservation,metadataPeak:Int64,
        adopt:(HostVerifiedArtifactInput)->Result<Unit>,
        readIndex:(HostVerifiedArtifactInput,PluginDocumentPayloadReference,()->Result<Unit>,(AgentValue)->Unit)->Result<(Int64,String)>,
        readRaw:(HostVerifiedArtifactInput,PluginDocumentPayloadReference,()->Result<Unit>,(Int64,Array<Byte>)->Result<Unit>)->Result<(Int64,String)>,
        guard:()->Result<Unit>,
        consume:(AgentValue,PluginDocumentPayloadReference,AgentValue,AgentValue,
            (PluginDocumentPayloadReference,(Int64,Array<Byte>)->Result<Unit>)->Result<Unit>)->Unit):Result<Unit>{
        lock.lock();try{
            if(database.isNone() || parent.source.operationRoot.isNone() || parent.source.runId.value!=context.runId.value ||
                parent.source.sessionId.value!=context.sessionId.value || parent.source.epoch!=context.epoch || metadataPeak<1){
                return hostResourceError<Unit>("plugin.live_history_parent_changed")}
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            match(guard()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            // No await or Host/Registry lookup occurs under Artifact -> SQL.
            // The caller already holds its actual invoke/generation loan.
            database.getOrThrow().readTransaction<Unit>({tx=>
                let materialize:LivePolicyHistoricalRawReader={reference,current,observe=>
                    let path=blobPath(reference.digest)
                    let witness=match(hostReadResourceWitness(path)){
                        case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
                    let reader=HostVerifiedArtifactInput(witness,reference.bytes)
                    match(adopt(reader)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    match(reader.open(path)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    readRaw(reader,reference,current,observe)}
                let indexReader:LivePolicyHistoricalIndexReader={reference,current,use=>
                    let path=blobPath(reference.digest)
                    let witness=match(hostReadResourceWitness(path)){
                        case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
                    let reader=HostVerifiedArtifactInput(witness,reference.bytes)
                    match(adopt(reader)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    match(reader.open(path)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    readIndex(reader,reference,current,use)}
                let verify:(PluginDocumentPayloadReference)->Result<Unit>={reference=>
                    match(materialize(reference,guard,{_,_=>Result<Unit>.Ok(())})){
                        case Result.Err(error)=>Result<Unit>.Err(error);case Result.Ok(_)=>Result<Unit>.Ok(())}}
                withPluginLivePolicyKnownProposalSequencePayloadsNativeAbort328(tx,parent.source.operationRoot.getOrThrow(),
                    parent.operationId,context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,
                    sequence,through,ledger,{bytes=>reserveNativeRowJournalPayload(bytes)},verify,guard,indexReader,materialize,
                    {tip,indexRef,errorData,index,send=>
                        let sender:(PluginDocumentPayloadReference,(Int64,Array<Byte>)->Result<Unit>)->Result<Unit>={reference,forward=>
                            // The Store sender validates the next original ordinal
                            // and production pin; this closure cannot skip members.
                            let transmit:LivePolicyHistoricalRawReader={actual,current,observe=>
                                materialize(actual,current,{offset,raw=>
                                    match(observe(offset,raw)){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                                    forward(offset,raw)})}
                            send(reference,transmit)}
                        consume(tip,indexRef,errorData,index,sender)},metadataOwner,metadataPeak)
                match(guard()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
            })
            guard()
        }catch(error:HostArtifactOperationFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){hostResourceError<Unit>("plugin.live_history_input_stale")}
        finally{lock.unlock()}
    }

    func consumeLivePolicyKnownProposalPayloads(context:ToolInvocationContext,parent:PreparedToolInvocation,
        sequence:Int64,through:Int64,ledger:AgentValue,metadataOwner:LogicalJsonOwnerReservation,metadataPeak:Int64,
        adopt:(HostVerifiedArtifactInput)->Result<Unit>,
        readIndex:(HostVerifiedArtifactInput,PluginDocumentPayloadReference,()->Result<Unit>,(AgentValue)->Unit)->Result<(Int64,String)>,
        readRaw:(HostVerifiedArtifactInput,PluginDocumentPayloadReference,()->Result<Unit>,(Int64,Array<Byte>)->Result<Unit>)->Result<(Int64,String)>,
        guard:()->Result<Unit>,
        consume:(AgentValue,PluginDocumentPayloadReference,AgentValue,AgentValue,
            (PluginDocumentPayloadReference,(Int64,Array<Byte>)->Result<Unit>)->Result<Unit>)->Unit):Result<Unit>{
        lock.lock();try{
            if(database.isNone() || parent.source.operationRoot.isNone() || parent.source.runId.value!=context.runId.value ||
                parent.source.sessionId.value!=context.sessionId.value || parent.source.epoch!=context.epoch || metadataPeak<1){
                return hostResourceError<Unit>("plugin.live_history_parent_changed")}
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            match(guard()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            // No await or Host/Registry lookup occurs under Artifact -> SQL.
            // The caller already holds its actual invoke/generation loan.
            database.getOrThrow().readTransaction<Unit>({tx=>
                let materialize:LivePolicyHistoricalRawReader={reference,current,observe=>
                    let path=blobPath(reference.digest)
                    let witness=match(hostReadResourceWitness(path)){
                        case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
                    let reader=HostVerifiedArtifactInput(witness,reference.bytes)
                    match(adopt(reader)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    match(reader.open(path)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    readRaw(reader,reference,current,observe)}
                let indexReader:LivePolicyHistoricalIndexReader={reference,current,use=>
                    let path=blobPath(reference.digest)
                    let witness=match(hostReadResourceWitness(path)){
                        case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
                    let reader=HostVerifiedArtifactInput(witness,reference.bytes)
                    match(adopt(reader)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    match(reader.open(path)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    readIndex(reader,reference,current,use)}
                let verify:(PluginDocumentPayloadReference)->Result<Unit>={reference=>
                    match(materialize(reference,guard,{_,_=>Result<Unit>.Ok(())})){
                        case Result.Err(error)=>Result<Unit>.Err(error);case Result.Ok(_)=>Result<Unit>.Ok(())}}
                withPluginLivePolicyKnownProposalSequencePayloads(tx,parent.source.operationRoot.getOrThrow(),
                    parent.operationId,context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,
                    sequence,through,ledger,{bytes=>reserveNativeRowJournalPayload(bytes)},verify,guard,indexReader,materialize,
                    {tip,indexRef,errorData,index,send=>
                        let sender:(PluginDocumentPayloadReference,(Int64,Array<Byte>)->Result<Unit>)->Result<Unit>={reference,forward=>
                            // The Store sender validates the next original ordinal
                            // and production pin; this closure cannot skip members.
                            let transmit:LivePolicyHistoricalRawReader={actual,current,observe=>
                                materialize(actual,current,{offset,raw=>
                                    match(observe(offset,raw)){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                                    forward(offset,raw)})}
                            send(reference,transmit)}
                        consume(tip,indexRef,errorData,index,sender)},metadataOwner,metadataPeak)
                match(guard()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
            })
            guard()
        }catch(error:HostArtifactOperationFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){hostResourceError<Unit>("plugin.live_history_input_stale")}
        finally{lock.unlock()}
    }

    func copyLivePolicyStepPayload(context:ToolInvocationContext,parent:PreparedToolInvocation,ledger:AgentValue,
        payload:PluginDocumentPayloadReference,adopt:(HostVerifiedArtifactInput)->Result<Unit>,
        consume:(HostVerifiedArtifactInput,PluginDocumentPayloadReference,()->Result<Unit>)->Result<(Int64,String)>,
        guard:()->Result<Unit>):Result<Unit>{
        lock.lock();try{
            if(database.isNone() || parent.source.operationRoot.isNone() || parent.source.runId.value!=context.runId.value ||
                parent.source.sessionId.value!=context.sessionId.value || parent.source.epoch!=context.epoch){
                return hostResourceError<Unit>("plugin.live_step_parent_changed")}
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            database.getOrThrow().readTransaction<Unit>({tx=>
                let materialize:(PluginDocumentPayloadReference,()->Result<Unit>)->Result<(Int64,String)>={reference,current=>
                    let path=blobPath(reference.digest)
                    let witness=match(hostReadResourceWitness(path)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
                    let reader=HostVerifiedArtifactInput(witness,reference.bytes)
                    match(adopt(reader)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    match(reader.open(path)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    consume(reader,reference,current)}
                match(consumePluginLivePolicyCurrentStepPayload(tx,parent.source.operationRoot.getOrThrow(),parent.operationId,
                    context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,ledger,payload,
                    {bytes=>reserveNativeRowJournalPayload(bytes)},guard,materialize)){
                    case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}})
            Result<Unit>.Ok(())
        }catch(error:HostArtifactOperationFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){hostResourceError<Unit>("plugin.live_step_input_stale")}
        finally{lock.unlock()}
    }

    func livePolicyPinnedInput(context:ToolInvocationContext,parent:PreparedToolInvocation,through:Int64,ledger:AgentValue,
        adopt:(HostVerifiedArtifactInput)->Result<Unit>,consume:(HostVerifiedArtifactInput,PluginDocumentPayloadReference,()->Result<Unit>)->Result<(Int64,String)>,
        guard:()->Result<Unit>):Result<Unit>{
        lock.lock();try{
            if(database.isNone() || parent.source.operationRoot.isNone() || parent.source.runId.value!=context.runId.value ||
                parent.source.sessionId.value!=context.sessionId.value || parent.source.epoch!=context.epoch){
                return hostResourceError("plugin.live_input_parent_changed")}
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            database.getOrThrow().readTransaction<Unit>({tx=>
                match(consumePluginLivePolicyPinnedInput(tx,parent.source.operationRoot.getOrThrow(),parent.operationId,context.runId,
                    ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,through,ledger,
                    {bytes=>reserveNativeRowJournalPayload(bytes)},guard,{reference,current=>
                        let path=blobPath(reference.digest)
                        let witness=match(hostReadResourceWitness(path)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
                        let reader=HostVerifiedArtifactInput(witness,reference.bytes)
                        match(adopt(reader)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                        match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                        match(reader.open(path)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                        consume(reader,reference,current)})){
                    case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}})
            Result<Unit>.Ok(())
        }catch(error:HostArtifactOperationFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){hostResourceError("plugin.live_input_stale")}
        finally{lock.unlock()}
    }

    func describeLivePolicyBaseJournal(context:ToolInvocationContext,parent:PreparedToolInvocation,
        through:Int64,ledger:AgentValue,guard:()->Result<Unit>,
        consume:(AgentValue,PluginDocumentLatestJournalStreamReference)->Unit,
        retainedMetadataOwner!:?LogicalJsonOwnerReservation=None,retainedMetadataPeak!:Int64=0):Result<Unit>{
        lock.lock();try{
            if(database.isNone() || parent.source.operationRoot.isNone() || parent.source.runId.value!=context.runId.value ||
                parent.source.sessionId.value!=context.sessionId.value || parent.source.epoch!=context.epoch){
                return hostResourceError("plugin.live_base_descriptor_source_missing")}
            database.getOrThrow().readTransaction<Unit>({tx=>
                match(describePluginLivePolicyBaseJournalInput(tx,parent.source.operationRoot.getOrThrow(),parent.operationId,
                    context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,through,ledger,
                    {bytes=>reserveNativeRowJournalPayload(bytes)},guard,consume,
                    retainedMetadataOwner:retainedMetadataOwner,retainedMetadataPeak:retainedMetadataPeak)){
                    case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}})
            Result<Unit>.Ok(())
        }catch(error:HostArtifactOperationFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){hostResourceError("plugin.live_base_descriptor_stale")}
        finally{lock.unlock()}
    }

    func livePolicyBaseJournalInput(context:ToolInvocationContext,parent:PreparedToolInvocation,
        through:Int64,reference:AgentValue,guard:()->Result<Unit>,consume:(Int64,Array<Byte>)->Result<Unit>,
        end:(Int64)->Result<Bool>,retainedMetadataOwner!:?LogicalJsonOwnerReservation=None,
        retainedMetadataPeak!:Int64=0):HostLatestJournalStreamInputReader{
        HostLatestJournalStreamInputReader({reader=>
            lock.lock()
            try{
                if(database.isNone()){return hostResourceError<Unit>("plugin.live_base_input_store_missing")}
                let rootSource=match(parent.source.operationRoot){case Some(actual)=>actual
                    case None=>return hostResourceError<Unit>("plugin.live_base_input_root_missing")}
                if(parent.source.runId.value!=context.runId.value || parent.source.sessionId.value!=context.sessionId.value || parent.source.epoch!=context.epoch){
                    return hostResourceError<Unit>("plugin.live_base_input_parent_changed")}
                match(guard()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                database.getOrThrow().readTransaction<Unit>({tx=>
                    match(consumePluginLivePolicyBaseJournalInputStreamed(tx,rootSource,parent.operationId,context.runId,ThreadId(context.sessionId.value),
                        context.epoch,parent.operationPlan,through,reference,{bytes=>reserveNativeRowJournalPayload(bytes)},guard,
                        {proof=>reader.materialize(proof)},retainedMetadataOwner:retainedMetadataOwner,retainedMetadataPeak:retainedMetadataPeak)){
                        case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
                    match(guard()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}})
                Result<Unit>.Ok(())
            }catch(error:HostArtifactOperationFailure){Result<Unit>.Err(error.failure)}
            catch(_:Exception){hostResourceError<Unit>("plugin.live_base_input_stale")}
            finally{lock.unlock()}
        },{digest=>blobPath(digest)},guard,consume,end)
    }

    public func retainDocumentPureResult(link:ContextReadFactLink,parent:AgentValue,writer:HostServiceArtifactWriter,
        current:()->Result<Unit>):Result<Unit>{
        lock.lock()
        try{
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(database.isNone()){return hostResourceError("plugin.document_query_store_missing")}
            let host=parent.field("host_plan").getOrThrow()
            if(!pluginDocumentFrozenResultValid(host)){return hostResourceError("plugin.document_result_invalid")}
            let reference=parsePluginDocumentPayloadReference(host.field("result_payload").getOrThrow()).value().getOrThrow()
            let artifact=writer.completedArtifact()
            if(reference.digest!=artifact.sha256 || reference.bytes!=artifact.bytes){return hostResourceError("plugin.document_result_changed")}
            match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let path=blobPath(artifact.sha256)
            match(writer.publish(path,guard:current)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            database.getOrThrow().transaction{tx=>
                tx.execute("INSERT OR IGNORE INTO artifacts(hash,mime,size,metadata,relative_path) VALUES(?,?,?,?,?)",
                    [SqlParameter.Text(artifact.sha256),SqlParameter.Text(artifact.contentType),SqlParameter.Int64Value(artifact.bytes),
                        SqlParameter.Text(hostArtifactMetadata(artifact)),SqlParameter.Text("blobs/"+artifact.sha256+".txt")])
                match(retainPreparedPluginDocumentResult(tx,link,parent,{bytes=>reserveNativeDocumentPayload(bytes)},
                    {=>writer.verifyCanonicalDocument(path,current,receiptValue:true)})){
                    case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
                match(current()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}}
            Result.Ok(())
        }catch(error:HostArtifactOperationFailure){Result.Err(error.failure)}
        catch(_:Exception){hostResourceError("plugin.document_result_preparation_failed")}
        finally{lock.unlock()}
    }

    public func retainDocumentWindowResult(links:Array<ContextReadFactLink>,parent:AgentValue,writer:HostServiceArtifactWriter,
        current:()->Result<Unit>):Result<Unit>{
        lock.lock()
        try{
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(database.isNone()){return hostResourceError("plugin.document_query_store_missing")}
            let host=parent.field("host_plan").getOrThrow()
            if(!pluginDocumentRowJournalFrozenResultValid(host)){return hostResourceError("plugin.document_result_invalid")}
            let reference=parsePluginDocumentPayloadReference(host.field("result_payload").getOrThrow()).value().getOrThrow()
            let artifact=writer.completedArtifact()
            if(reference.digest!=artifact.sha256 || reference.bytes!=artifact.bytes){return hostResourceError("plugin.document_result_changed")}
            match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let path=blobPath(artifact.sha256)
            match(writer.publish(path,guard:current)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            database.getOrThrow().transaction{tx=>
                tx.execute("INSERT OR IGNORE INTO artifacts(hash,mime,size,metadata,relative_path) VALUES(?,?,?,?,?)",
                    [SqlParameter.Text(artifact.sha256),SqlParameter.Text(artifact.contentType),SqlParameter.Int64Value(artifact.bytes),
                        SqlParameter.Text(hostArtifactMetadata(artifact)),SqlParameter.Text("blobs/"+artifact.sha256+".txt")])
                match(retainPreparedPluginDocumentWindowResult(tx,links,parent,{bytes=>reserveNativeDocumentPayload(bytes)},
                    {=>writer.verifyCanonicalDocument(path,current,receiptValue:true)})){
                    case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
                match(current()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}}
            Result.Ok(())
        }catch(error:HostArtifactOperationFailure){Result.Err(error.failure)}
        catch(_:Exception){hostResourceError("plugin.document_result_preparation_failed")}
        finally{lock.unlock()}
    }

    public func verifyDocumentFrozenResult(context:ToolInvocationContext,prepared:PreparedToolInvocation,
        current:()->Result<Unit>,completedChildren!:Bool=false):Result<Unit>{
        lock.lock()
        try{
            match(ensureArtifactRoot()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(database.isNone() || operations.isNone() || prepared.source.operationRoot.isNone()){
                return hostResourceError("plugin.document_result_source_missing")}
            operations.getOrThrow().verifyDocumentFrozenResultExecuting(prepared.operationId,context.runId,
                ThreadId(context.sessionId.value),context.epoch,prepared.source.operationRoot.getOrThrow(),prepared.operationPlan,current,
                completedChildren:completedChildren)
        }finally{lock.unlock()}
    }

    // Current invocation owners only. The caller never receives the internal
    // temporary pathname and cannot choose an existing artifact reference.
    public func openServiceArtifactWriter(): Result<HostServiceArtifactWriter> {
        lock.lock()
        try {
            match (ensureArtifactRoot()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            // Claim memory before any file exists. The returned writer has no
            // OS handle until the invocation session has adopted it.
            var reserved: ?LogicalJsonFixedBufferReservation = None
            try {
                let selected = reserveNativeObservationBuffer(); reserved = Some(selected)
                Result.Ok(HostServiceArtifactWriter(root, selected))
            } catch (_: Exception) {
                match (reserved) { case Some(value) => value.close(); case None => () }
                hostArtifactError<HostServiceArtifactWriter>(AgentErrorKind.Internal,
                    "artifact.stream_open_failed", "could not reserve an owned observation file", "")
            }
        } finally { lock.unlock() }
    }

    func verifyToolInputAttachment(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<Unit> {
        let actual = match (database) { case Some(value) => value
            case None => return hostResourceError("input_attachment.store_required") }
        if (prepared.source.operationRoot.isNone()) { return hostResourceError("input_attachment.source_invalid") }
        try {
            actual.transaction { tx =>
                match (context.cancellation.check()) { case Result.Err(_) => throw IllegalStateException("input owner cancelled"); case Result.Ok(_) => () }
                verifyToolInputAttachmentExecuting(tx, prepared.operationId, context.runId, ThreadId(context.sessionId.value),
                    context.epoch, prepared.source.operationRoot.getOrThrow(), prepared.operationPlan)
            }
            Result.Ok(())
        } catch (_: Exception) { hostResourceError("input_attachment.root_changed") }
    }
    func verifyRetainedToolInputAttachment(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        writer: HostServiceArtifactWriter, expected: AgentValue, lifetime: () -> Result<Unit>): Result<Unit> {
        let actual = match (database) { case Some(value) => value; case None => return hostResourceError("input_attachment.store_required") }
        if (prepared.source.operationRoot.isNone()) { return hostResourceError("input_attachment.source_invalid") }
        lock.lock(); try {
            match (lifetime()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            actual.transaction { tx =>
                let recorded = tx.query("SELECT payload FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='tool_input_attached'",
                    [SqlParameter.Text(prepared.operationId.value), SqlParameter.Text(context.runId.value), SqlParameter.Text(context.sessionId.value)])
                if (recorded.size != 1) { throw IllegalStateException("actual retained input evidence is missing") }
                let pin = decodeStoredValue(recorded[0].required(0))
                if (!httpIntentExactFields(pin, ["evidence", "call_payload", "call_provenance"]) ||
                    canonicalAgentValue(pin.field("evidence").getOrThrow()) != canonicalAgentValue(expected)) {
                    throw IllegalStateException("actual retained input evidence changed") }
                let current = input_store.retainToolInputAttachment(tx, prepared.operationId, context.runId, ThreadId(context.sessionId.value),
                    context.epoch, prepared.source.operationRoot.getOrThrow(), prepared.operationPlan, writer.completedArtifact().value())
                if (canonicalAgentValue(current) != canonicalAgentValue(expected)) { throw IllegalStateException("retained input Root changed") }
                match (writer.verifyPublished(blobPath(writer.completedArtifact().sha256), guard: lifetime)) {
                    case Result.Err(_) => throw IllegalStateException("actual retained input file changed"); case Result.Ok(_) => () }
            }
            Result.Ok(())
        } catch (_: Exception) { hostResourceError("input_attachment.retained_changed") }
        finally { lock.unlock() }
    }
    func retainToolInputAttachment(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        writer: HostServiceArtifactWriter, lifetime: () -> Result<Unit>): Result<AgentValue> {
        let actual = match (database) { case Some(value) => value
            case None => return hostResourceError("input_attachment.store_required") }
        let rootSource = match (prepared.source.operationRoot) { case Some(value) => value
            case None => return hostResourceError("input_attachment.source_invalid") }
        lock.lock()
        try {
            match (lifetime()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (verifyToolInputAttachment(context, prepared)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let artifact = writer.completedArtifact()
            match (writer.publish(blobPath(artifact.sha256), guard: lifetime)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (persistArtifactMetadata(artifact)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let result = actual.transaction { tx =>
                // No callback enters Source/Host/Store inside this TX. The
                // exact current SQL proof and GC pin share its IMMEDIATE lock.
                match (lifetime()) { case Result.Err(_) => throw IllegalStateException("input owner cancelled"); case Result.Ok(_) => () }
                match (writer.verifyPublished(blobPath(artifact.sha256), guard: lifetime)) {
                    case Result.Err(_) => throw IllegalStateException("input file changed before its actual Root pin"); case Result.Ok(_) => () }
                input_store.retainToolInputAttachment(tx, prepared.operationId, context.runId, ThreadId(context.sessionId.value),
                    context.epoch, rootSource, prepared.operationPlan, artifact.value())
            }
            match (lifetime()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            Result.Ok(result)
        } catch (_: Exception) { hostResourceError("input_attachment.not_retained") }
        finally { lock.unlock() }
    }

    public func retainServiceArtifact(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        binding: AgentValue, stream: String, writer: HostServiceArtifactWriter): Result<AgentValue> {
        if (database.isNone()) { return hostResourceError("artifact.observation_store_required") }
        let store = match (operations) { case Some(value) => value
            case None => return hostResourceError("artifact.observation_store_required") }
        let rootSource = match (prepared.source.operationRoot) { case Some(value) => value
            case None => return hostResourceError("artifact.observation_source_invalid") }
        let artifact = writer.completedArtifact()
        lock.lock()
        try {
            if (context.cancellation.isCancelled()) { return hostResourceCancelled() }
            match (writer.publish(blobPath(artifact.sha256))) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (persistArtifactMetadata(artifact)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let evidence = objectValue([ValueField("schema", textValue("axyndra.service-artifact-observation/v1")),
                ValueField("stream", textValue(stream)), ValueField("artifact", artifact.value()),
                ValueField("operation_id", textValue(prepared.operationId.value))])
            match (store.retainChannelArtifactObservation(prepared.operationId,
                context.runId, ThreadId(context.sessionId.value), context.epoch, rootSource,
                prepared.operationPlan, binding, evidence, { =>
                    if (context.cancellation.isCancelled()) { return hostResourceCancelled() }
                    writer.verifyPublished(blobPath(artifact.sha256))
                })) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => Result.Ok(objectValue([ValueField("artifact", artifact.value(stream: stream)),
                    ValueField("preview", textValue(writer.preview())), ValueField("truncated", boolValue(artifact.bytes > 8192))]))
            }
        } catch (_: Exception) { hostResourceError("artifact.observation_not_retained") }
        finally { lock.unlock() }
    }

    // Host-only preparation seam. A plugin may supply bytes to its pure
    // preparation, but never a reference. Persist the immutable text encoding,
    // then bind it to the actual Run/epoch/call inside the same SQLite store.
    // No operation, approval, source or I/O grant is created here.
    public func stageServicePayload(context: ToolInvocationContext, call: ToolCall, binding: AgentValue,
        id: String, hexadecimal: String): Result<AgentValue> {
        let selected = match (servicePayloadLimits(binding)) {
            case Result.Ok(Some(value)) => value
            case _ => return hostArtifactError<AgentValue>(AgentErrorKind.PermissionDenied, "artifact.payload_not_granted", "payload profile is absent", "")
        }
        let bytes = match (channelServiceWriteBytes(objectValue([ValueField("id", textValue(id)),
            ValueField("bytes_hex", textValue(hexadecimal))]), maximumBytes: selected.maxWriteBytes)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        let actual = match (database) { case Some(value) => value
            case None => return hostArtifactError<AgentValue>(AgentErrorKind.PermissionDenied, "artifact.payload_store_required", "payload preparation requires the canonical Store", "") }
        let artifact = match (persistText(hexadecimal)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let payload = objectValue([ValueField("schema", textValue(SERVICE_PAYLOAD_REFERENCE_SCHEMA)),
            ValueField("artifact_ref", textValue(artifact.reference)), ValueField("encoding", textValue("hex")),
            ValueField("bytes", integerValue(bytes.size)), ValueField("sha256", textValue(hostArtifactSha256(bytes))),
            ValueField("encoded_sha256", textValue(artifact.sha256))])
        let intent = objectValue([ValueField("id", textValue(id)), ValueField("payload", payload)])
        let evidence = servicePayloadPreparationWitness(context.sessionId.value, context.runId.value, context.epoch,
            call.callId, call.name, call.arguments, binding, intent)
        lock.lock()
        try {
            actual.transaction { transaction =>
                if (context.cancellation.isCancelled() || context.epoch < 1 || httpIntentText(binding, "target_thread_id") != context.sessionId.value) {
                    throw IllegalStateException("payload preparation owner is cancelled")
                }
                let owner = transaction.query("SELECT r.id FROM runs r JOIN threads t ON t.id=r.thread_id " +
                    "JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id WHERE r.id=? AND r.thread_id=? " +
                    "AND r.epoch=? AND r.state='running' AND t.active_turn_id=r.turn_id AND turn.active_run_id=r.id",
                    [SqlParameter.Text(context.runId.value), SqlParameter.Text(context.sessionId.value), SqlParameter.Int64Value(context.epoch)])
                if (owner.size != 1) { throw IllegalStateException("payload preparation has no live canonical Run") }
                // GC's final scan/delete uses an IMMEDIATE transaction too.
                // If it won the race, this bounded reread fails before the pin.
                let actualBytes = readServicePayloadInTransaction(transaction, payload, selected.maxWriteBytes)
                if (actualBytes.size != bytes.size || hostArtifactSha256(actualBytes) != hostArtifactSha256(bytes)) {
                    throw IllegalStateException("payload content changed before its preparation witness")
                }
                let encoded = encodeStoredValue(evidence)
                let existing = transaction.query("SELECT id FROM audit_events WHERE kind='service_payload_prepared' " +
                    "AND thread_id=? AND run_id=? AND operation_id IS NULL AND payload=?",
                    [SqlParameter.Text(context.sessionId.value), SqlParameter.Text(context.runId.value), SqlParameter.Text(encoded)])
                if (existing.size > 1) { throw IllegalStateException("payload preparation witness is ambiguous") }
                if (existing.isEmpty()) {
                    let count = transaction.query("SELECT COUNT(*) FROM audit_events WHERE kind='service_payload_prepared' AND run_id=?",
                        [SqlParameter.Text(context.runId.value)])
                    if (Int64.parse(count[0].required(0)) >= 256) { throw IllegalStateException("payload preparation history limit exceeded") }
                    transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
                        "VALUES(?,?,NULL,'service_payload_prepared',?,?)", [SqlParameter.Text(context.sessionId.value),
                        SqlParameter.Text(context.runId.value), SqlParameter.Text(encoded), SqlParameter.Int64Value(agentUtcMillis())])
                }
            }
            Result.Ok(intent)
        } catch (_: Exception) {
            hostArtifactError<AgentValue>(AgentErrorKind.Conflict, "artifact.payload_preparation_failed", "payload preparation no longer matches canonical state or content", artifact.reference)
        } finally { lock.unlock() }
    }

    // Diagnostic retention after a real handoff. This does not change the
    // Operation state or authorize a retry. Cancellation does not erase an
    // already observed result: it is retained as untrusted evidence only.
    public func retainServiceObservation(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        output: AgentValue): Result<OperationObservation> {
        let actual = match (database) { case Some(value) => value
            case None => return hostArtifactError<OperationObservation>(AgentErrorKind.PermissionDenied, "artifact.observation_store_required", "canonical Store is required", "") }
        if (prepared.source.operationRoot.isNone() || prepared.source.kind == PreparedInvocationSourceKind.Derived ||
            prepared.source.sessionId.value != context.sessionId.value || prepared.source.runId.value != context.runId.value ||
            prepared.source.epoch != context.epoch) {
            return hostArtifactError<OperationObservation>(AgentErrorKind.PermissionDenied, "artifact.observation_source_invalid", "observation has no exact canonical root", "")
        }
        let root = prepared.source.operationRoot.getOrThrow()
        let encoded = stringifyUnifiedJson(output)
        if (encoded.size > 8388608) { return hostArtifactError<OperationObservation>(AgentErrorKind.InvalidInput,
            "artifact.observation_too_large", "observed JSON exceeds its granted result envelope", "") }
        let artifact = match (persistText(encoded)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let evidence = objectValue([ValueField("schema", textValue("axyndra.service-observation/v1")),
            ValueField("artifact_ref", textValue(artifact.reference)), ValueField("sha256", textValue(artifact.sha256)),
            ValueField("bytes", integerValue(artifact.bytes)), ValueField("content_type", textValue(artifact.contentType)),
            ValueField("format", textValue("json")), ValueField("operation_id", textValue(prepared.operationId.value))])
        let observation = OperationObservation(stringifyUnifiedJson(evidence))
        lock.lock()
        try {
            actual.transaction { transaction =>
                let rows = transaction.query("SELECT e.normalized_plan FROM operations o JOIN runs r ON r.id=o.run_id " +
                    "JOIN operation_effect_records e ON e.operation_id=o.id WHERE o.id=? AND o.run_id=? AND r.thread_id=? AND r.epoch=? " +
                    "AND o.tool_call_item_id=? AND EXISTS (SELECT 1 FROM audit_events a WHERE a.operation_id=o.id " +
                    "AND a.run_id=r.id AND a.thread_id=r.thread_id AND a.kind='operation_execution_handoff')",
                    [SqlParameter.Text(prepared.operationId.value), SqlParameter.Text(context.runId.value),
                        SqlParameter.Text(context.sessionId.value), SqlParameter.Int64Value(context.epoch), SqlParameter.Text(root.itemId().value)])
                if (rows.size != 1 || !storedOperationPlanMatches(rows[0].required(0), prepared.operationPlan)) {
                    throw IllegalStateException("observation differs from the actual handed off canonical operation")
                }
                // Serialize with the final GC reference scan/delete. A prior
                // GC win or conflicting old MIME identity causes no pin.
                let metadata = transaction.query("SELECT mime,size,metadata,relative_path FROM artifacts WHERE hash=?", [SqlParameter.Text(artifact.sha256)])
                if (metadata.size != 1 || metadata[0].required(0) != artifact.contentType ||
                    metadata[0].required(1) != artifact.bytes.toString() || metadata[0].required(2) != hostArtifactMetadata(artifact) ||
                    metadata[0].required(3) != "blobs/" + artifact.sha256 + ".txt") { throw IllegalStateException("observation artifact identity changed") }
                let path = blobPath(artifact.sha256); let info = FileInfo(Path(path))
                if (!info.isRegular() || info.isSymbolicLink() || info.size != artifact.bytes) { throw IllegalStateException("observation artifact disappeared") }
                let hasher = SHA256(); let file = File(path, OpenMode.Read); let buffer = Array<Byte>(8192, repeat: 0)
                var bytes: Int64 = 0
                try {
                    while (true) {
                        let count = file.read(buffer); if (count == 0) { break }
                        if (count > artifact.bytes - bytes) { throw IllegalStateException("observation artifact grew") }
                        hasher.write(buffer[0..count]); bytes += count
                    }
                } finally { file.close() }
                if (bytes != artifact.bytes || hostArtifactHex(hasher.finish()) != artifact.sha256) { throw IllegalStateException("observation artifact bytes changed") }
                let prior = transaction.query("SELECT payload FROM audit_events WHERE operation_id=? AND kind='service_output_observed'", [SqlParameter.Text(prepared.operationId.value)])
                let stored = encodeStoredValue(observation.toValue())
                if (prior.size > 1 || (prior.size == 1 && prior[0].required(0) != stored)) { throw IllegalStateException("operation already retained a different observation") }
                if (prior.isEmpty()) {
                    transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) VALUES(?,?,?,'service_output_observed',?,?)",
                        [SqlParameter.Text(context.sessionId.value), SqlParameter.Text(context.runId.value), SqlParameter.Text(prepared.operationId.value),
                            SqlParameter.Text(stored), SqlParameter.Int64Value(agentUtcMillis())])
                }
            }
            Result.Ok(observation)
        } catch (_: Exception) { hostArtifactError<OperationObservation>(AgentErrorKind.Conflict, "artifact.observation_not_retained", "observation could not be pinned to canonical history", artifact.reference) }
        finally { lock.unlock() }
    }

    // The caller must first prove the actual Executing child and handoff. This
    // method only resolves bounded immutable content; it grants no execution.
    // Trusted composition supplies one fixed-purpose payload pin port. It is
    // never passed to a plugin, SDK, or JS broker, and exposes no database getter.
    // The port cannot move the immutable-content reread outside this owner's
    // original lock and SQLite transaction. Runtime gates run in the adapter,
    // before and after this method, never while a Store transaction is held.
    public func stagePreparedPayload(id: String, hexadecimal: String, maximum: Int64,
        pin: HostArtifactPayloadPin): Result<AgentValue> {
        let bytes = match (channelServiceWriteBytes(objectValue([ValueField("id", textValue(id)),
            ValueField("bytes_hex", textValue(hexadecimal))]), maximumBytes: maximum)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let actual = match (database) { case Some(value) => value
            case None => return Result<AgentValue>.Err(pin.storageRequiredError()) }
        let artifact = match (persistText(hexadecimal)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let payload = objectValue([ValueField("schema", textValue(SERVICE_PAYLOAD_REFERENCE_SCHEMA)),
            ValueField("artifact_ref", textValue(artifact.reference)), ValueField("encoding", textValue("hex")),
            ValueField("bytes", integerValue(bytes.size)), ValueField("sha256", textValue(hostArtifactSha256(bytes))),
            ValueField("encoded_sha256", textValue(artifact.sha256))])
        lock.lock()
        try {
            actual.transaction { transaction =>
                pin.requireCurrent(transaction)
                let actualBytes = readServicePayloadInTransaction(transaction, payload, maximum)
                if (actualBytes.size != bytes.size || hostArtifactSha256(actualBytes) != hostArtifactSha256(bytes)) {
                    throw IllegalStateException("prepared payload content changed before its pin")
                }
                pin.retain(transaction, payload)
            }
            Result.Ok(payload)
        } catch (_: Exception) { Result<AgentValue>.Err(pin.retentionError(artifact.reference)) }
        finally { lock.unlock() }
    }

    public func readPreparedPayload(payload: AgentValue, maximum: Int64,
        pin: HostArtifactPayloadPin): Result<Array<Byte>> {
        let actual = match (database) { case Some(value) => value
            case None => return Result<Array<Byte>>.Err(pin.storageRequiredError()) }
        lock.lock()
        try {
            Result<Array<Byte>>.Ok(actual.transaction { transaction =>
                pin.requireCurrent(transaction)
                pin.requireRetained(transaction, payload)
                readServicePayloadInTransaction(transaction, payload, maximum)
            })
        } catch (_: Exception) { Result<Array<Byte>>.Err(pin.readError()) }
        finally { lock.unlock() }
    }

    // Host-internal export content. This validates only a blob reference and
    // the original immutable bytes; the concrete destination policy remains
    // in the concrete host workspace adapter and is never a plugin path.
    public func readCompleteText(reference: String): Result<String> {
        let hash = match (hostArtifactHash(reference)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        lockAndReadText(hash)
    }

    public func readServicePayload(payload: AgentValue, maximum: Int64): Result<Array<Byte>> {
        let actual = match (database) { case Some(value) => value
            case None => return hostArtifactError<Array<Byte>>(AgentErrorKind.PermissionDenied, "artifact.payload_store_required", "canonical Store is required", "") }
        lock.lock()
        try { Result.Ok(actual.transaction { transaction => readServicePayloadInTransaction(transaction, payload, maximum) }) }
        catch (_: Exception) { hostArtifactError<Array<Byte>>(AgentErrorKind.Conflict, "artifact.payload_invalid", "payload content or canonical metadata changed", "") }
        finally { lock.unlock() }
    }

    private func readServicePayloadInTransaction(transaction: SqliteTransaction, payload: AgentValue, maximum: Int64): Array<Byte> {
        let size = servicePayloadReferenceBytes(payload, maximum).value().getOrThrow()
        let hash = httpIntentText(payload, "encoded_sha256")
        let artifact = HostArtifact("blob:sha256:" + hash, hash, size * 2)
        let rows = transaction.query("SELECT mime,size,metadata,relative_path FROM artifacts WHERE hash=?", [SqlParameter.Text(hash)])
        if (rows.size != 1 || rows[0].required(0) != artifact.contentType || rows[0].required(1) != artifact.bytes.toString() ||
            rows[0].required(2) != hostArtifactMetadata(artifact) || rows[0].required(3) != "blobs/" + hash + ".txt") {
            throw IllegalStateException("payload metadata differs from immutable text artifact")
        }
        let path = blobPath(hash); let info = FileInfo(Path(path))
        if (!info.isRegular() || info.isSymbolicLink() || info.size != artifact.bytes) { throw IllegalStateException("payload file shape changed") }
        let encoded = Array<Byte>(artifact.bytes, repeat: 0)
        let buffer = Array<Byte>(8192, repeat: 0); let file = File(path, OpenMode.Read)
        var offset: Int64 = 0
        try {
            while (true) {
                let count = file.read(buffer)
                if (count == 0) { break }
                if (count > encoded.size - offset) { throw IllegalStateException("payload grew while reading") }
                for (index in 0..count) { encoded[offset + index] = buffer[index] }
                offset += count
            }
        } finally { file.close() }
        if (offset != encoded.size || hostArtifactSha256(encoded) != hash) { throw IllegalStateException("payload file digest changed") }
        let bytes = channelServiceWriteBytes(objectValue([ValueField("id", textValue("payload")),
            ValueField("bytes_hex", textValue(String.fromUtf8(encoded)))]), maximumBytes: maximum).value().getOrThrow()
        if (bytes.size != size || hostArtifactSha256(bytes) != httpIntentText(payload, "sha256")) { throw IllegalStateException("payload raw bytes differ from frozen intent") }
        bytes
    }

    // Blob offsets and limits are byte based. The returned window is always
    // valid UTF-8 and is capped at one MiB even when a larger limit is asked.
    public func read(
        reference: String,
        offset!: Int64 = 0,
        limit!: Int64 = HOST_ARTIFACT_PREVIEW_BYTES
    ): Result<HostArtifactRead> {
        if (offset < 0) {
            return hostArtifactError<HostArtifactRead>(
                AgentErrorKind.InvalidInput,
                "artifact.offset_invalid",
                "artifact offset must not be negative",
                reference
            )
        }
        if (limit < 1) {
            return hostArtifactError<HostArtifactRead>(
                AgentErrorKind.InvalidInput,
                "artifact.limit_invalid",
                "artifact limit must be positive",
                reference
            )
        }
        let hash = match (hostArtifactHash(reference)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        lock.lock()
        try {
            let bytes = match (validatedArtifactBytes(hash)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let start = min(offset, bytes.size)
            if (!hostArtifactUtf8Boundary(bytes, start)) {
                return hostArtifactError<HostArtifactRead>(
                    AgentErrorKind.InvalidInput,
                    "artifact.offset_not_utf8_boundary",
                    "artifact offset must point to a UTF-8 boundary",
                    reference
                )
            }
            let requested = min(limit, HOST_ARTIFACT_PREVIEW_BYTES)
            let prefix = hostArtifactUtf8Prefix(bytes[start..], requested)
            if (prefix.isEmpty() && start < bytes.size) {
                return hostArtifactError<HostArtifactRead>(
                    AgentErrorKind.InvalidInput,
                    "artifact.limit_splits_utf8",
                    "artifact limit is too small to return the next UTF-8 character",
                    reference
                )
            }
            Result.Ok(
                HostArtifactRead(
                    reference,
                    String.fromUtf8(prefix),
                    bytes.size,
                    start,
                    prefix.size,
                    start + prefix.size < bytes.size
                )
            )
        } finally {
            lock.unlock()
        }
    }

    private func lockAndReadText(hash: String): Result<String> {
        lock.lock()
        try {
            match (validatedArtifactBytes(hash)) {
                case Result.Ok(bytes) => Result.Ok(String.fromUtf8(bytes))
                case Result.Err(error) => Result.Err(error)
            }
        } finally {
            lock.unlock()
        }
    }

    private func ensureArtifactRoot(): Result<Unit> {
        try {
            if (!exists(Path(root))) {
                Directory.create(root, recursive: true)
            }
            let info = FileInfo(Path(root))
            if (!info.isDirectory() || info.isSymbolicLink()) {
                return hostArtifactError<Unit>(
                    AgentErrorKind.PermissionDenied,
                    "artifact.root_unsafe",
                    "artifact root must be a real directory",
                    root
                )
            }
            hostArtifactChmod(root, "700")
        } catch (error: Exception) {
            hostArtifactError<Unit>(
                AgentErrorKind.Internal,
                "artifact.root_failed",
                error.message,
                root
            )
        }
    }

    private func persistArtifactFile(
        artifact: HostArtifact,
        bytes: Array<Byte>
    ): Result<Unit> {
        let path = blobPath(artifact.sha256)
        if (exists(Path(path))) {
            return validateExistingBlob(path, artifact.sha256, bytes.size)
        }
        match (hostAtomicArtifactWrite(path, bytes)) {
            case Result.Ok(_) => validateExistingBlob(path, artifact.sha256, bytes.size)
            case Result.Err(error) =>
                if (exists(Path(path))) {
                    validateExistingBlob(path, artifact.sha256, bytes.size)
                } else {
                    Result.Err(error)
                }
        }
    }

    private func persistArtifactMetadata(artifact: HostArtifact): Result<Unit> {
        match (database) {
            case Some(value) => return persistArtifactMetadataRow(value, artifact)
            case None => ()
        }
        let path = metadataPath(artifact.sha256)
        let body = hostArtifactMetadata(artifact).toArray()
        if (exists(Path(path))) {
            return validateExistingMetadata(path, body, artifact.reference)
        }
        match (hostAtomicArtifactWrite(path, body)) {
            case Result.Ok(_) => validateExistingMetadata(path, body, artifact.reference)
            case Result.Err(error) =>
                if (exists(Path(path))) {
                    validateExistingMetadata(path, body, artifact.reference)
                } else {
                    Result.Err(error)
                }
        }
    }

    private func validatedArtifactBytes(hash: String): Result<Array<Byte>> {
        let path = blobPath(hash)
        let meta = metadataPath(hash)
        let metadataExists = match (database) {
            case Some(value) => value.scalarInt(
                "SELECT COUNT(*) FROM artifacts WHERE hash=" + sqliteText(hash)
            ) == 1
            case None => exists(Path(meta))
        }
        if (!exists(Path(path)) || !metadataExists) {
            return hostArtifactError<Array<Byte>>(
                AgentErrorKind.InvalidInput,
                "artifact.not_found",
                "artifact blob or metadata does not exist",
                HOST_ARTIFACT_PREFIX + hash
            )
        }
        try {
            let info = FileInfo(Path(path))
            if (!info.isRegular() || info.isSymbolicLink()) {
                return hostArtifactError<Array<Byte>>(
                    AgentErrorKind.PermissionDenied,
                    "artifact.blob_unsafe",
                    "artifact blob must be a regular non-symlink file",
                    HOST_ARTIFACT_PREFIX + hash
                )
            }
            let bytes = File.readFrom(path)
            if (hostArtifactSha256(bytes) != hash) {
                return hostArtifactError<Array<Byte>>(
                    AgentErrorKind.Conflict,
                    "artifact.blob_corrupt",
                    "artifact blob does not match its SHA-256 name",
                    HOST_ARTIFACT_PREFIX + hash
                )
            }
            let artifact = HostArtifact(
                HOST_ARTIFACT_PREFIX + hash,
                hash,
                bytes.size
            )
            let metadataValidation = match (database) {
                case Some(value) => validateArtifactMetadataRow(value, artifact)
                case None => validateExistingMetadata(
                    meta,
                    hostArtifactMetadata(artifact).toArray(),
                    artifact.reference
                )
            }
            match (metadataValidation) {
                case Result.Ok(_) => Result.Ok(bytes)
                case Result.Err(error) => Result.Err(error)
            }
        } catch (error: Exception) {
            hostArtifactError<Array<Byte>>(
                AgentErrorKind.Internal,
                "artifact.read_failed",
                error.message,
                HOST_ARTIFACT_PREFIX + hash
            )
        }
    }

    private func validateExistingBlob(
        path: String,
        expectedHash: String,
        expectedBytes: Int64
    ): Result<Unit> {
        try {
            let info = FileInfo(Path(path))
            if (!info.isRegular() || info.isSymbolicLink()) {
                return hostArtifactError<Unit>(
                    AgentErrorKind.Conflict,
                    "artifact.blob_conflict",
                    "existing artifact blob is not a safe regular file",
                    HOST_ARTIFACT_PREFIX + expectedHash
                )
            }
            if (info.size != expectedBytes) {
                return hostArtifactError<Unit>(
                    AgentErrorKind.Conflict,
                    "artifact.blob_corrupt",
                    "existing artifact blob has a different byte length",
                    HOST_ARTIFACT_PREFIX + expectedHash
                )
            }
            let actual = hostArtifactSha256(File.readFrom(path))
            if (actual != expectedHash) {
                return hostArtifactError<Unit>(
                    AgentErrorKind.Conflict,
                    "artifact.blob_corrupt",
                    "existing artifact blob does not match its SHA-256 name",
                    HOST_ARTIFACT_PREFIX + expectedHash
                )
            }
            Result.Ok(())
        } catch (error: Exception) {
            hostArtifactError<Unit>(
                AgentErrorKind.Internal,
                "artifact.blob_validate_failed",
                error.message,
                HOST_ARTIFACT_PREFIX + expectedHash
            )
        }
    }

    private func validateExistingMetadata(
        path: String,
        expected: Array<Byte>,
        reference: String
    ): Result<Unit> {
        try {
            let info = FileInfo(Path(path))
            if (!info.isRegular() || info.isSymbolicLink()) {
                return hostArtifactError<Unit>(
                    AgentErrorKind.Conflict,
                    "artifact.metadata_conflict",
                    "existing artifact metadata is not a safe regular file",
                    reference
                )
            }
            if (File.readFrom(path) != expected) {
                return hostArtifactError<Unit>(
                    AgentErrorKind.Conflict,
                    "artifact.metadata_corrupt",
                    "existing artifact metadata does not match the blob",
                    reference
                )
            }
            Result.Ok(())
        } catch (error: Exception) {
            hostArtifactError<Unit>(
                AgentErrorKind.Internal,
                "artifact.metadata_validate_failed",
                error.message,
                reference
            )
        }
    }

    private func blobPath(hash: String): String {
        root + "/" + hash + ".txt"
    }

    private func metadataPath(hash: String): String {
        root + "/" + hash + ".json"
    }

    private func persistArtifactMetadataRow(
        database: SqliteDatabase,
        artifact: HostArtifact
    ): Result<Unit> {
        try {
            database.execute(
                "INSERT OR IGNORE INTO artifacts(hash,mime,size,metadata,relative_path) VALUES(" +
                    sqliteText(artifact.sha256) + "," + sqliteText(artifact.contentType) + "," +
                    artifact.bytes.toString() + "," + sqliteText(hostArtifactMetadata(artifact)) + "," +
                    sqliteText("blobs/" + artifact.sha256 + ".txt") + ")"
            )
            validateArtifactMetadataRow(database, artifact)
        } catch (error: Exception) {
            hostArtifactError<Unit>(
                AgentErrorKind.Internal,
                "artifact.metadata_commit_failed",
                error.message,
                artifact.reference
            )
        }
    }

    private func validateArtifactMetadataRow(
        database: SqliteDatabase,
        artifact: HostArtifact
    ): Result<Unit> {
        try {
            let rows = database.query(
                "SELECT mime,size,metadata,relative_path FROM artifacts WHERE hash=" +
                    sqliteText(artifact.sha256)
            )
            if (rows.size != 1 || rows[0].required(0) != artifact.contentType ||
                Int64.parse(rows[0].required(1)) != artifact.bytes ||
                rows[0].required(2) != hostArtifactMetadata(artifact) ||
                rows[0].required(3) != "blobs/" + artifact.sha256 + ".txt") {
                return hostArtifactError<Unit>(
                    AgentErrorKind.Conflict,
                    "artifact.metadata_corrupt",
                    "artifact metadata row does not match the blob",
                    artifact.reference
                )
            }
            Result.Ok(())
        } catch (error: Exception) {
            hostArtifactError<Unit>(
                AgentErrorKind.Internal,
                "artifact.metadata_validate_failed",
                error.message,
                artifact.reference
            )
        }
    }
}

public class HostProcessArtifactCapture {
    public let stdout: HostArtifactCapture
    public let stderr: HostArtifactCapture

    public init(
        store: ?HostArtifactStore,
        stdout: String,
        stderr: String
    ) {
        this.stdout = captureHostArtifactStream(store, "stdout", stdout)
        this.stderr = captureHostArtifactStream(store, "stderr", stderr)
    }

    public func artifactsValue(): AgentValue {
        let values = ArrayList<AgentValue>()
        match (stdout.artifact) {
            case Some(value) => values.add(value.value(stream: "stdout"))
            case None => ()
        }
        match (stderr.artifact) {
            case Some(value) => values.add(value.value(stream: "stderr"))
            case None => ()
        }
        listValue(values.toArray())
    }

    public func errorValue(): AgentValue {
        let values = ArrayList<AgentValue>()
        addHostArtifactCaptureError(values, stdout)
        addHostArtifactCaptureError(values, stderr)
        if (values.isEmpty()) {
            return nullValue()
        }
        objectValue([ValueField("errors", listValue(values.toArray()))])
    }
}

public func captureHostProcessArtifacts(
    store: ?HostArtifactStore,
    stdout: String,
    stderr: String
): HostProcessArtifactCapture {
    HostProcessArtifactCapture(store, stdout, stderr)
}

public func captureHostArtifactStream(
    store: ?HostArtifactStore,
    stream: String,
    content: String
): HostArtifactCapture {
    let bytes = content.toArray()
    if (bytes.size <= HOST_ARTIFACT_PREVIEW_BYTES) {
        return HostArtifactCapture(stream, content, bytes.size, false)
    }
    match (store) {
        case Some(value) => value.capture(stream, content)
        case None => HostArtifactCapture(
            stream,
            hostArtifactPreview(bytes, HOST_ARTIFACT_PREVIEW_BYTES),
            bytes.size,
            true,
            error: Some(
                AgentError(
                    AgentErrorKind.Configuration,
                    "artifact.store_unavailable",
                    "complete oversized output could not be stored because no artifact store is installed",
                    fields: [ErrorField("stream", stream)]
                )
            )
        )
    }
}

public func addHostArtifactCaptureError(
    values: ArrayList<AgentValue>,
    capture: HostArtifactCapture
): Unit {
    match (capture.error) {
        case Some(error) => values.add(
            objectValue(
                [
                    ValueField("stream", textValue(capture.stream)),
                    ValueField("code", textValue(error.code)),
                    ValueField("message", textValue(error.message))
                ]
            )
        )
        case None => ()
    }
}

public func isHostArtifactReference(value: String): Bool {
    value.startsWith("blob:")
}

public func hostArtifactHash(reference: String): Result<String> {
    if (!reference.startsWith(HOST_ARTIFACT_PREFIX)) {
        return hostArtifactError<String>(
            AgentErrorKind.InvalidInput,
            "artifact.ref_invalid",
            "artifact reference must use blob:sha256:<64 lowercase hex>",
            reference
        )
    }
    let hash = reference[HOST_ARTIFACT_PREFIX.size..]
    if (hash.size != 64) {
        return hostArtifactError<String>(
            AgentErrorKind.InvalidInput,
            "artifact.ref_invalid",
            "artifact reference must contain exactly 64 lowercase hex characters",
            reference
        )
    }
    for (byte in hash.toArray()) {
        if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) {
            return hostArtifactError<String>(
                AgentErrorKind.InvalidInput,
                "artifact.ref_invalid",
                "artifact reference must contain exactly 64 lowercase hex characters",
                reference
            )
        }
    }
    Result.Ok(hash)
}

public func hostArtifactSha256(bytes: Array<Byte>): String {
    modelPolicySha256(bytes)
}

public func hostArtifactMetadata(artifact: HostArtifact): String {
    encodeAgentValue(
        objectValue(
            [
                ValueField("version", integerValue(1)),
                ValueField("ref", textValue(artifact.reference)),
                ValueField("sha256", textValue(artifact.sha256)),
                ValueField("bytes", integerValue(artifact.bytes)),
                ValueField("content_type", textValue(artifact.contentType))
            ]
        )
    ) + "\n"
}

public func hostArtifactPreview(bytes: Array<Byte>, limit: Int64): String {
    if (bytes.size <= limit) {
        return String.fromUtf8(bytes)
    }
    // Reserve enough space for the omission marker and its decimal count.
    let payloadBudget = max(0, limit - 160)
    let head = hostArtifactUtf8Prefix(bytes, payloadBudget / 2)
    let tail = hostArtifactUtf8Suffix(bytes, payloadBudget - head.size)
    let omitted = max(0, bytes.size - head.size - tail.size)
    String.fromUtf8(head) + "\n... [omitted " + omitted.toString() + " bytes] ...\n" + String.fromUtf8(tail)
}

public func hostArtifactUtf8Prefix(bytes: Array<Byte>, limit: Int64): Array<Byte> {
    var end = min(bytes.size, max(limit, 0))
    while (end > 0) {
        let candidate = bytes[..end]
        try {
            let _ = String.fromUtf8(candidate)
            return candidate
        } catch (_: Exception) {
            end--
        }
    }
    []
}

public func hostArtifactUtf8Suffix(bytes: Array<Byte>, limit: Int64): Array<Byte> {
    var start = max(0, bytes.size - max(limit, 0))
    while (start < bytes.size) {
        let candidate = bytes[start..]
        try {
            let _ = String.fromUtf8(candidate)
            return candidate
        } catch (_: Exception) {
            start++
        }
    }
    []
}

public func hostArtifactUtf8Boundary(bytes: Array<Byte>, offset: Int64): Bool {
    if (offset == 0 || offset == bytes.size) {
        return true
    }
    try {
        let _ = String.fromUtf8(bytes[..offset])
        true
    } catch (_: Exception) {
        false
    }
}

public func hostAtomicArtifactWrite(path: String, bytes: Array<Byte>): Result<Unit> {
    var temporary = ""
    try {
        // File.createTemp uses the platform's exclusive temporary-file
        // primitive in the destination directory. It cannot follow a
        // pre-planted predictable symlink, and the open handle is used for
        // the complete write before the atomic rename.
        let file = File.createTemp(Path(path).parent)
        temporary = file.info.path.toString()
        try {
            file.write(bytes)
        } finally {
            file.close()
        }
        let info = FileInfo(Path(temporary))
        if (!info.isRegular() || info.isSymbolicLink()) {
            let _ = removeIfExists(temporary)
            return hostArtifactError<Unit>(
                AgentErrorKind.PermissionDenied,
                "artifact.temporary_unsafe",
                "artifact temporary file is not a safe regular file",
                path
            )
        }
        match (hostArtifactChmod(temporary, "600")) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                let _ = removeIfExists(temporary)
                return Result.Err(error)
        }
        rename(temporary, to: path, overwrite: false)
        Result.Ok(())
    } catch (error: Exception) {
        if (temporary != "") {
            let _ = removeIfExists(temporary)
        }
        hostArtifactError<Unit>(
            AgentErrorKind.Internal,
            "artifact.atomic_write_failed",
            error.message,
            path
        )
    }
}

public func hostArtifactChmod(path: String, mode: String): Result<Unit> {
    let (code, _, error) = executeWithOutput("/usr/bin/chmod", [mode, "--", path])
    if (code == 0) {
        return Result.Ok(())
    }
    hostArtifactError<Unit>(
        AgentErrorKind.PermissionDenied,
        "artifact.permissions_failed",
        String.fromUtf8(error).trimAscii(),
        path
    )
}

public func hostArtifactError<T>(
    kind: AgentErrorKind,
    code: String,
    message: String,
    reference: String
): Result<T> {
    Result.Err(
        AgentError(
            kind,
            code,
            message,
            fields: [ErrorField("artifact", reference)]
        )
    )
}

