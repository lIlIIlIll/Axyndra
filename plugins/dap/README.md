# Installed DAP plugin

`axyndra:dap` is an independently installed Native Service. The Product host
does not contain a built-in debug executor or statically link `dap4cj`.
Configure an adapter executable, arguments, mounts, network policy and bounded
resources in the existing plugin lifecycle configuration, then start `stdio`.
Its published tool name is `plugin.axyndra:dap.service.stdio.debug`.

The plugin preserves the original 28 actions and complete debug schema. It
owns adapter selection, launch/attach handshakes, breakpoint categories,
stopped-frame state, inspection aliases, output and session data. The shared
Host supplies existing authorization, approval, process isolation, cancellation
and canonical operation accounting. Reverse process requests use separately
admitted canonical children. Source metadata also goes through the existing
Host path; a plugin data path cannot grant filesystem authority.

Preparation performs no process or channel I/O. Finite request batches freeze
their wire bytes before dispatch. Actual responses, continuations and original
known or uncertain errors retain their existing ownership and byte bounds.
Cache-only observations have a real no-write path. There is no hidden retry,
second Agent execution kernel, or synthetic cleanup acknowledgment.

The original `support_tests/debug_contract` now installs the real artifact and
runs every existing launch, reverse runInTerminal, attach, breakpoint,
inspection, control, output, termination and schema expectation through the
public Product canonical entry. Its existing fake adapter supplies protocol
data only; it does not construct an approval, Root, Source, plan or Receipt.

Run the pinned unit suite and `scripts/prepare_language_plugin.py --plugin dap
--output NEW_DIRECTORY`, followed by the installed Product debug contract.
The independent protocol fixture checks the current exact `debug` Tool and
`session` Service handshake, including the original 28-action schema and
closed additional-property grammar; it does not assume a Service-only worker.
These source changes do not themselves certify current compiled artifacts,
complete lifecycle parity, clean installation or cross-platform acceptance.
