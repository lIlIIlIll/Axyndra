package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*
import stdx.crypto.digest.*
import yjson.*
import yjson_support.*

// Content only, with bounded disk and fixed memory. This object never mints an
// execution source, accepts a plugin path, or opens an existing blob for input.
public class HostServiceArtifactWriter {
    private let root: String
    private var file: ?File = None
    private var verificationFile: ?HostVerifiedArtifactInput = None
    private let reservation: LogicalJsonFixedBufferReservation
    private let digest = SHA256()
    private let prefix = ArrayList<Byte>()
    private var temporary = ""
    private var pathKnown = false
    private var fileOpen = false
    private var openAttempted = false
    private var bytes: Int64 = 0
    private var artifact: ?HostArtifact = None
    private var released = false
    private var journalStreamVerification = false

    public init(root: String, reservation: LogicalJsonFixedBufferReservation) {
        this.root = root; this.reservation = reservation
    }
    // The session retains this writer before open(). Even metadata failures
    // leave the handle reachable for a later close/cleanup acknowledgement.
    public func open(): Result<Unit> {
        if (released || openAttempted) { return hostResourceError("artifact.stream_open_failed") }
        openAttempted = true
        try {
            let selected = File.createTemp(Path(root))
            file = Some(selected); fileOpen = true
            temporary = selected.info.path.toString(); pathKnown = true
            Result.Ok(())
        } catch (_: Exception) { hostResourceError("artifact.stream_open_failed") }
    }
    public func append(offset: Int64, content: String, maximum: Int64): Result<Unit> {
        if (!fileOpen || artifact.isSome() || offset != bytes || content.size < 1 || content.size > 16384 ||
            maximum < 1 || maximum > 16777216 || content.size > maximum - bytes) {
            return hostResourceError("artifact.stream_offset_or_bound") }
        appendBytes(offset, content.toArray(), maximum)
    }
    // Host-internal document copies may split a UTF8 codepoint between chunks.
    // The original worker-facing append still accepts only decoded String data.
    public func appendBytes(offset: Int64, raw: Array<Byte>, maximum: Int64): Result<Unit> {
        if (!fileOpen || artifact.isSome() || offset != bytes || raw.size < 1 || raw.size > 16384 ||
            maximum < 1 || maximum > 16777216 || raw.size > maximum - bytes) {
            return hostResourceError("artifact.stream_offset_or_bound")
        }
        try {
            file.getOrThrow().write(raw)
            digest.write(raw)
            let take = min(raw.size, 8192 - prefix.size)
            if (take > 0) { prefix.add(all: raw[..take]) }
            bytes += raw.size
            Result.Ok(())
        } catch (_: Exception) { hostResourceError("artifact.stream_write_failed") }
    }
    // Package-local, content-only use by the actual typed stream reader.
    // The complete bound comes from its one-shot Store proof, not a worker.
    // Old append/appendBytes remain their exact 16KiB/16MiB implementations.
    func appendJournalStreamBytes(offset:Int64,raw:Array<Byte>,maximum:Int64):Result<Unit>{
        if(!fileOpen || artifact.isSome() || offset!=bytes || raw.size<1 || raw.size>65536 ||
            maximum<1 || bytes>maximum || raw.size>maximum-bytes){
            return hostResourceError("artifact.journal_stream_offset_or_bound")}
        try{
            file.getOrThrow().write(raw);digest.write(raw)
            journalStreamVerification = true
            let take=min(raw.size,8192-prefix.size)
            if(take>0){prefix.add(all:raw[..take])}
            bytes+=raw.size;Result<Unit>.Ok(())
        }catch(_:Exception){hostResourceError("artifact.journal_stream_write_failed")}
    }

    public func finish(expectedBytes: Int64, expectedDigest: String): Result<Unit> {
        if (!fileOpen || artifact.isSome() || bytes != expectedBytes) { return hostResourceError("artifact.stream_incomplete") }
        try {
            let actualDigest = hostArtifactHex(digest.finish())
            if (actualDigest != expectedDigest) { return hostResourceError("artifact.stream_digest_mismatch") }
            file.getOrThrow().close(); fileOpen = false
            artifact = Some(HostArtifact(HOST_ARTIFACT_PREFIX + actualDigest, actualDigest, bytes))
            Result.Ok(())
        } catch (_: Exception) { hostResourceError("artifact.stream_finish_failed") }
    }
    public func completedArtifact(): HostArtifact { artifact.getOrThrow() }
    public func preview(): String {
        String.fromUtf8(hostArtifactUtf8Prefix(prefix.toArray(), prefix.size))
    }
    // Only the actual input-retention adapter calls this with its fixed hash
    // path. A retry verifies every published byte and keeps pending FD debt.
    func publishLivePolicyInput(path:String,guard:()->Result<Unit>):Result<Unit>{
        if(fileOpen || artifact.isNone()){return hostResourceError("artifact.stream_not_complete")}
        if(temporary==""){return verifyPublished(path,guard:guard)}
        publish(path,guard:guard)
    }

    public func publish(path: String, guard!: () -> Result<Unit> = {=>Result<Unit>.Ok(())}): Result<Unit> {
        if (fileOpen || artifact.isNone() || temporary == "") { return hostResourceError("artifact.stream_not_complete") }
        try {
            let info = FileInfo(Path(temporary))
            if (!info.isRegular() || info.isSymbolicLink() || info.size != bytes) {
                return hostResourceError("artifact.stream_file_changed")
            }
            match (hostArtifactChmod(temporary, "600")) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            if (!exists(Path(path))) {
                try { rename(temporary, to: path, overwrite: false); temporary = "" }
                catch (_: Exception) { if (!exists(Path(path))) { return hostResourceError("artifact.stream_publish_failed") } }
            }
            match (verifyPublished(path,guard:guard)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            if (temporary != "") { let _ = removeIfExists(temporary); temporary = "" }
            Result.Ok(())
        } catch (_: Exception) { hostResourceError("artifact.stream_publish_failed") }
    }
    private func openVerification(path:String,expected:HostArtifact,guard:()->Result<Unit>,journalStream!:Bool=false):Result<HostVerifiedArtifactInput>{
        let witness=match(hostReadResourceWitness(path)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let opened=HostVerifiedArtifactInput(witness,expected.bytes)
        verificationFile=Some(opened)
        // Retain the owner before open. This checkpoint also lets the caller
        // reject deadline drift between identity freezing and actual fd open.
        match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let opening=if(journalStream){opened.openJournalStream(path)}else{opened.open(path)}
        match(opening){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result.Ok(opened)
    }
    private func closeVerification():Result<Unit>{
        match(verificationFile){case Some(value)=>match(value.close()){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>verificationFile=None};case None=>()}
        Result.Ok(())
    }
    public func verifyPublished(path: String, guard!: () -> Result<Unit> = {=>Result<Unit>.Ok(())}): Result<Unit> {
        if (released || verificationFile.isSome()) { return hostResourceError("artifact.stream_cleanup_pending") }
        try {
            let expected = completedArtifact()
            match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let opened=match(openVerification(path,expected,guard,journalStream:journalStreamVerification)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            try {
                let hasher = SHA256(); let buffer = Array<Byte>(8192, repeat: 0)
                var count: Int64 = 0
                while (true) {
                    match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    let read=match(opened.read(buffer)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                    if (read == 0) { break }
                    if (read > expected.bytes - count) { return hostResourceError("artifact.stream_file_changed") }
                    hasher.write(buffer[..read]); count += read
                }
                if (count != expected.bytes || hostArtifactHex(hasher.finish()) != expected.sha256) {
                    return hostResourceError("artifact.stream_file_changed")
                }
                match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                match(closeVerification()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                Result.Ok(())
            } finally {
                // A failed close remains attached to this same invocation
                // owner; it cannot be replaced by another verifier or leak
                // when the caller receives a failed integrity check.
                let _=closeVerification()
            }
        } catch (_: Exception) { hostResourceError("artifact.stream_file_changed") }
    }
    // Only the Host document-preparation adapter uses this method, before a
    // parent Operation exists. Failed verifier close remains on this writer.
    public func verifyCanonicalDocument(path: String, guard: () -> Result<Unit>, receiptValue!: Bool = false): Result<Unit> {
        if(released || verificationFile.isSome()) { return hostResourceError("artifact.stream_cleanup_pending") }
        let expected=completedArtifact()
        if(expected.bytes<1 || expected.bytes>PLUGIN_DOCUMENT_MAX_BYTES) { return hostResourceError("plugin.document_next_invalid") }
        let charge=try { reserveNativeDocumentPayload(expected.bytes) }
            catch(_: Exception) { return hostResourceError("plugin.document_payload_capacity") }
        try {
            match(guard()) {case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let opened=match(openVerification(path,expected,guard)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            try {
                let bytes=ArrayList<Byte>();let buffer=Array<Byte>(16384,repeat:0)
                while(true) {
                    match(guard()) {case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    let count=match(opened.read(buffer)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                    if(count==0){break}
                    if(count>expected.bytes-bytes.size){return hostResourceError("artifact.stream_file_changed")}
                    bytes.add(all:buffer[..count])
                }
                if(bytes.size!=expected.bytes){return hostResourceError("artifact.stream_file_changed")}
                let raw=String.fromUtf8(bytes.toArray())
                if(modelPolicySha256Text(raw)!=expected.sha256){return hostResourceError("artifact.stream_file_changed")}
                charge.ensureDecoded(raw.size,logicalJsonNodeCount(raw))
                let decoded=match(decodeAgentValue(raw,maxBytes:PLUGIN_DOCUMENT_MAX_BYTES)) {
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                if(encodeAgentValue(decoded)!=raw){return hostResourceError("plugin.document_next_noncanonical")}
                if(receiptValue && encodeStoredValue(decoded).size>8388608){return hostResourceError("plugin.document_result_codec_limit")}
                match(guard()) {case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                match(closeVerification()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                Result.Ok(())
            } finally {let _=closeVerification()}
        } catch(_: Exception) {hostResourceError("plugin.document_payload_verification_failed")}
        finally {charge.close()}
    }
    // This callback sees only this already-finished writer's private file.
    // No path or metadata reference supplied by an untrusted worker is opened.
    // The original writer retains failed verifier closes for cleanup retries.
    // Opt-in Unit inspection of this exact finished private writer. The
    // default Context result method remains byte-for-byte unchanged. No Node,
    // file/path or grant may escape this actual verification/close-ACK scope.
    func withPrivateLivePolicyMetadataInput(guard:()->Result<Unit>,
        consume:(HostVerifiedArtifactInput,HostArtifact)->Result<Unit>):Result<Unit>{
        if(released || verificationFile.isSome() || temporary=="" || artifact.isNone()){
            return hostPluginResourceError("plugin.live_metadata_closed","private live metadata writer is unavailable")}
        let expected=completedArtifact()
        match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let opened=match(openVerification(temporary,expected,guard)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let value=try{consume(opened,expected)}catch(_:Exception){
            hostPluginResourceError<Unit>("plugin.live_metadata_invalid","private live metadata could not be verified")}
        match(closeVerification()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        value
    }

    public func withPrivateContextResultInput(guard:()->Result<Unit>,
        consume:(HostVerifiedArtifactInput,HostArtifact)->Result<AgentValue>):Result<AgentValue>{
        if(released || verificationFile.isSome() || temporary=="" || artifact.isNone()){
            return hostPluginResourceError("context.document_result_closed","private context result writer is unavailable")}
        let expected=completedArtifact()
        match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let opened=match(openVerification(temporary,expected,guard)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let value=try{consume(opened,expected)}catch(_:Exception){
            hostPluginResourceError<AgentValue>("context.document_result_invalid","private context result could not be verified")}
        match(closeVerification()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(guard()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        value
    }

    public func close(): Result<Unit> {
        if (released) { return Result.Ok(()) }
        try {
            match(closeVerification()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match (file) { case Some(value) =>
                if (!pathKnown) { temporary = value.info.path.toString(); pathKnown = true }
                if (fileOpen) { value.close(); fileOpen = false }
                case None => () }
            if (temporary != "") {
                let _ = removeIfExists(temporary)
                if (exists(Path(temporary))) { return hostResourceError("artifact.stream_cleanup_pending") }
                temporary = ""
            }
            reservation.close(); released = true
            Result.Ok(())
        } catch (_: Exception) { hostResourceError("artifact.stream_cleanup_pending") }
    }
}

