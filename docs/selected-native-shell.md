# Selected native Shell frontend

Shell commands require an installed native Shell package, a current explicit
selector, and an operator lifecycle service started through its own canonical
approval. Coding/Full package membership does not itself configure or approve
a process. A missing selection fails with the existing diagnostic; no old
Kernel/Builtin Shell runs as a fallback.

The convenience frontend now freezes an explicit 10-second command default
(or the lower configured service ceiling when no timeout was supplied).
Explicit seconds/milliseconds are never clamped. A requested timeout must fit
the native request timeout, Host call timeout, and configured service lifetime.
Seconds=0 retains the legacy meaning of 600 seconds and is refused unless all
three configured finite ceilings support it. Actual live lease/deadline and
cancellation checks still run in the original Host pipeline.

The native physical backend request remains at most 30720 encoded bytes.
UTF-8 and JSON-escaped controls count toward this limit, so this release does
not claim unbounded legacy command-input compatibility. Larger output is a
different boundary: the original bounded stream publishes immutable artifacts.
The frontend can read an artifact only from its actual held completed Shell
result, through a separate ordinary read_resource Root and its own choice.
It retains the original result, child owners and output charges until their
actual cleanup acknowledgements succeed. Returned references or historical
JSON cannot reconstruct an owner, grant or approval.

The whole legacy persistent contract uses its separately configured 60-second
service and keeps its explicit 60-second command default. Its 131072-byte output,
124 timeout outcome, partial output, PTY, stdin, environment, cancellation and
durable same-Store session approval remain required actual gates, not source-only
success claims. Other legacy mains and Program retirement are still pending.
