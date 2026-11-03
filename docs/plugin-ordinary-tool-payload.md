# Bounded payloads for an installed ordinary Tool

This profile transports the existing Program compiler/interpreter input and
result. Program remains an ordinary Tool. It does not gain a Service lifecycle,
filesystem access, a larger Tool budget, or additional host callbacks.

The operator selects the exact installed contribution in the existing
`settingsRoot/plugins/services.json` entry, alongside its explicit readonly
delegation grant:

```json
"tool_payload_limits": [{
  "schema": "axyndra.ordinary-tool-payload/v1",
  "contribution": "run",
  "max_input_bytes": 2097152,
  "max_result_bytes": 1114112,
  "max_service_response_bytes": 1114112,
  "max_message_bytes": 2162688
}]
```

These numbers are hard ceilings; lower valid profiles are supported. The exact
profile and the full configuration digest enter the canonical frozen plan.
Preparation and execution revalidate the installed package, generation,
contribution, configuration and actual Run catalog snapshot. Changing the
operator profile invalidates an old approval. A worker cannot negotiate larger
limits or select another contribution's profile. Other Tool, Command, pure
prepare, ContextProvider and Service limits remain separate.

Preparation freezes the input locally in the host's existing readonly delegation
canonicalizer. It does not send the source through the 64 KiB native `prepare`
frame and does not execute the compiler or read workspace content. The actual
Tool invocation uses the existing logical JSON codec and physical frame bound.
Subcall responses and the terminal result use the same identity, window,
sequence, digest, cancellation and deadline checks. The ordinary invocation
still has at most 32 service requests.

The existing Program limits are unchanged: 262144 bytes of raw UTF-8 source and
1048576 units of `programValueBytes` result tree cost. That cost counts eight
units per node plus text and field-name bytes; it is not the JSON encoded size.
The 2 MiB input envelope carries the worst JSON escaping of a 256 KiB source.
The 1 MiB plus 64 KiB result/child-response envelopes cover the old Product
bridge's reachable encoded output plus protocol metadata. This does not promise
that every theoretical 1 MiB tree containing control characters fits: the old
1 MiB bridge also could not carry its much larger escaped JSON. Such larger
encoded values remain unsupported and explicitly bounded. Node, depth, same
owner aggregate allocation and cumulative retained subresult bounds also apply.

Each host result carries an idempotent `ToolResultPayloadLease`. Wrapping a
result transfers the same lease. `detachTransfer()` only returns the worker's
two-transfer concurrency slot; the shared host allocation remains charged until
the terminal consumer calls `releasePayload()`. Core releases after canonical
persistence, hooks and event consumption, including failure exits. Direct API
callers own a successful returned result and must release it in `finally` after
consumption. The CLI and generic stdio ingress follow that contract. This lease
is allocation ownership, never execution authority or an artifact reference.

Integration requires the separately validated MCP host-removal69 change
(`2faf7f26bff5672c2912f9aa44f706e61265df2889c8b118099aba23817e1a67`).
The obsolete in-process MCP consumer does not implement the result lease and
must not coexist with this profile. `scripts/prepare_program_plugin.py` refuses
to build/run the formal fixture when those retired files remain. This dependency
does not authorize deleting old paths before their migration gates pass.

The authored tests cover real packaged protocol framing and original tree-cost
boundaries, actual Runtime subprocess cancellation and allocation release,
concurrent detach/close, and Product Direct/Committed plans and approval fences.
They require the fresh standalone Program and Workspace packages. At this
candidate's freeze they have not been compiled or executed. Full cancellation
inside the actual Program→Workspace→read-view process tree and broader artifact
parity remain separate open validation work; the Runtime wire fixture is not
evidence for that whole Product tree. No old Program path is removed here.
