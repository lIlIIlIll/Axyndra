# Pure Context and Resource logical payloads

The native host may offer `content_payload_limits` only when the inspected
package declares a ContextProvider or ResourceProvider contribution. A peer
opts in by echoing the exact supported value in its existing `ready` message.
Omission keeps the old bounds. An altered or unsolicited profile is rejected.

```json
{"schema":"axyndra.content-payload/v1","max_message_bytes":4521984,"max_input_bytes":4456448,"max_result_bytes":4194304}
```

The query bound is one existing 4 MiB canonical ContextRead output, 192 KiB of
ordinary query data, and 64 KiB for source links and envelope data. The result
bound is the existing 4 MiB Context snapshot codec. A serialized contribution
may still fail that final codec after host ownership/trust metadata is added;
failure never applies a partial Context version or truncates the result.

This is a transport and memory profile, not a capability grant. Only the exact
registered `context_provider` / `resource_provider` route uses it. The identity
still has an empty Run and Operation, epoch zero, and its host query nonce.
The same host's Tool preparation, Command, Pi, and Service limits do not change.
Pure queries emit neither progress nor host service requests. Their 5-second
deadline is not extended by chunks, output encoding, or retries.

The wire reuses `axyndra.logical-json/v1`: full native identity on every frame,
host-generated `payload_window`, transfer sequence 1, declared byte count and
SHA256, contiguous hexadecimal chunks of at most 16 KiB, then one end frame.
The receiver checks outer identity before accepting a header and verifies the
assembled invoke/result and window again. Duplicate/late/overlapping transfers
fail the query; no state can be adopted by another nonce. Old peers do not gain
logical framing just because another contribution on the package supports it.

Both ordinary physical frames and logical frames reserve bounded memory before
expanded parsing and check the existing 65,536 lexical-token ceiling. Native
host reservations share its existing 128 MiB owner pool. The pure Skills peer
uses the same Domain budget/assembler and retains each parsed input and result
charge through its actual consumer. The 512-byte token coefficient is
conservative accounting, not a measured RSS guarantee. Persisted Context data
continues to use the existing Context codec and Store; there is no new registry.

Only the host's verified ContextRead consumer can pass an expanded observed
query through Product. Public ordinary queries retain their existing 192 KiB
bound. A caller cannot turn reserved JSON fields into a canonical read fact.
The actual read still uses its original Run, capability ceiling, policy,
approval, slot, budget, Item, Operation and Receipt before a pure query runs.

The implementation and its four Runtime, two Product and six new package
protocol tests are staged and uncompiled. The Skills suite contains eighteen
cases including its previous twelve. This does not complete automatic user
directory selection, pending-read restart recovery or old Skills removal.
