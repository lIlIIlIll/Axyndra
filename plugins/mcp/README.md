# MCP client service plugin

This independent native executable connects an operator-authorized stdio MCP
process or HTTP endpoint through generic host broker services. It has no Product, Core,
Store, ToolRuntime or agent SDK dependency. `mcp4cj` owns MCP framing, discovery,
metadata, correlation and outcomes; this package adapts its existing channel
and immutable HTTP exchange interfaces. It uses that library's current `2026-07-28` protocol and
`server/discover` handshake, not a second protocol implementation.

The current standalone protocol inventory contains 51 cases, including stdio,
HTTP/SSE, authentication, bounded capacity and payload transfers. Build and run
the unchanged official gate with a new package directory:

```sh
python3 scripts/prepare_mcp_plugin.py --output /absolute/new/mcp-client-package
```

The helper requires all 51 actual cases without failure or skip, validates the
packaged runtime/license provenance, and runs with loader overrides removed.
Its real localhost peers and native artifact use a fixture host broker.
The fixture brokers stdout and stderr reads concurrently, so a quiet stderr
poll cannot delay ready stdout chunks. All stream byte limits, exact identities,
and the original 15-second invocation deadline still apply. This
does not prove actual Minimal permission, lifecycle, process isolation or
durable Receipt behavior. Earlier full-App results have their own frozen source
and binary scope; current transitive inputs require fresh evidence. See the
[acceptance matrix](../../docs/mcp-plugin-migration.md).

The physical worker reader scans bounded 8 KiB chunks, retaining any prefetched
tail for the next frame. Exact frame maxima, EOF/UTF-8 rules and the existing
deadline remain unchanged. Payload accounting prepays raw decoding and retained
call storage separately; removing scalar read overhead does not enlarge limits.

## Opt-in historical configuration drafts

`python3 plugins/mcp/migrate_legacy.py path/to/mcp.yml` reads the historical
version-1 restricted YAML grammar and prints an inert JSON draft. It never
installs, enables, discovers, launches a process, resolves environment values or
publishes a grant. A missing file produces zero servers. Unknown/repeated fields,
unsupported indentation, mixed transports, duplicate identities/targets/headers,
invalid limits and unsafe HTTP authorities fail without changing the source or
printing a partial draft. The original bytes and SHA-256 remain in the draft;
treat that output as local configuration, not a file to commit.

Every server retains its historical enabled flag as **data only**, exact argv,
cwd, ordinary/secret environment source names, framing values, transport fields,
HTTP URL/query bytes, bearer/header sources, Origin, SSE preference and trusted
remote names. Defaults remain 8 MiB frames, 30-second requests and 3-second
shutdown grace. Nondefault values are preserved, not silently clamped. Trusted
remote names additionally map to the stable local `t_<SHA256>` names requested
by an operator's `read_only_tools`; remote annotations do not grant trust.
Custom header source names retain the original RFC-token grammar and exact legacy
reserved denylist. Their inert credential requests still require operator review;
preserving a draft does not bypass current host header or injection policy.

Case-distinct legacy IDs receive distinct package IDs using the full SHA-256 of
the original ID. Create each explicit local variant from an already built bundle:

```sh
PACKAGE_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["servers"][0]["package_id"])' path/to/draft.json)
python3 plugins/mcp/package.py --clone-source path/to/mcp-client-package \
  --id "$PACKAGE_ID" --output path/to/new-independent-package
```

The clone verifies the exact manifest contract, executable, complete runtime and
license inventories, original compiled-source provenance and independent loader
closure before publishing a new directory. It does not rebuild or merge an
existing package. `--id` also selects the manifest ID when packaging a compiled
binary; omitting it retains `mcp-client` and version `1.0.0`. The worker obtains
its exact ID from its installed immutable manifest beside the actual executable,
not a hello frame, working directory, prefix match or global list of accepted IDs.

Install each reviewed package disabled, obtain its real registry content digest,
and deliberately select the exact process mounts/cwd, resources, lifetime,
network/HTTP egress and TLS trust. Draft endpoint and credential source requests
are not complete operator grants: fill the existing generic lifecycle/HTTP schema
and bind its actual namespace/digest. For stdio, the requested physical stop policy
is `{"schema":"axyndra.process-shutdown/v1","grace_ms":3000}` in the service's
`lifecycle_policy`; normal host stop uses that frozen policy, whereas cancellation
or revocation aborts. The plugin's local reader close does not mint a broker
request outside an invocation window. Explicit startup approval is still required;
static inspect/import/enable do not contact the MCP endpoint.

The draft selects the existing bounded `protocol_limits` and `payload_limits`
profiles so the legacy 30-second default and 8 MiB receive framing are not mapped
back to the small default service profile. Actual host limits still apply: a draft
preserves, but cannot authorize or widen, an out-of-range request. In particular,
request bounds beyond 120 seconds and credential counts above the current generic
host ceiling require a supported operator profile rather than truncation or
plaintext credential expansion. MCP wire versions remain the documented library
matrix; conversion does not introduce a protocol fallback.

Run the public converter/native identity regressions separately from the unchanged
51-case worker gate:

```sh
python3 plugins/mcp/check_migration.py --package path/to/current-package \
  --baseline-package path/to/preserved-before-package --evidence path/to/result.json
```

The native identity checks exercise real packaged executables with loader overrides
removed, including a pre-fix rejection and two independent namespaced clones.
They are not a substitute for fixed-host startup, canonical receipts, external
Server principals or drain evidence.

## Host integration

The only manifest contribution is Service `session`; it requests the generic
`process.channel` and `network.http` capabilities; both are declarations, not grants.
There is no fake Tool. The host pins one plugin worker to one actual service
resource and permission domain. The stdio configuration accepts no executable
or lease selector; an HTTP URL and opaque credential references are only request
data, subject to exact operator grants. Operator
launch grants and canonical lifecycle execution remain the host's authority.

1. `kind=service`, arguments `{"action":"start","configuration":operatorConfiguration}` opens the startup I/O
   window and performs real discovery plus bounded paginated `tools/list`.
   It returns exactly `{"tools":[{"name", "description", "input_schema"}]}`.
   An empty directory is valid. Remote names, including dots, colons and Unicode,
   map to stable `t_<SHA256(remote-name UTF-8)>` local names. The full remote name
   remains in the description and in a private lookup table. Duplicate names or
   collisions reject the entire startup; no tool is silently dropped. TTL and
   cache scope must remain identical across all pages; metadata drift rejects
   the whole startup before any directory is returned.
2. `kind=service_prepare`, arguments `{"action":"call","tool":localName,
   "input":object}` performs **no I/O**. The stable request ID is SHA256 of the
   canonical JSON array of the actual frame's Thread, Run, epoch and call ID.
   It calls `McpClient.prepareToolCall`, retains that exact sealed object, and
   returns `{"intents":[{"id":"mcp-call","bytes_hex":exactFrame}]}` for stdio,
   or `{"intents":[{"id":"mcp-call","request":exactHttpRequest}]}` for HTTP.
   Re-preparing the same identity and same input returns the same bytes.
   Changed input under that identity, a consumed identity or capacity exhaustion
   fails explicitly.
3. `kind=service`, arguments `{"action":"call","tool":localName,
   "input":object,"host_plan":frozenHostPlan}` checks the original prepared
   input and exact intent bytes, then dispatches the same sealed object through
   `dispatchPreparedToolCall`. It never rebuilds metadata or chooses a new RPC
   ID. The host independently checks the full actual endpoint/lease/catalog
   binding and canonical source; plugin fields do not grant authority.

4. `kind=service`, arguments `{"action":"refresh","configuration":operatorConfiguration}`
   opens a distinct host-approved refresh window and repeats bounded `tools/list`
   on the same client/session. It does not rediscover or reopen the backend.
   Configuration must equal the validated startup configuration. It returns the
   same exact directory shape as startup. The adapter replaces its private name
   map only after every page passes validation, and invalidates all earlier
   pending prepared IDs. If subsequent host publication fails, the host closes
   the entire service rather than retaining a mismatched old directory.

The nonsecret configuration has this exact shape:

```json
{"version":1,"transport":"stdio","request_timeout_ms":10000,"directory":{"max_pages":8,"max_tools":64}}
```

Request timeout is positive and no greater than the frozen protocol profile (the
default ceiling is 10000 ms). The default directory allows 1–8 pages and 1–64
tools; an explicit profile allows up to 1024 pages and its frozen tool count. A
server may still return zero tools. Unknown fields, versions, transport names,
credential fields and out-of-range values fail before any MCP I/O in stdio mode.
Optional `framing` has exactly `max_frame_bytes` and `graceful_shutdown_ms`: the
frame is 1024 bytes through the selected logical result ceiling and grace is a
nonnegative Int64, independent of request timeout. These values only narrow
business limits; they never select an executable, environment, host lease,
permission or secret. The HTTP shape below additionally requests a URL and opaque refs, without granting them. Operator configuration changes revoke
the old host grant and require a fresh explicitly approved service startup.

Refresh writes use `process.channel.refresh.write` with only `bytes_hex`. The
host supplies this callback only inside the new canonical Refresh maintenance
Operation and its explicitly configured finite window. It does not reuse the
startup observer. Each physical write during startup uses `process.channel.startup.write` with
`{"bytes_hex":...}`. Later writes use `process.channel.write` with only
`{"intent_id":"mcp-call"}`. The host reads the exact approved bytes from its
frozen plan. Startup responses are `{"written_bytes":n}`; active responses also
require a nonempty actual `receipt_id`. Extra notifications or MCP cancellation
frames are not silently authorized as part of a prepared tools/call.

Both streams use `process.channel.read` with `stream`, `max_bytes=16384`, and
`wait_ms=25`; the successful response is directly `{"bytes_hex":...,"eof":...}`.
A standard broker error fails the channel. Empty bytes with `eof=false` mean an
idle poll, not EOF. Outside startup/refresh/execute, the stream reader waits locally and
emits **no service request**. Before a terminal result, the gate closes and all
already issued polls drain under the same invocation identity. The host should
give a native Service invocation a bounded service-request quota sufficient for
these reads (plugin cap 4096, host profile ceiling 8192).

Physical LF scans and lowercase hexadecimal encoding use bounded pinned arrays
with exact output sizes. Array pins are released on every path; malformed hex
and invalid logical UTF-8 still fail. Large results are serialized once with the
standard JSON value/header/window encoder and a size-known envelope builder.
The same result, frame, message, node, payment, cancellation and deadline guards
apply before physical output. Decoded text equality avoids re-encoding scalar
strings while preserving order-independent object identity and the existing
numeric equality rules. These are implementation changes, not evidence of the
unchanged 51-case gate passing for a newly built package.

The common terminal result is exactly:

```json
{
  "schema": "axyndra.service-call-result/v1",
  "status": "complete",
  "result": {"resultType": "complete", "content": []},
  "error": null,
  "retry_safe": false
}
```

`status=complete` includes MCP business errors (`ok=false`, error code
`mcp_plugin.tool_error`); it still represents a complete server exchange.
`status=input_required` preserves the MCP result and explicitly reports
`mcp_plugin.input_required_unsupported`. The plugin does not automatically
provide input or continue execution. Required-task tools fail in preparation;
unexpected task/extension outcomes fail explicitly. Transport loss, timeout or
any unrecognized post-write terminal is `status=unknown` and closes the session.
The host must use its own actual write/child Receipt evidence to preserve
Unknown, even if a plugin omits or forges this wrapper. `ok=false` alone must not
turn a possible effect into a known failed effect. No automatic retry is offered.

The native protocol has exactly one reader of inherited fd 0. It uses the
existing `process4cj` bounded readiness poll before an at-most-8192-byte read;
it borrows the descriptor without taking close ownership. Idle waits return
from native code at least every 10 milliseconds so concurrent garbage
collection can stop the mutator. EOF and descriptor errors remain terminal;
idle readiness polls do not create EOF. The existing 256 KiB frame limit and
all invocation deadlines remain unchanged. This avoids the SDK ConsoleReader
blocking in native `getc` while other MCP tasks wait for GC completion.

Host cancellation atomically closes the session and interrupts local pending
broker waits without taking a writer lock. It does not emit an additional MCP
`notifications/cancelled` byte frame. Host revocation owns backend termination;
this plugin cannot declare that process cleanup is acknowledged.

## Explicit bounds and current limits

- IPC frames: 256 KiB; pure input: 16 KiB; result: 64 KiB.
- Prepared raw RPC frame including LF: 30 KiB, so its hex plus JSON fits the
  64 KiB preparation result. The library's 8 MiB general framing limit is not
  available through this plugin's IPC contract.
- Directory: 0–64 tools, at most eight pages, total encoded entries at most
  64000 bytes; remote name and full generated description at most 4096 bytes.
- Pending prepared frames: 128 (under 4 MiB raw); consumed identities: 4096,
  no eviction and no reuse. Reopening a new session requires a new actual host
  endpoint/lease/catalog identity and fresh approval.
- MCP request timeout: positive and no larger than the frozen Service profile
  (10 seconds without an explicit profile); broker reply timeout: 5 seconds; terminal
  poll drain: 2 seconds. Host startup, invocation and lifetime bounds may be
  stricter and are not extended by these local limits.

This adapter does not implement MCP Server, literal credential injection,
task polling, MRTR input resolution,
subscriptions or plugin-initiated context updates. The host's conservative
process-startup grant explicitly authorizes the discovery window; a successful
startup is not blanket permission for later writes. Explicit directory refresh is available only through the approved host maintenance
entry. Catalog CAS updates new Run snapshots; the host also applies approved
directory changes to an active Core Run at its legal context cut point. No old
Prepared invocation is redirected to the new directory. The remaining behaviors
must remain visible until implemented through the same canonical host path.

## Build and actual protocol checks

After coordinated candidate integration and actual build:

```sh
plugins/mcp/build-package.sh --output /absolute/new/mcp-package
python3 plugins/mcp/check.py --binary /absolute/new/mcp-package/bin/mcp-client-plugin
```

Packaging copies the actual runtime closure, sets relative rpaths, records file
digests, checks dependencies without `LD_LIBRARY_PATH`, and refuses to overwrite
an existing artifact. Running the checker needs Python and Linux; the plugin
itself does not launch the Python fixture or require Python in its package.


## HTTP broker transport

HTTP uses the same client, discovery, pagination, name map and prepared-ID cache.
Its configuration adds one exact nonsecret object:

```json
{"version":1,"transport":"http","request_timeout_ms":10000,"directory":{"max_pages":8,"max_tools":64},"http":{"url":"https://example.test/mcp?a=1&a=%2f","credential_refs":["operator-header"],"max_response_bytes":65536,"prefer_sse":true}}
```

`http` requires exactly these four fields. Unknown fields, literal bearer tokens,
environment names, proxy settings and duplicate references reject. URL bytes are
visible ASCII, bounded to 16 KiB, with an explicit path and no userinfo or fragment;
the library permits HTTPS or loopback HTTP. Query order, duplicates and escaped
bytes remain unchanged. At most four unique opaque refs are accepted. Response
limit is 1024–1048576 bytes; `prefer_sse` is a Boolean and affects the actual
library-frozen `Accept` header. Configuration changes require a fresh authorized
service, rather than changing a cached executor's connection.

Pure prepare retains `McpPreparedToolCall.httpExchange`: the complete library
URL, method, protocol and projected schema headers, raw UTF-8 JSON body, and
timeouts. It does not reconstruct the request from tool input. The broker DTO is
exactly `{method,url,headers,body_hex,credential_refs,timeout_ms,max_response_bytes}`.
The body is hex of the frozen bytes, not parsed/re-encoded JSON. Raw prepared RPC
is capped at 30 KiB and the complete request DTO at 64000 encoded bytes, under
the 64 KiB pure-result ceiling. Existing 16 KiB pure input and 64 KiB library
response-frame limits still apply. A larger HTTP body limit does not enlarge
native IPC or MCP single-message bounds.

During startup or approved refresh, `network.http.stream.open` takes only
`{request: exactRequest}`. During an active call it takes only
`{intent_id:"mcp-call"}`; the host selects the approved exact request from its
frozen plan. No execute-time URL, header, body or credential target can replace
that request. The return `{exchange_id,status,content_type,body_size}` is response
metadata, not permission, a Receipt or successful completion.

`network.http.stream.read` uses the exact host-returned exchange ID, up to 16384
bytes and a 0–25 ms wait. Empty bytes with `eof:false` remain a local wait.
`network.http.stream.close` must return exact
`{closed:true,receipt_id,body_eof,consumed_bytes}`. An active exchange requires a
nonempty Receipt ID; maintenance requires null because the real HostService root
settles later. The adapter verifies byte accounting after all responses drain.
A completed SSE message may close before body EOF; that fact remains explicit.

Local close interrupts open/read waiters without taking their read lock.
An already issued open retains its callback, and a late handle is closed under
its original invocation. The window cannot publish a result until all issued
responses and close acknowledgements drain; invalid/missing/reused handles,
foreign responses, missing Receipts and unverified cleanup fail closed. No MCP
cancellation request is implicitly authorized. Root cancellation closes the gate
and suppresses late terminal output; the host retains cleanup responsibility.

Limits are 32 exchanges, 4096 broker requests and 1 MiB delivered response bytes
per window, 256 KiB cumulative maintenance request bytes, and 4096 lifetime
exchange-ID tombstones without eviction. Active window deadline is the configured
request timeout; maintenance is at most 60 seconds. Waiting for HTTP headers uses
the frozen request timeout, bounded by the remaining window. Short read replies,
close acknowledgements and final drain have a separate five-second watchdog.
Host limits may be tighter. The plugin never
retries an HTTP exchange automatically, and an error after dispatch remains
Unknown until the host's actual Operation facts decide settlement.

The HTTP protocol fixture injects its test header only in its host-side socket
request, verifies the real origin saw it, and withholds reflected secret output
before plugin IPC. This checks adapter protocol behavior, not production
redaction, gateway isolation, canonical approval or Store Receipt integrity.
Those require separate real Product tests. The current `check.py` inventory is
51 cases; `check_http.py` also supports independent HTTP/auth runs.

The preceding 256-case phase-5 checkpoint passed 36 packaged protocol cases,
actual Product HTTP execution tests, the complete Store contract including 82
HTTP-stream authority scenarios, and all 256 Product unit cases. Exact scope,
source/binary hashes and remaining compatibility work are recorded in
[the migration record](../../docs/plugin-first-migration.md). These results do
not establish old-path removal, Minimal dependency isolation or full capacity
equivalence with the built-in client.


## Explicit bounded service protocol profile

The host operator may attach `protocol_limits` to the exact configured stdio service in `plugins/lifecycle.json` (or to the exact HTTP plugin grant in `plugins/services.json`). The host freezes it into startup approval and every later canonical binding; manifest declarations and plugin messages cannot raise it. Omitting the profile preserves the previous limits. The native Tool `prepare` path remains 16 KiB input, 64 KiB output and five seconds even when the same native worker has a larger Service profile.

```json
{"max_frame_bytes":4194304,"max_input_bytes":1048576,"max_prepare_bytes":2097152,"max_result_bytes":4128768,"max_directory_bytes":2097152,"max_tools":8192,"call_timeout_ms":120000}
```

All seven fields are required; unknown fields are rejected. Input plus preparation and 256 KiB of binding/identity reserve must fit the physical frame. The declared maxima are ceilings: exact MCP framing, hexadecimal expansion, actual lease cumulative I/O quotas, Run budget, five-second pure-preparation limit and the catalog's **8192 retained registrations across owners/revisions** still apply. Each individual owned tool definition remains bounded to 64 KiB. Business configuration must explicitly select larger directory bounds (`max_pages` at most 1024, `max_tools` no larger than the profile) and `request_timeout_ms` no larger than the selected call bound. This does not change endpoint lifetime or authorize more effects.

The current inline profile is a bounded intermediate step, not full legacy capacity equivalence. The MCP client keeps at most 128 undelivered calls and 8 MiB of their actual retained input/RPC/intent bytes, plus 4096 never-evicted dispatch-ID tombstones. Store checks the complete encoded plan against its existing 8 MiB decoder bound before admission/handoff. Returned results are measured with the actual durable codec; post-effect overflow becomes Unknown with a small receipt and no automatic retry.

HTTP still retains the separately approved generic 64 KiB request-body and 1 MiB response limits; this profile does not silently widen that transport. Payloads beyond the 4 MiB native frame, large inline input plus prepared bytes, and legacy timeouts beyond 120 seconds remain migration gaps requiring a separate immutable payload/transport design. Actual Product tests passed complete 96 KiB input/output, a 72-tool nine-page directory and an 11-second call under a 15-second configuration. These do not establish those larger limits. Large channel writes preserve one canonical child and once-only total byte accounting while writing chunks of at most 64 KiB; every chunk revalidates cancellation, scope, Store authorization and the active lease.

The 44-case package revision and the complete 291-case Product compatibility
graph are validated separately in the migration record. SDK/StdX and Cangjie
dependency caches were reused. The latest actual App ingress suite belongs to
the earlier 256-case checkpoint; no current App rebuild or full legacy capacity
equivalence is claimed here. Future payload/transport candidates are excluded.


## Explicit immutable HTTP payload profile

An HTTP service may additionally receive an operator-selected `payload_limits`
alongside `protocol_limits`. Both profiles are frozen into the completed startup
grant and each later canonical binding. The earlier 64 KiB request / 1 MiB
response defaults still apply when this profile is absent.

```json
{"version":1,"max_message_bytes":16777216,"max_input_bytes":4194304,"max_prepare_bytes":8388608,"max_result_bytes":8388608,"max_write_bytes":4128768}
```

With this profile, logical input/prepared/result messages use bounded physical
chunks. Pure prepare still freezes the library's exact HTTP body. Before the
parent Operation is prepared, the host stores every nonempty body in its existing
immutable content store and replaces `body_hex` with `body_payload` in
`http-stream-intents/v2`. The reference contains full raw/encoded digests and byte
length; a plugin cannot choose an artifact. Store requires a unique preparation
witness bound to the real Thread/Run/epoch/call/input/installed-service binding in
the same transaction as each Operation transition. Execution reloads and hashes
the complete content, rechecks the actual handoff, and writes it in 64 KiB chunks
through that exchange's one process and cancellation owner.

The logical input is at most 4 MiB, prepared/result values at most 8 MiB, and total
request body bytes at most 4 MiB minus 64 KiB in the illustrated profile. Hex
encoding, metadata and the actual durable codec impose their own finite bounds.
Every HTTP response window is bounded by the configured result ceiling. JSON/SSE
bytes and cumulative DOM tokens are charged before decoding to the actual
worker's existing reservation; SSE metadata is excluded, Content-Type matching
is case-insensitive, and the charge remains until terminal publication. There is
no automatic replay following an ambiguous effect or corrupt stored content.

Six Product/SQLite cases cover 3 MiB exact input/output, 1 MiB SSE, explicit
committed approval, corrupt content, dense mixed-case SSE and absent-profile
denial. Thirty HTTP Store cases cover source, transition and cancellation; six
native worker cases cover payload budgets. Execution evidence belongs to each
gate's exact source/binary report, not to this inventory. Do not infer unrun
Product cases or complete legacy equivalence from a native worker result.
Timeouts outside the supported host ceiling and complete lifecycle/principal
matrices remain explicit requirements in the migration record.
