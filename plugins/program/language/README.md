# Program language implementation

This package owns the restricted TS-like compiler, closed IR and bounded value
interpreter previously embedded in `tool_runtime/src/program.cj`. The original
compiler/interpreter algorithms, defaults, errors and value/trace results remain.
The old ToolRuntime exports are deleted; clients import `program_language`.

The interpreter's `execute(program, limits: ...)` and its executor's `invoke(call)`
no longer accept ToolInvocationContext. A trusted host port may capture its real
context; a worker needs no synthetic Run or Session. These value interfaces grant
no authority. Canonical parent/source, frozen catalog, capabilities, approval,
derived Receipt, cancellation, budget and nested slot enforcement stay in the
existing host pipeline. The previous Tool contract assertions remain, using a
test port that captures its actual pipeline context.

This is a source extraction checkpoint, not a completed installed Program plugin.
Product still statically imports this explicitly optional package and contains
its worker/launch/plan wrapper. The dependency ratchet records that remaining
coupling rather than hiding it as a generic host package. Removal requires an
independently installed native contribution, a bounded read-only derived service,
and actual compatibility tests. Ordinary Tool input/service limits are unchanged.
Preserve the original 256 KiB source and 1 MiB bridge/result bounds in that work.
The language default is 128 subcalls; Product explicitly caps its root at 32.

Validation at sealing: exact source/manifest graph and isolated patch application
only, zero Cangjie compiler or runtime calls. Existing Tool and Product Program
contracts must run against the integrated source before acceptance.
