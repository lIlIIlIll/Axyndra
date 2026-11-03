package agent_host_runtime

import agent_domain.*
import agent_store.*
import agent_extension_runtime.*
import tool_runtime.*
import std.convert.*
import std.fs.*

foreign func axyndra_read_view_probe(path: CString, output: CPointer<UInt8>, capacity: Int64): Int32

// Native identity/copy primitives require absolute physical names. Prefix
// only the actual CWD; never canonicalize authored components or erase a
// symlink before the original no-follow check. Descriptive paths stay intact.
func hostPhysicalReadResourcePath180(path: String): String {
    if (Path(path).isAbsolute()) { return path }
    canonicalize(Path(".")).join(path).toString()
}

public func hostReadResourceWitness(path: String): Result<String> {
    unsafe {
        let name = LibC.mallocCString(hostPhysicalReadResourcePath180(path)); let buffer = LibC.malloc<UInt8>(count: 256)
        try {
            let code = axyndra_read_view_probe(name, buffer, 256)
            if (code != 0) { return hostPluginResourceError("read_view.resource_invalid", "read resource must have a stable link-free regular identity") }
            Result.Ok(CString(buffer).toString())
        } finally { LibC.free(buffer); LibC.free(name) }
    }
}

public func hostArtifactHex(bytes: Array<Byte>): String {
    let digits = "0123456789abcdef".toArray()
    let encoded = Array<Byte>(bytes.size * 2, repeat: 0)
    for (index in 0..bytes.size) {
        encoded[index * 2] = digits[Int64(bytes[index]) / 16]
        encoded[index * 2 + 1] = digits[Int64(bytes[index]) % 16]
    }
    String.fromUtf8(encoded)
}

public func hostOperationStore(database: SqliteDatabase,
    derivedSettlementFailureObserver!: ?(String, String, String, String) -> Unit = None): DurableOperationStore {
    DurableOperationStore(database,
        documentPayloadAllocation: Some({ bytes => reserveNativeDocumentPayload(bytes) }),
        derivedSettlementFailureObserver: derivedSettlementFailureObserver)
}

public func hostPluginResourceError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.PermissionDenied, code, message))
}

public func hostResourceFailure(code: String): AgentError {
    AgentError(AgentErrorKind.Conflict, code, "service lifecycle authority or retained resource state rejected the request",
        retryable: false, fallbackAllowed: false)
}
public func hostResourceError<T>(code: String): Result<T> { Result.Err(hostResourceFailure(code)) }


public func hostResourceCancelled<T>(): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Cancelled, "plugin.lifecycle_io_cancelled",
        "current service I/O was cancelled; possibly transferred bytes must not be replayed",
        retryable: false, fallbackAllowed: false))
}
