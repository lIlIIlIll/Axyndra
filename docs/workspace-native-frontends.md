# Native Workspace tools and explicit resource roots

Workspace read, grep, glob, hashline edit and write algorithms live in the
independent native Workspace package. Product no longer registers compiled
Workspace executors or starts the two compiled Workspace SDK providers.
Historical implementations are confined to `support_tests` contract oracles.

Coding and Full explicitly select their bundled Workspace package. Minimal has
no optional package or Workspace selection. An operator can select an actually
installed and enabled package in `settings/plugins/workspace-tools.json`:

```json
{"schema":"axyndra.workspace-tools/v1","namespace":"axyndra:workspace","package_digest":"sha256:<actual-package-tree-digest>"}
```

This file selects data, not capabilities, credentials or an approval.
Existing operator `services.json` tool read grants can permit only the named
read-only view operations. Without such a grant, the actual Root requires its
own displayed review; selecting or bundling this package does not create that
grant or an approval. The host
requires the current native package, contribution, generation and published
version/fingerprint. Missing, disabled or changed selections return an explicit
error; they do not choose a compiled fallback. Distribution installation retains
existing operator files and effective registry choices, including disabled ones.

`ProductRuntime.invokeWorkspaceTool` and `ApplicationSession.invokeWorkspaceTool`
return the actual invocation. `approval()` exposes its frozen review and real
operation ID. `decide(operationId, decision)` resumes only that retained owner.
`output()` returns a defensive copy of a completed result. `close()` settles a
pending rejection and releases the actual result lease.

Filesystem reads retain native hashline anchors and range/raw handling. Native
grep and glob operate on the host's approved read-only view. Edit and filesystem
write produce an immutable application plan. They do not change workspace files.
Write accepts at most 32,768 UTF-8 content bytes, without NUL. Its input is frozen
in a private read-only view file, so JSON escaping does not exceed OS argument
limits. The reserved `.axyndra-worker-input.json` view path cannot be a requested
resource. Worker input and output remain bounded; ordinary requests retain their
existing limits. An ordinary Native Parent defensive result copy is limited to
262,144 bytes. An independent resource Root copy allows at most 8 MiB solely
for JSON escaping of the original at-most-1-MiB UTF-8 resource page; it does not
increase resource IO or process/frame limits. The actual result remains charged
until the copy finishes and is released even when copying fails.

Replacing a file normally supplies exact `expected_content`. When the transport
would be too large, the native writer supplies the SHA256 and byte count of its
actual frozen read view. This form supports a single replacement with at most
65,536 precondition bytes and 32,768 new content bytes. Host reads the safely
classified current file, checks those exact values, then retains the original
full-text durable plan and atomic CAS. A changed file fails before applying any
write. Multi-file proposals retain their original 64 KiB encoded limit.

Artifact and custom URI access use a separate resource operation. A native read
of `blob:sha256:<64 lowercase hex>` returns a request for `read_resource`; adding
`destination` returns an `export_artifact` request. A custom `scheme://...` read
or write returns a `read_resource` or `write_resource` request. Preparing these
references and running the read-only worker neither invokes the URI handler nor
reads, exports or writes an artifact. Artifacts are immutable. Unsupported URI
handlers and invalid destinations fail explicitly.

After inspecting the actual output, the caller may call `beginResource()`. This
consumes that invocation's frozen request once and submits a **new canonical Root
in the same Runtime**. It returns another retained invocation. If approval is
required, review its own `approval()` and decide its own operation ID. A plugin
result, copied JSON or receipt string cannot construct this continuation.
Artifact export uses the existing complete-content verification and atomic
workspace write primitive. URI IO borrows the existing registered handler;
no additional Store, registry or process owner is created.

Resource reads intentionally use a new API: artifacts page by bytes from zero;
URI text pages by lines from one and includes content type, immutable status and
handler notes. They do not invent filesystem hashline anchors for URI data.
Artifact export accepts a complete reference and a canonical workspace-relative
destination; offset/raw/range combinations are rejected. Every resource Root
uses denied network policy and its actual read or write capability.

The `read` and `grep` CLI commands use this selected native frontend. Without
`--interactive`, a pending approval is shown and no choice is fabricated. With
`--interactive`, type `approve <displayed-operation-id>` only after reviewing
that actual Root. To consume a resource or application plan, separately type
`execute-resource`; any required approval for the second Root is displayed next.
Leaving the proposal unapplied performs no resource write.

The native grep CLI accepts `--count`, `--case`, `--no-gitignore`, `--skip` and
one optional path/glob expression. A filter such as `src;*.cj` uses the native
semicolon-separated selection; it replaces the former separate `--glob`/`-g`
argument. The former Product-only `--limit`/`-l`, `--context`/`-C` and
`--files`/`-f` presentation modes are unsupported and return an error. The old
`-c` alias also returns an error; use `--count` for the native count result.
There is no local ripgrep execution or implicit conversion of those old flags.
Native `--skip` is an offset into its bounded result, not a replacement for
the old display limit or context-line expansion. This is an explicit frontend
API migration; native search output and count semantics remain authoritative.
