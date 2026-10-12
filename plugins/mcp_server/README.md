# Independent MCP Server decoder

This package interprets the repository's MCP protocol inside an installed native
component. The Product hosts a generic bounded stdio receiver; it does not parse
MCP methods. The package has **no capabilities** and exposes only the powerless
`decoder` Service. Every parse/encode window uses `service_prepare` and has no
broker observer, Tool executor, progress callback, or workspace/network access.

The decoder reuses `mcp4cj.McpServer` for `server/discover`, `tools/list`,
`tools/call`, protocol metadata, schema validation and result encoding. It does
not introduce a second MCP implementation. Unsupported task and input-required
continuation methods return protocol errors. This first component has a fixed
export directory and executes one Tool call at a time on one actual Thread.
The old embedded MCP Server source has been removed. Remaining transport,
concurrency, authentication and compatibility acceptance still needs the real
shared Host owners and both independent packages in one fixed Minimal binary.

Build on Linux x86_64 with the pinned SDK/StdX and `patchelf`:

```sh
plugins/mcp_server/build-package.sh --output /absolute/new/mcp-server-package
python3 plugins/mcp_server/check.py --package /absolute/new/mcp-server-package
```

The packager bundles the runtime closure and licenses, rejects an existing output
directory, and verifies that runtime lookup needs only package/system libraries.
The checker requires all 20 actual child-process cases without skips, including
typed request IDs, Unicode, library schema checks, explicit host approval failure,
immutable exports, invalid blob offsets and rejected execution/identity profiles.
The payload cases exercise explicit resource profiles, complete 1 MiB results,
bounded logical transfers, corrupt/incomplete blobs, dense JSON and cancellation.
A successful package check alone does not prove host authorization or persistence.

After import and enable, a local operator supplies the exact installed digest in
`$AXYNDRA_HOME/plugins/ingress.json`:

```json
{"schema":"axyndra.stdio-ingress-grants/v1","grants":[{"id":"local-peer","namespace":"axyndra:mcp-server","package_digest":"sha256:<64 lowercase hex>","service":"decoder","principal":"local-operator-peer","thread_id":"local-mcp-thread","exports":["read"],"capabilities":["workspace.read"],"lifetime_ms":120000}]}
```

Then a parent process opens pipes to `axyndra plugin serve local-peer`. The grant
ID is the only CLI input; a peer cannot choose its principal, capability ceiling,
Thread, package, configuration, instance or exports. The decoder's actual pinned
endpoint identity, both original-frame and proposed-call digests, typed request
ID and actual Runtime source are persisted with each canonical External call.
Host policy still decides approval: this noninteractive frontend never grants an
approval requested by an exported Tool. An operator-selected trusted policy
remains the same explicit host policy used by other direct entry points.

Default limits and compatibility boundaries (unchanged without both profiles):

- LF-delimited UTF-8 input: 64 KiB per frame; catalogue/result blobs: 64 KiB each.
  Upload uses <=4 KiB chunks under each 16 KiB powerless prepare request.
- Outbound MCP response: 24 KiB before framing; oversized responses become an
  explicit protocol error. Native IPC remains bounded by 64 KiB result / 256 KiB
  frame. This is a narrower envelope than the old standalone Server transport.
- One fixed Thread, at most 16 queued calls, 4,096 received frames/request keys
  and 16 MiB retained input per connection. Request keys are never evicted for
  replay. A consumed raw-frame seal cannot admit another call.
- A cancellation frame is parsed independently from an executing Tool; queued
  cancellation creates no Run/effect. EOF closes the connection and cancels
  outstanding work. It is not a request to drain queued effects to completion.
- Stdout must be a pipe or socket. The generic owner borrows fd1, temporarily
  enables nonblocking writes, and restores its original flags after real cleanup.
  It never closes fd1. A full output pipe has a five-second write deadline; EOF
  cancellation can interrupt polling. Regular-file/terminal stdout is rejected.
- Decoder upload work has a ten-second inter-chunk bound; each real parser Run
  separately has a five-second maximum. A currently dispatched final chunk may
  use its remaining window. Shutdown retains ownership until all tasks and the
  fixed worker acknowledge cleanup; a timeout is not success.
- Host ancestry is an actual local composition binding, not peer metadata. The
  local stdio root starts a fresh ancestry and rejects own/ancestor namespace
  exports. It does not authenticate ancestry across unrelated OS processes.
- Configuration, package, instance, export identity and expiry are revalidated.
  The worker cannot silently restart under its old identity. Repeated digest
  scanning and polling cost have not been measured or optimized.

The earlier integrated checkpoint passed 12 independently packaged decoder
cases and nine actual ingress scenarios on a physically MCP-free full App,
including canonical External records, approval before effects, active/queued
cancellation and output cleanup. It predates the current 20-case inventory and
shared Host/Minimal graph. Preserve its artifact hashes and failed attempts;
run fresh package and current-host acceptance instead of treating that old
checkpoint as Minimal proof. See the [acceptance matrix](../../docs/mcp-plugin-migration.md).


Optional larger result decoding uses the same generic Native Service logical
payload protocol as the Client. The operator must set **both** `protocol_limits`
and `payload_limits` on the exact ingress grant; neither is selected by an MCP
request or plugin configuration. The host binds them into the pinned endpoint's
handshake. Unknown fields, incomplete pairs and invalid bounds reject startup.
For example, add the following two fields to the grant above:

```json
{
  "protocol_limits": {
    "max_frame_bytes": 4194304,
    "max_input_bytes": 1048576,
    "max_prepare_bytes": 2097152,
    "max_result_bytes": 4128768,
    "max_directory_bytes": 2097152,
    "max_tools": 8192,
    "call_timeout_ms": 120000
  },
  "payload_limits": {
    "version": 1,
    "max_message_bytes": 16777216,
    "max_input_bytes": 4194304,
    "max_prepare_bytes": 8388608,
    "max_result_bytes": 8388608,
    "max_write_bytes": 4128768
  }
}
```

The decoder continues to accept only powerless `service_prepare` invocations.
Every parser invocation still has a five-second ceiling. The complete uploaded
Tool result may be at most `payload_limits.max_input_bytes`; upload chunks are
at most `min(131072, (max_input_bytes - 1024) / 2)` bytes within one fixed
30-second aggregate upload deadline. At least 16 KiB input and 64 KiB prepare
capacity are required. Incoming peer JSON-RPC frames and the immutable export
catalogue remain at 64 KiB, with at most 256 exports.

The outbound MCP response may be at most `(max_prepare_bytes - 4096) / 2`
bytes because the powerless directive hex-encodes it. Physical native frames
remain bounded by the granted frame limit; larger directives use authenticated,
ordered 16 KiB logical-transfer chunks, not extra executions. Identity, fixed
window, sequence, declared size and SHA-256 must match. Cancellation, incomplete
or foreign transfers cannot continue in a later invocation.

Both raw and parsed profile frames, active serialization and retained result
blobs share a 128 MiB endpoint accounting pool. Token counts are checked before
expanded parsing. The 512-byte-per-lexical-token factor is conservative resource
accounting, not a measured RSS bound. Blob replacement and final process cleanup
release the retained charges. The supplied profile is intended to preserve a
full 1 MiB Tool result including both MCP text and structured content. A response
outside its explicit bound still becomes a bounded protocol error; the host's
canonical ToolResult and Receipt remain authoritative.

The six new packaged cases and the separate host capacity App cases are authored
but not yet executed in this candidate. They do not establish complete parity
with the old Server's maximum transport envelope. Larger raw peer requests,
dynamic exports, concurrency and remaining compatibility work stay separate.
