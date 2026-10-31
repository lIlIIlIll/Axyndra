# Prepared plugin HTTP requests

This is the bounded HTTP part of the [plugin migration](plugin-first-migration.md).
It does not provide background services, MCP transports, streaming responses, or
independent plugin authorization. The migration tracker records the executed
package, Product, Core, Tool and Store contracts and their remaining scope.

Native executable packages may request `network.http`. The request only selects
the preparation protocol. Installation, enablement, and manifest capabilities do
not grant access to a host credential or network endpoint. Pi adapters retain
their current workspace-only service boundary.

## Preparation and execution

For each Tool invocation, the host first invokes the registered native Tool with
`kind: prepare`, effective Tool input and nonsecret configuration. This runs inside the
existing package-only, network-denied process sandbox, with no host services,
progress observer or UI. It has a five-second deadline, including a blocked stdin
write, 16 KiB argument limit and 64 KiB response-frame limit. See the
[process protocol](plugin-process-protocol.md#pure-tool-preparation).

The plugin returns untrusted request data:

```json
{
  "intents": [{
    "id": "search",
    "request": {
      "method": "GET",
      "url": "https://example.com/search",
      "query": {"q": "example"},
      "headers": {"Accept": "application/json"},
      "json_body": null,
      "credential_refs": [],
      "timeout_ms": 30000
    }
  }]
}
```

There are at most four unique intents. The host checks each request against the
operator's exact URL, method and credential bindings. It adds the gateway policy,
package content digest, namespace, instance generation and configuration digest
to the canonical parent plan. The input remains separate from the host envelope,
including when it uses fields named `input`, `configuration` or `host_plan`.
If an authorized hook rewrites arguments, this input is the effective argument
object frozen in the reviewed plan; the original canonical ToolCall remains in
the Thread. Approval restoration unwraps exactly the host envelope's input and
recomputes preparation. It does not feed the envelope back as new plugin input.

The canonical plan's `generation` is the mounted plugin instance's positive
UInt64 value, encoded as a decimal string. It is distinct from the numeric
`generation` in the process protocol envelope: that counter identifies a worker
connection within the mounted instance. Preparation and execution have different
authority scopes and may therefore use workers with different connection counters.
For example, a plan bound to instance `"23"` can execute on worker `7`. Endpoints
validate the plan generation's format without comparing these two identities.
The host revalidates instance authority against the frozen executor and persisted
parent plan; every IPC reply, service message and cancellation must still match
its own worker's full handshake and invocation envelope.

The normal ToolPipeline evaluates the complete parent plan and shows it for
approval when policy requires. Preparation runs again during approval and
execution; changed input, request, implementation or configuration invalidates
the earlier plan. The plugin cannot add a network request after approval.

During execution, its only HTTP service message is:

```json
{
  "request_id": "search",
  "service": "network.http",
  "arguments": {"intent_id": "search"}
}
```

The normal invocation correlation envelope is also required. The request ID must
equal the intent ID. The broker obtains URL, body, headers and credential references
from the persisted parent plan; IPC supplies none of those authority-bearing
fields at execution time.

The hidden `host.network.http` child uses the sealed Direct or Committed root,
same Run, epoch, budget and nested execution slot. The Store transaction verifies
the canonical parent, its execution handoff and the exact request, including the
private-address gateway rule. It records `operation_parent_intent_authorized`
with parent/child plan digests and rechecks this proof at execution and handoff.
This is distinct from a user approval and cannot override a hard policy denial
or missing Run capability. Raw callers, model ToolCall guesses, Program and other
derived roots cannot invoke this hidden port.

For an approved model call, Core supplies its freshly attested Committed source
to approval continuation. The Store's existing idempotent preparation check
verifies the exact Decision, scoped call, canonical Item and immutable plan
without resetting the pending state. Loading a plan through the raw approval
API does not manufacture this attestation or grant derived-service authority.
The continuation reacquires the parent's scheduler slot without charging its
ToolCall a second time. A child yields that slot through the normal nested
scheduler, including under a single-slot limit; cancellation, budget failure and
executor exceptions release ownership. A post-handoff exception remains Unknown.

The durable request key is fixed by canonical parent call and intent ID. A new
transport ID cannot produce another POST. An existing child can only yield its
original durable result; an unfinished or Unknown exchange is never resubmitted.
GET children are ReadOnly but NeverReplay. POST children are ExternalMutation and
NeverReplay. The networked parent is conservatively ExternalMutation/NeverReplay.

## Operator configuration

The sole configuration file is `plugins/services.json` under the product's
configured settings root. It is not loaded from the plugin package or workspace.
Unknown fields, duplicate identities, unsupported versions, oversized files and
unbound package digests fail closed. No default endpoint or credential discovery
exists in the host HTTP service.

This example is a template; replace the digest with the inspected installed
package's actual content identity (`sha256:` followed by 64 lowercase hex
characters). The algorithm prefix is part of that identity; configuration-file
digests are separate, unprefixed SHA-256 values:

```json
{
  "version": 1,
  "plugins": [{
    "namespace": "axyndra:web-search",
    "package_digest": "<installed package content digest>",
    "configuration": {
      "brave_credential_ref": "brave",
      "tavily_credential_ref": "tavily"
    },
    "requests": [
      {
        "url": "https://api.search.brave.com/res/v1/web/search",
        "methods": ["GET"],
        "private_addresses": [],
        "credential_refs": ["brave"]
      },
      {
        "url": "https://api.tavily.com/search",
        "methods": ["POST"],
        "private_addresses": [],
        "credential_refs": ["tavily"]
      }
    ],
    "credentials": [
      {"ref": "brave", "source": {"environment": "BRAVE_API_KEY"},
       "injection": {"header": "X-Subscription-Token"}},
      {"ref": "tavily", "source": {"file": "tavily.key"},
       "injection": {"json_pointer": "/api_key"}}
    ]
  }]
}
```

`configuration` is explicitly nonsecret plugin input. Only opaque references go
there. The host does not interpret these provider-specific configuration keys;
the independent plugin does. An absent configuration file does not restore the
old environment/file discovery behavior. An operator can explicitly bind an old
environment variable or credential file as shown above.

Each request grant matches the complete URL before query parameters, with no
prefix, wildcard, implicit redirect or alternate origin. HTTP and HTTPS require
an explicit absolute path. Userinfo, URL query/fragment, backslashes and control
characters are rejected. Query parameters are separate strings and are encoded
by the host. Private targets require explicit `private_addresses`, validated by
the same gateway as other controlled processes; an ordinary DNS name does not
implicitly authorize a private address.

Credential references are bound to this package and its request grant. Only the
operator selects the source and injection location. Sources are an explicitly
named host environment variable or a relative regular file under
`settingsRoot/credentials`. Paths cannot traverse symlinks or escape that
directory. Secret values are resolved only after canonical admission. They must
be nonempty and at most 8 KiB, without NUL or line breaks; header values must be
visible ASCII. Files are not trimmed. Injection cannot overwrite an authored
header/JSON field or collide with another credential. JSON pointers currently
select one nonempty top-level field and honor RFC 6901 escapes.

Updating the package requires an explicit new digest binding. Changes to any
configuration bytes invalidate pending plans and cancel active HTTP exchanges.
Disablement, instance replacement and parent cancellation also close the active
process. Cancellation cannot undo bytes already sent to the configured server.
Credential file checks follow the repository's regular-file/non-symlink pattern;
they do not claim an atomic defense against concurrent path replacement by a
separately trusted process with the same operating-system identity.

## Transport and results

The host builds fixed curl arguments and uses the existing mandatory sandbox and
Mediated gateway. The transport has no workspace mount, user toolchain, ambient
environment, shell, user curl configuration, arbitrary argv, redirect following
or automatic retry. The plugin endpoint itself remains network-denied. TLS
certificate verification stays enabled. HTTP header names affecting proxying,
framing, cookies or the target host are not plugin-selectable.

The service returns only `{status, body}`. A complete 4xx/5xx response is a
Completed HTTP exchange; the plugin renders the provider's business error.
Transport errors, timeout, cancellation or incomplete/truncated output never
pretend that a POST had no effect. The child is Unknown after handoff and cannot
be made successful merely by a plugin swallowing its error. A cancelling Run can
record an in-flight child's Unknown result without reopening execution.

Requests are at most 64 KiB, encoded URLs at most 16 KiB, response bodies at most
64 KiB, and serialized child outputs at most 192 KiB. The timeout is 1–120000 ms
and is clamped to the parent deadline. The HTTP subprocess never exceeds lower
parent process/output limits. The persistent native worker currently uses a
fixed resource profile: a parent limit below that profile, such as 4096 output
bytes or 32 open files, is rejected during preparation with
`plugin.resource_limit_unavailable`, before an HTTP child is admitted. It is not
silently widened or treated as a successful invocation under those lower limits.
Overflow is an explicit failure, not truncated JSON or an implicit retry.

No credential bytes are included in host-authored plans, IPC arguments, audit
metadata or Receipts. Host transport diagnostics and response headers are not
returned. Response filtering includes short credentials, raw text, JSON escapes,
percent encoding and Base64 echoes, before output persistence. This is not a
proof against arbitrary encoding by an untrusted remote server: the operator
credential binding also authorizes the configured recipient. Echo detection or
output-limit failure withholds the response and preserves uncertainty.

The [independent web search package](../plugins/web_search/README.md) demonstrates
this service. Its package/protocol tests and the real Product gateway/approval
contracts are separate evidence; pure request-template tests do not prove that a
network request traversed this boundary.

## Product entry points

Local packages can be inspected, installed and managed without configuring a
model provider:

```sh
axyndra plugin inspect ./web-search-package --json
axyndra plugin import ./web-search-package --scope workspace
axyndra plugin list --json
axyndra plugin enable axyndra:web-search --scope workspace
axyndra plugin commands --json
axyndra plugin command plugin.axyndra:web-search.help
```

Import leaves the package disabled. The list reports the actual installed content
digest needed in operator configuration. Enabling does not grant HTTP access.
The help contribution runs offline without HTTP configuration or a model; its
bounded text is returned through the ordinary command notice channel.

The same `plugin` entry provides local `update`, `rollback`, `disable`, `uninstall`,
`gc` and `doctor` operations. A package update does not inherit the previous
digest's HTTP grant. GC retains generations referenced by installation history.
Rollback restores the earlier package identity but does not resurrect an old
workspace grant: explicitly enable the restored package before using it. Existing
operator HTTP configuration remains unchanged and must still match that digest.
Git/npm acquisition through this noninteractive entry returns
`plugin.cli_interactive_required`; the existing interactive `/plugins` acquisition
path performs its permission checks. Supplying a source pin alone is not an
approval decision. `plugin --help` is static and does not initialize Product state.

Installed Tools enter the existing model/TUI/RPC catalog. The CLI also exposes a
generic Direct invocation entry; it contains no provider selection or request
templates:

```sh
axyndra tools list
axyndra tools inspect plugin.axyndra:web-search.web_search
axyndra tools invoke plugin.axyndra:web-search.web_search '{"query":"Cangjie","provider":"searxng","limit":5}'
```

`tools list` and `inspect` show public contributions, not hidden host services.
`invoke` accepts one bounded JSON object and uses the same schema, policy,
canonical Run, Operation and Receipt pipeline as other local tool invocations.
The configured policy still applies. If interactive approval is required, this
noninteractive command returns `cli.tool_approval_required` without execution;
use the interactive model/TUI/RPC flow to review the prepared operation. It does
not manufacture an approval from the presence of a CLI command.

`tools --help` is static and does not open Product state. The retired `search`/`q`
commands produce an explicit migration diagnostic before opening Product state;
their words are not reinterpreted as a model prompt. The independent plugin owns
the search schema, provider configuration, business failures and result content.

## Executed CLI acceptance

The repository's [native plugin CLI gate](../support_tests/plugin_cli_blackbox/README.md)
has passed against the App with the old built-in web implementation removed.
The self-contained `run.sh` entry built a fresh base package (29 business and 30
process checks), compiled a real 1.0.1 endpoint from a separate source copy (30
process checks), and completed 17 checks through 67 real App invocations. Five
real short-process tests also verified bounded termination of the harness's owned
sessions. The final summary is `phase4/cli-gate-1/summary.json`.

The acceptance uses a local HTTP origin, empty settings and no model credentials.
It does not use `--fixture`, fake registration or direct lock edits. Read-only
SQLite inspection proves the Direct parent, derived HTTP child, exact request
key, ParentIntent audit, handoffs and durable Receipts. Manual approval policy
produces no HTTP exchange; an explicitly configured trusted call succeeds; a
provider business error returns nonzero. The hidden service remains unavailable
to raw CLI callers.

The lifecycle checks include real update, refusal to inherit the old digest's
HTTP grant, rollback remaining disabled until explicit enable, a successful
request after reenable, uninstall, GC retaining three referenced historical
snapshots, and doctor reporting no issues. The App SHA-256 remains
`b2b587742050b324c93e38539ff3fb177326d737dfdaf16afc44cf8cb15418f9`
before fixture preparation and before/after acceptance. The package itself stays
at release version 1.0.0; 1.0.1 is a separately built upgrade test artifact.
These CLI results do not themselves assert public-provider availability, clean
dependency-cache builds or completion of the performance/distribution matrix.
The separate final Product gate passed all 122 enumerated unit cases in isolated
processes after removing the old web path, with no failed, skipped or errored
cases (`phase4/product-full-2/summary.json`). Its source manifest was unchanged
throughout the run; the migration tracker records its identity and broader limits.

The deliverable `axyndra-web-search-plugin-1.0.0-linux-x86_64.tar.gz` was built from
that fresh base artifact and checked after extraction into a new native Linux
directory. All 12 files, including seven runtime libraries and package provenance,
retain identical bytes; the extracted entry and libraries retain their relative
RPATHs. Archive permissions are 0755 for directories/executables and 0644 for
JSON/license text, normalized in native staging because the source DrvFS mount
reports 0777 throughout. Thirty packaged-process checks passed without SDK or
`LD_LIBRARY_PATH` environment settings. The declared Linux system libraries remain
required. `phase4/web-deliverable-1/summary.json` records the archive digest and
preserves the initial permission-check failure separately.
