# Native readonly Shell

This independently installed `axyndra:shell-readonly` package publishes `exec`.
It is distinct from the persistent `axyndra:shell` channel service. It can be
disabled, upgraded, or uninstalled separately. Coding and Full include it;
Minimal includes neither its binary nor its source business implementation.

Pure preparation returns an exact Host-held parameter reference, a package
worker and a workspace resource request. It performs no filesystem or process
effects. The real canonical child runs the worker in the existing isolated
readonly resource view with denied network. The package owns shell quoting,
command policy, cwd/env grammar, capture, timeout, and output decoding.

Command bytes remain bounded at 131072; worker input 229376; aggregate captured
stdout+stderr 131072. The Host's separate service envelope and Run output budget
remain bounded independently. Workspace views retain 16 MiB / 1024 objects.
`timeout_ms` supports 1..600000, or legacy `timeout` 0..600 seconds (0 means 600).
The operator must grant `exec` in the exact read-only `tool_read_grants` object,
`read_view_parameter_references`, and `read_view_parameter_contexts` in the
actual namespace/package-digest services entry. The last opt-in freezes the
actual workspace-relative working directory as descriptive metadata after
link-free native probing and unchanged workspace capability checks; the
Native worker consumes its exact frozen argv. Missing grants refuse.
Long execution requires an explicit generic finite read-view deadline profile;
the default Host read-view contract remains 60000 ms. No value is silently
clamped to 60000. Actual cancellation and the Root deadline can end work earlier.

An `exec` requested by another plugin is a new canonical Derived operation,
and its resource worker is a second actual Derived operation. Parent plus the
two children cost three operations/Receipts. A budget of two must fail; it is
never enlarged by the route or package. Startup approval is not command approval.

A services entry binds the actual installed package digest. For example, its
explicit grant is `tool_read_grants: [{"kind":"tool","name":"exec","effect":"read_only","services":["process.readview"]}]`,
`read_view_parameter_references: ["exec"]`,
`read_view_parameter_contexts: ["exec"]`, and
`read_view_deadlines: [{"contribution":"exec","maximum_ms":600000}]`.
The separately selected complete `protocol_limits` must have
`call_timeout_ms: 600000`; all other original frame and payload bounds still
apply. These configuration bytes are frozen and revalidated with the actual
ready schema and Root. A shorter actual caller/Root cancellation deadline wins.
The independent frontend selector `plugins/shell-readonly-tools.json` uses
`schema: "axyndra.shell-readonly-tools/v1"`, the actual namespace and installed
package digest. Existing operators and choices are never overwritten.

Complete captured output includes control bytes and invalid UTF-8. The worker
uses a private canonical base64/byte-count/SHA representation inside its exact
five-field result; the parent verifies both streams and their combined 131072
raw-byte limit, then applies the original per-invalid-byte replacement decoder.
No Host Shell codec or additional effect authority is introduced. The fixed
private representation is below 229376 bytes; the ordinary service envelope
remains below 262144. Full business JSON can be larger after text escaping.

To retain that full output, the operator explicitly adds this existing neutral
transport profile (it grants no capability and never enlarges a Root budget):
`tool_payload_limits: [{"schema":"axyndra.ordinary-tool-payload/v1","contribution":"exec","max_input_bytes":229376,"max_result_bytes":1048576,"max_service_response_bytes":262144,"max_message_bytes":1056768}]`.
The original 262144 physical frame is unchanged. The actual current Host offer
and invocation window must agree before segmented result transport is used.
Without this opt-in an oversized result fails; it is never silently truncated.
Encoded/raw/decoded/JSON copies are prepaid under the same 128 MiB pool and two
process transfer slots; buffers remain owned until emission, and the actual
Host ToolResult remains retained until its consumer's same-owner ACK.

`check.py` contains nineteen real packaged protocol/worker tests, with no skip.
The wire peer supplies descriptive fixture replies; it cannot approve or prove
a Host Root. The separate full Product and SQLite contracts remain mandatory.
This source candidate is uncompiled and unexecuted. Linux x86_64 packaging and
all real Host/Pi/direct/committed legacy cases are required before acceptance.
