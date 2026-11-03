# Retained service backend network permissions

A native service endpoint and its retained backend are separate sandboxed
processes. The endpoint remains network-denied. An operator can explicitly
authorize its backend with the existing `plugins/lifecycle.json` service field:

```json
"network": {"mode": "host", "egress": [], "publish": []}
```

This permits the backend to use the host network namespace, including private
addresses. It does not impose an origin allowlist. Protocol or URL restrictions
implemented inside an installed backend remain the responsibility of that
approved code. Use `denied` or an explicit mediated policy when narrower network
authority is required. Publication declarations remain unsupported for retained
services; Host mode itself does not provide syscall-level listener restrictions.

The complete operator configuration and selected network policy are frozen into
the launch grant. Startup still requires a real finite HostService Operation,
the caller's `NetworkAccess` capability for canonical resource `["host"]`, and the configured
approval decision. Installing or enabling a plugin does not approve this launch.
Dynamic calls use the same Thread and permission-domain binding, their own
current source and approval, exact byte intents, and actual derived Receipts.
The original startup never authorizes arbitrary later writes.

Only the lifecycle owner's private launcher can open a Host-mode backend. The
public raw channel API continues to reject Host mode, and an arbitrary custom
ProcessPort cannot opt in. The backend keeps its filesystem/process sandbox and
explicit read-only mounts. It receives the sandbox's fixed system PATH, not the
host PATH or SDK mounts. The existing host-selected CA bundle is mounted read-only
when configured, with fixed SSL_CERT_FILE and CURL_CA_BUNDLE values; this grants
no other environment or mount access. If no host-selected CA bundle is
configured, ambient `SSL_CERT_FILE` and `CURL_CA_BUNDLE` are not admitted.
Resolver/hosts files follow the existing
Host-network sandbox policy. Ordinary and secret environment bindings remain
subject to the separate lifecycle environment rules.

Changing or removing the configuration revokes the existing service and its
directory. A lower-authority call or another Thread cannot reuse the mutable
backend. Cleanup retains ownership until the actual process and endpoint
acknowledge release; changing network mode does not silently upgrade a running
service or create an automatic replacement.

This compatibility path does not give the native endpoint ambient network,
broaden MCP HTTP credentials, or establish completion of the MCP migration.

Seven actual Product cases passed, including Host/Denied real socket behavior,
canonical startup authority, revocation, public raw-port rejection and a private
launcher with an empty CA selection that cannot inherit ambient CA variables.
The last case tests the factory environment boundary, not a substitute Store
admission path. The complete Product run passed 291 cases; the related sandbox
and direct-runtime sandbox contracts were also built and executed from native
Linux working directories. See [the migration record](plugin-first-migration.md).
