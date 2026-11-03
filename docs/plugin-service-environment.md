# Environment and secret references for managed channel services

Configure a backend process in the host-owned `plugins/lifecycle.json` file.
Its `environment` object maps a backend variable name to an explicit host
environment variable name. Values in that object are references, not literal
values. The backend does not inherit the full host environment.

For secrets, declare a plugin-level `credentials` list containing entries such
as `{"ref":"backend-token","source":{"environment":"BACKEND_TOKEN"}}` or
`{"ref":"backend-token","source":{"file":"backend-token"}}`. File sources
resolve under the host's `credentials` directory. The service lists the opaque
reference in `credential_refs` and maps its target variable with
`"secret_env":{"API_TOKEN":"backend-token"}`. Do not put secret text in
arguments, ordinary environment configuration or plugin configuration.

The host validates sources and includes the nonsecret reference specification
in the launch grant. Inspection, preparation and a rejected approval do not
read the secret. Resolution happens at the actual canonical execution handoff
inside the private process launcher. The plugin endpoint receives the channel,
not the raw credential. The backend receives only its approved environment.

Changing configuration, a referenced ordinary environment value or a secret
invalidates the retained launch. The host checks the private launch baseline
before subsequent I/O. Start the service again under the new grant. Fixed
sandbox variables including `PATH`, `HOME` and `LANG`, loader variables and
other reserved targets cannot be overridden.

Secret-bearing channels require actual ingress byte accounting. Startup,
refresh and lifetime output limits include bytes withheld by the streaming
secret filter, including partial matches. Both stdout and stderr are checked
for raw, JSON-escaped, percent-encoded and base64 representations across read
boundaries. A reflected secret closes the service and preserves an unknown
in-flight outcome; it does not authorize retry. Raw process-channel APIs keep
their existing secret denial.

This migration currently covers bounded environment and secret references for
channel backends. Explicit host-network grants are described in [service network policy](plugin-service-network.md);
both have actual Product validation recorded in the migration tracker.
These services still require explicit startup approval and existing process,
workspace and network grants. Nothing here changes the plugin endpoint's own
sandbox or makes remote metadata an authorization source.

The nine Product environment cases and the existing channel/lifecycle cases
passed in the complete 291-case Product run. Rejected approval is checked as an
actual terminal rejected Receipt with no handoff or peer frames; resource
capacity returns only after the existing bounded cleanup ACK. Separate metadata
tracing of the synthetic credential fixture confirmed no secret file read before
handoff; missing-path metadata probes are not represented as secret reads.
Exact source, binary, fixture hashes and preserved earlier failures are listed
in [the migration record](plugin-first-migration.md).
