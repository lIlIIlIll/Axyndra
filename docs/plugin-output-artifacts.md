# Managed service output artifacts

An active process-channel Service may send `output.artifact` requests during its
actual canonical Tool invocation. The host accepts content only. This API cannot
read paths or blobs, launch work, create an Operation, approve an effect, or make
an uncertain operation completed. Startup, refresh and pure preparation do not
expose it.

The native v2 outer identity and per-invocation request quota apply to every
request. Each request rechecks the same installed generation, active lease,
Thread, Run, epoch, Executing Operation, exact normalized plan and durable handoff.
The host permits one active stream, eight distinct stream names, and at most
16 MiB of content for the invocation, further bounded by the lease's output
ceiling. Names contain 1–32 lowercase letters, digits or underscores.

1. Begin with `{"action":"begin","stream":"stdout","bytes":N,"sha256":"..."}`.
   The host replies with `{"accepted_bytes":N}`. A name cannot be reused.
2. Append with `{"action":"append","stream":"stdout","offset":0,"text":"..."}`.
   Offsets count UTF-8 bytes. Text chunks contain 1–16,384 bytes and must also fit
   the existing 65,536-byte service argument envelope after JSON escaping.
   Alternatively replace `text` with `data_base64` containing canonical RFC 4648
   Base64 of the same strict UTF-8 bytes. The forms are mutually exclusive; no
   path or artifact reference is accepted. The decoded 1–16,384-byte bound,
   original argument envelope, invocation quota and byte offsets are unchanged.
   This avoids repeated JSON control-character escaping for content such as NUL.
   The host replies with the next byte offset.
3. Finish with `{"action":"finish","stream":"stdout"}`. Length and SHA-256
   must match. The response contains an immutable `artifact` descriptor, at most
   8 KiB of UTF-8 `preview`, and a `truncated` flag. The plugin owns the final
   business result's presentation.

The host writes an exclusively created internal temporary file incrementally;
it never accepts a plugin-supplied filename or artifact reference. A fixed 64 KiB
workspace is reserved from the native IPC allocation pool. Final publication
uses the existing content-addressed artifact store. The canonical Store then
rechecks the full invocation source, exact metadata and streamed file hash in
the same transaction that creates `service_artifact_observed` in `audit_events`.
GC's final reference check uses that same transaction boundary. An artifact
remains an untrusted observation, including when the parent later becomes
Unknown. It is not a receipt, a retry permission or a second task ledger.

An incomplete or rejected transfer cannot accompany a successful terminal
result. Close cancels further requests and retries actual file cleanup before
releasing its allocation. Unpublished partial temporary files are removed on
normal cancellation/close. Crash cleanup of temporary files still needs the
full recovery matrix; this document does not claim that validation has run.

The current candidate has not been compiled. It authors real storage boundary
tests and an installed Shell scenario that checks a 3 MiB artifact and its
canonical GC reference. Service/native/Store negative and crash matrices remain
required before considering this capability fully verified.
