# Independent web search plugin

Version 1.0.0 implements a native endpoint using prepared host HTTP intents.
The endpoint, packaging and offline protocol checks have passed. Real Product
HTTP validation is pending; the existing Product search implementation has not
yet been removed.

The package contains input/schema validation, deterministic provider selection,
Brave/Tavily/SearxNG request templates, response decoding/rendering, and the
existing search command's argument and compact-output behavior. It depends only
on JSON helpers and the standard library. The endpoint uses stdin/stdout and
does not read workspace files, credential files or environment values, spawn
processes, or access the network directly. It registers the `web_search` Tool and
offline `help` Command, declaring only `network.http`. The network search CLI
route has not yet migrated; help does not claim to execute searches.

The existing seven input fields and `content/provider/count/sources/error`
result shape are retained. `num_search_results` overrides `limit`, with a final
1–20 clamp. `temperature` remains accepted and unused; `max_tokens` is forwarded
only by Tavily. Auto selection uses supplied availability in Brave, Tavily,
SearxNG order. An explicitly missing provider does not fall back. Other legacy
CLI provider labels return an explicit unsupported result, not a request.

Rendered snippets keep the legacy 240-byte budget while avoiding split UTF-8
characters; structured snippets remain complete. The protocol limits input to
16 KiB, HTTP body and final encoded result each to 64 KiB, frames to 256 KiB and
diagnostics to 4096 bytes. These are explicit breaking limits versus the old
in-process path: oversize input/results fail rather than truncate JSON or pretend
success. The pure parser's legacy 16 MiB ceiling does not raise the IPC/HTTP limit.
Command help shows generic `tools inspect` and `tools invoke` JSON examples.
The legacy flag parser and compact renderer remain tested pure APIs, with no
Product CLI route; they are not advertised as working commands.

From this directory, with the repository's pinned toolchain available:

```sh
../../scripts/pinned_cangjie cjpm test --parallel 1 --no-color --no-progress
```

The offline tests exercise provider requests and golden results without network
access or credentials. Protocol, mediation, approvals, cancellation, durable
receipts, installation and CLI integration still require separate real tests.

The initial pure module was actually compiled and all 29 tests passed, with no
skips or errors; the dry-run enumeration also contains exactly 29 distinct cases.
Evidence is recorded in `phase4/web-business/{test.log,enumeration.log,summary.json}`.
That historical pure-only test binary SHA-256 is
`b121b24fcac4fde9c34c11e0dfb4c2f6e593cafb0a10d99f3d7b12ce76330463`.
Those tests preceded the endpoint and do not validate its newer source.

## Build and configuration

On Linux x86_64, use the pinned SDK/stdx, Python 3 and `patchelf`:

```sh
bash plugins/web_search/build-package.sh --output /absolute/path/to/new-web-search-package
python3 plugins/web_search/check.py --package /absolute/path/to/new-web-search-package
```

The directory must be new; packaging never merges or deletes an existing package.
It bundles the endpoint's Cangjie library closure, checks relative RPATH resolution
with `LD_LIBRARY_PATH` removed, records binary/library digests and retains licenses.
It does not bundle an AST engine, invoke curl or build Product. Recorded Linux
system libraries are still required. The preparation helper builds and checks a
fresh package, printing its path on stdout:

```sh
export AXYNDRA_WEB_SEARCH_PLUGIN_PACKAGE="$(bash scripts/prepare_web_search_plugin.sh)"
```

The helper also executes and enumerates all 29 reviewed pure business cases,
checks their nonzero pass count independently of the CJPM exit code, and stores
logs, source/binary digests and the exact case list beside the generated package.

On a host with HTTP intent support:

```text
/plugins import /absolute/path/to/new-web-search-package --scope workspace
/plugins enable axyndra:web-search --scope workspace
```

The Tool is `plugin.axyndra:web-search.web_search`. Import/enable does not grant
network or credentials; the operator separately configures exact endpoint grants
and credential bindings. The real install/approval/HTTP path remains unverified.
Use the [host HTTP configuration template](../../docs/plugin-http-services.md#operator-configuration)
for the full `plugins/services.json` shape and explicit credential injection.
Nonsecret configuration accepts only these optional string fields:

| Field | Meaning |
| --- | --- |
| `brave_credential_ref` | Opaque host credential reference for Brave |
| `tavily_credential_ref` | Opaque host credential reference for Tavily |
| `searxng_url` | Explicit SearxNG endpoint; the request appends `/search` |

References contain 1–64 ASCII letters, digits, hyphens, dots or underscores, never
key bytes or injection directives. The operator binds Brave to header
`X-Subscription-Token` and Tavily to JSON field `api_key`. The plugin does not read
`BRAVE_API_KEY`, `TAVILY_API_KEY`, `SEARXNG_URL` or old credential files. Unknown
configuration fields and incorrect types fail preparation.

Missing operator configuration is an explicit migration error, including for
`provider: "none"` or `auto` with no configured provider. Those Tool invocations
still require a `plugins/services.json` entry matching the installed namespace
and package digest, with `configuration: {}`, `requests: []` and `credentials: []`.
They then prepare no HTTP intents and return their offline result. The offline
`help` Command does not require this HTTP configuration. Existing search CLI
argument parsing remains an internal pure API until the generic Tool CLI is
connected; this package does not itself expose a working search command route.

## Protocol boundary

`kind: prepare` receives `{input, configuration}` with real thread/run/call,
positive epoch and empty Operation ID. It emits only `{intents:[...]}`: one
`search` intent for configured searches, none for an unavailable/disabled provider.
There are no preparation service, progress or UI calls.

`kind: tool` receives `{input, configuration, host_plan}`. The endpoint recomputes
and compares its request with the bound intent, then sends only `network.http`
with `{intent_id:"search"}`. Execution cannot substitute URL, body, header or
credential. The host owns grants, approval, generation, cancellation, budget,
mediation and durable parent/child receipts. The request timeout is 120 seconds,
further bounded by the host parent deadline; the plugin never redirects or retries.
The package digest retains the package API's `sha256:` prefix followed by 64
lowercase hex digits; the configuration digest is a separate bare 64-hex hash.
Neither digest is reformatted or substituted by the plugin.
`host_plan.generation` is the mounted plugin instance's canonical positive UInt64
string. The outer numeric `generation` identifies an individual worker connection;
preparation and execution can use different workers for the same mounted instance.
These counters are deliberately not compared. The host verifies instance authority,
while every worker envelope, response and cancellation must match its own hello.

Invocation IDs are bounded opaque strings, such as the host's `invoke-1`, and
are echoed without parsing a numeric counter. Service responses must match the full invocation identity, request/service IDs
and a nonempty Receipt. HTTP 4xx remains a completed HTTP child exchange, while
the search Tool returns its legacy nonnull `error` payload with `ok:false`.
Unavailable/disabled providers, invalid provider JSON and empty search content
also set `ok:false`. This intentionally changes the old Tool error metadata,
while preserving its result fields, so generic clients report failure without
knowing search-specific fields. The parent Tool fails independently of a
completed HTTP exchange; typed transport failures retain their separate host
uncertainty and are never represented as search success. Matching
cancellation clears the pending request; late, duplicate and unrelated replies
are rejected. No private execution state or credential store is introduced.

The initial endpoint build, all 29 pure unit cases and all 26 packaged-process
cases passed on the existing Linux toolchain. The packaged executable ran with
SDK/`LD_LIBRARY_PATH` variables removed and resolves its seven bundled Cangjie
libraries plus recorded system libraries. Its SHA-256 is
`5ed36e9fe26c25f8babeac19d436339a250becdd965235a175e717f5f1c88b43`;
`phase4/web-endpoint/summary.json` records the source/binary digests, enumeration
and package provenance. Broker responses in `check.py` are fixtures, not proof
of actual network mediation, secrets, approvals or Store facts. Real host HTTP
integration still awaits execution evidence. A subsequent integration review
found that these initial fixtures incorrectly used numeric invocation IDs.
The endpoint and fixtures now use the real host string identity, with an
additional malformed-ID regression. The corrected candidate was rebuilt and
passed all 29 unit tests and 27 packaged-process checks; its executable SHA-256
is `b637028b00129ad8dd619396ad4056e10ad77277eec566ab2001241856972932`.
`phase4/web-endpoint-2/summary.json` records that separate run and package. This
corrects the wire mismatch; real Product networking still needs its own evidence.
The subsequent Tool-error metadata correction adds two packaged-process cases
(29 total), and real-host review corrected the package digest fixtures to retain
their canonical `sha256:` prefix. Bare, incorrect-prefix, uppercase and truncated
package digests are rejected. This third candidate passed 29 unit tests through
the new business-check helper, an exact 29-case enumeration, and all 29 real
packaged-process checks. Its executable SHA-256 is
`ad51a580ff2344bc29a60f7f3f81a7f61093dea0575d44cdd82e0448c894c8da`;
`phase4/web-endpoint-3/summary.json` and `business-tests/summary.json` retain the
source/binary digests and case evidence. Earlier binaries do not prove these
corrections; real Product HTTP and CLI integration are still separate checks.
Real Product execution subsequently exposed a distinct instance/worker-generation
mix-up: the endpoint incorrectly equated their counters. The current candidate
separates these identities, uses different counters in all protocol fixtures, and
adds a malformed-instance regression (30 process cases). The fourth candidate
passed all 29 business tests, exact enumeration and all 30 packaged-process checks.
Its executable SHA-256 is
`f1631fb63d666aa2bfe20cb6162ee0a7857e74ae7ee340ed6d70d970db3b4b05`,
recorded in `phase4/web-endpoint-4/summary.json`. The third candidate does not prove
this correction; real Product validation must use the fourth package.

The Product unit gate prepares and checks fresh AST and web search packages
before running cases, sets their package environment variables, and records
their paths, entrypoint digests and provenance. It rejects helper failure,
missing paths and mismatched manifests/digests rather than skipping plugin cases.
Its Python tests cover that orchestration; running the complete preparation
through the updated gate remains a separate build validation step.
