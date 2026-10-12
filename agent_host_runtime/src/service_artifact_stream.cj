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


// Synchronous callbacks already consume the existing native service quota.
// One active writer and at most 16 MiB total content per invocation. Completed
// names remain tombstones until this exact owner closes; no retries or handles
// can transfer the file to another generation, operation, Run or thread.
class HostServiceArtifactSession {
    private let lease: HostPluginLifecycleLease
    private let context: ToolInvocationContext
    private let prepared: PreparedToolInvocation
    private let bindingText: String
    private let lock = Mutex()
    private let names = HashSet<String>()
    private var active: ?HostServiceArtifactWriter = None
    private var selectedName = ""
    private var selectedDigest = ""
    private var selectedBytes: Int64 = 0
    private var offset: Int64 = 0
    private var total: Int64 = 0
    private var closed = false
    init(lease: HostPluginLifecycleLease, context: ToolInvocationContext,
        prepared: PreparedToolInvocation, binding: AgentValue) {
        this.lease = lease; this.context = context; this.prepared = prepared
        bindingText = stringifyUnifiedJson(binding)
    }
    func close(): Result<Unit> {
        lock.lock()
        try {
            closed = true
            match (active) { case Some(value) =>
                match (value.close()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => active = None }
                case None => () }
            Result.Ok(())
        } finally { lock.unlock() }
    }
    func terminalReady(): Bool {
        lock.lock(); try { !closed && active.isNone() } finally { lock.unlock() }
    }
    private func fail<T>(): Result<T> {
        closed = true
        // Keep a failed cleanup owner for close() to retry. A logical error
        // never releases the reservation while its native file is still open.
        match (active) { case Some(value) => if (value.close().isOk()) { active = None }; case None => () }
        hostLifecycleLeaseError("artifact.stream_protocol_invalid")
    }
    func handle(args: AgentValue): Result<AgentValue> {
        let diagnosticStarted = hostChannelIoDiagnosticStart()
        try {

        lock.lock()
        try {
            if (closed || hostManagedChannelCallerCancelled(context)) { return fail() }
            let binding = parseUnifiedJson(bindingText, maxBytes: 196608)
            match (lease.verifyInvocationRoot(context, prepared, binding)) {
                case Result.Err(error) => let _ = fail<Unit>(); return Result.Err(error); case Result.Ok(_) => () }
            let action = hostLifecycleText(args, "action")
            let name = hostLifecycleText(args, "stream")
            if (!hostServiceArtifactName(name)) { return fail() }
            if (action == "begin") {
                if (!httpIntentExactFields(args, ["action", "stream", "bytes", "sha256"]) || active.isSome() ||
                    names.size >= 8 || names.contains(name)) { return fail() }
                let count = hostServiceArtifactInteger(args, "bytes")
                let sha = hostLifecycleText(args, "sha256")
                if (count < 0 || count > lease.artifactObservationMaximum() - total || !hostServiceArtifactDigest(sha)) { return fail() }
                let writer = match (lease.openArtifactWriter(context, prepared, binding)) {
                    case Result.Err(error) => let _ = fail<Unit>(); return Result.Err(error); case Result.Ok(value) => value }
                // The cleanup owner must be installed before the first file
                // can be created; failed begin poisons this entire session.
                names.add(name); total += count; active = Some(writer)
                match (writer.open()) {
                    case Result.Err(error) => let _ = fail<Unit>(); return Result.Err(error)
                    case Result.Ok(_) => () }
                selectedName = name; selectedBytes = count; selectedDigest = sha; offset = 0
                return Result.Ok(objectValue([ValueField("accepted_bytes", integerValue(count))]))
            }
            if (active.isNone() || name != selectedName) { return fail() }
            let writer = active.getOrThrow()
            if (action == "append") {
                let content = hostServiceArtifactAppendText(args)
                let position = hostServiceArtifactInteger(args, "offset")
                if (position != offset) { return fail() }
                match (writer.append(offset, content, selectedBytes)) {
                    case Result.Err(error) => let _ = fail<Unit>(); return Result.Err(error); case Result.Ok(_) => () }
                offset += content.size
                return Result.Ok(objectValue([ValueField("next_offset", integerValue(offset))]))
            }
            if (action != "finish" || !httpIntentExactFields(args, ["action", "stream"]) || offset != selectedBytes) { return fail() }
            match (writer.finish(selectedBytes, selectedDigest)) {
                case Result.Err(error) => let _ = fail<Unit>(); return Result.Err(error); case Result.Ok(_) => () }
            let result = lease.retainArtifact(context, prepared, binding, name, writer)
            match (writer.close()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => active = None }
            if (result.isError()) { closed = true }
            match (lease.verifyInvocationRoot(context, prepared, binding)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            result
        } catch (_: Exception) { fail() }
        finally { lock.unlock() }
    
        } finally { hostChannelIoDiagnosticRecord(7, diagnosticStarted) }
    }
}

func hostServiceArtifactInteger(value: AgentValue, name: String): Int64 {
    match (value.field(name)) {
        case Some(found) => if (found.unifiedKind == ValueKind.Number) {
            try {
                let result = Int64.parse(found.asNumberText())
                if (result.toString() == found.asNumberText()) { return result }
            } catch (_: Exception) {}
        }
        case None => ()
    }
    -1
}
func hostServiceArtifactName(value: String): Bool {
    if (value == "" || value.size > 32) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'0' && byte <= b'9') || byte == b'_')) { return false }
    }
    true
}
func hostServiceArtifactDigest(value: String): Bool {
    if (value.size != 64) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= b'a' && byte <= b'f') || (byte >= b'0' && byte <= b'9'))) { return false }
    }
    true
}
