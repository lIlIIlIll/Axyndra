# Native Program and optional input evidence

The native executable owns the restricted Program compiler and interpreter.
The Host resolves a frozen operator alias and executes each readonly child
through the existing canonical Tool pipeline, Source, approval and Receipt.
There is no Product Program worker or separate execution registry in this
retirement candidate. Compilation and actual acceptance of this candidate
remain pending; source checks are not execution evidence.

Use `plugins/services.json` version 1 with the actual installed package digest,
empty network `requests` and `credentials`, and `tool_delegations` for the exact
`run` contribution. Each alias names an installed readonly Workspace Tool with
its own current read grants. The Product endpoint keeps the original 32-call
ceiling. Startup approval never approves a later Program Root.

Input attachment persistence is **off when its operator entry is absent**.
An operator may explicitly add this sibling field to that exact plugin entry:

```json
"tool_input_attachments": [
  {"contribution":"run","field":"code","max_bytes":262144}
]
```

The installed manifest, actual ready Tool, operator configuration and frozen
canonical Root must all agree. This literal top-level UTF8 selector has no
path, JSON-pointer, PID or artifact-reference semantics. It grants no Tool,
filesystem access, capability or extra budget. A changed profile, package,
generation, Source, Run, Thread, cancellation or canonical input fails closed.
The Host pays in the existing shared 128 MiB allocation aggregate before
copying or opening a file. Its private owner reserves a conservative 64 MiB
peak for the input and concurrent Root verification; this is not user output
or a new Run allowance. A failed close retains the file and charge for the
same owner's cleanup retry. A returned result, including an error, keeps its
actual input owner until the consumer acknowledges the result.

The Host writes complete UTF8 bytes, verifies the file and hash, and pins them
to the actual original Root and reserved Receipt. Native Program only maps the
small descriptive descriptor to `program_artifact`, `program_sha256` and its
actual SDK tag after checking the complete code bytes/hash. A descriptor is
never a Source. Historical display joins the completed original call, original
provenance, handoff, result, Receipt and metadata. Disabling the plugin does not
restore an execution grant; history and the immutable original blob remain
readable through their ordinary Host route.

Large code/result transport separately needs an explicit existing
`ordinary_tool_payload` profile. Raw physical frames retain their 256 KiB
limit; the accepted shared codec bounds logical messages and charges the same
process slots before encoding. Program source remains at most 262144 UTF8
bytes and proposals at most 1 MiB. There is no grammar or frame-limit increase.

File-plan previews are also off by default. Set `file_plan_proposals:true` only
in the exact `tool_delegations` entry when this operator intends the existing
`host.file.plan.propose` service. The actual Root still needs WorkspaceRead and
ExtensionInvoke, current Source and the caller's explicit budget (the preview
fixtures use four Tool calls). The service returns its real Derived Receipt;
applying a proposal remains a separate approved ordinary Root. Missing Receipt,
stale configuration, cancellation and default refusal never produce a success.

Build with the official `scripts/prepare_program_plugin.py` from an owned
checkout. Its original 19 packaged tests, two bounded request tests and three
preview tests remain mandatory, plus four attachment wire tests (28 total).
These wire peers grant no Root/Receipt authority. Actual Product tests require
both current Program and Workspace packages and the real canonical pipeline;
all original Support mains remain separate mandatory gates.
