# Native ModelProvider adapters

Version 1.1.0 requires a host accepting the typed `reply_stream` terminal.
For streamed text and reasoning above 64 KiB, the terminal contains ordered
byte ranges and SHA-256 digests of this same Attempt's already emitted UTF-8
text. The host verifies complete coverage before applying its existing reply,
usage and terminal checks. Text deltas remain bounded physical frames. This
avoids sending the same large text twice; it grants no resource or replay
authority and does not increase the host's ordinary process output ceiling.
New hosts still accept the original 1.0.0 ordinary `reply` terminal. Older
hosts reject the new kind explicitly. Non-streaming, opaque provider state and
structured output retain their existing representation and limits.

This independent package declares three `ModelProvider` contributions:
`openai-chat-completions`, `openai-responses`, and `anthropic-messages`. The
package reuses the existing typed `model_adapters` / `llm4cj` request encoders,
stream parsers, dialects, terminal validation and HTTP error classification.
Discovery has no Tool, Command, Hook, Service or model execution authority.

The host admits each dispatch through the existing Core Attempt and SQLite
`dispatch_claimed` proof. The worker and curl exchange have distinct typed
`ModelAttempt` resource owners, not fabricated Operation IDs. No model Tool,
second Attempt, second model loop, or Operation Receipt is created. Usage and
terminal facts return to the same Core completion and budget accounting path.

The worker runs with Denied network and only its installed package mounted.
HTTP `open/head/read/close` requests go through a host-only interface bound to
that same actual dispatch. The host checks the installed namespace, contribution,
package digest, generation, current operator configuration and exact URL/method/
credential grant. Secrets are first resolved after Attempt dispatch claim and
injected only by the fixed private HTTP launcher. Header/body/stderr reflection
passes the existing filter; `Retry-After` is a bounded, filtered header projection.
Rotation, disable, replacement or cancellation revokes the selected provider.
Success requires the real HTTP response end and resource cleanup acknowledgements.

The existing `settingsRoot/plugins/services.json` is the only grant source. Its
plugin entry is bound to `namespace` and canonical `sha256:<hex>` package digest.
Add an exact model mapping within the existing nonsecret `configuration`:

```json
{"model_providers":[{
  "model":"profile/model-id",
  "contribution":"openai-chat-completions",
  "wire_model":"provider-wire-model",
  "provider_id":"profile",
  "credential_refs":["model-key"],
  "configuration":{
    "base_url":"https://api.example.test",
    "provider":"openai",
    "dialect":"openai_chat",
    "headers":{},
    "timeout_ms":120000,
    "allow_insecure_http":false
  }
}]}
```

The entry also needs an exact `requests` POST grant for the resulting endpoint
and a `credentials` binding for `model-key`, such as an operator credential file
injected into `Authorization` with prefix `Bearer `. The model ID must match the
existing catalog display ID; its host-owned capability snapshot remains the
policy source. Selection never dispatches by provider name. An explicitly mapped
but disabled, invalid or removed provider does not fall back to a static adapter.
Unmapped models retain the old path while parity validation remains incomplete.

Build on Linux x86_64 with the pinned SDK/stdx and `patchelf`:

```sh
scripts/prepare_model_provider_plugin.sh /absolute/new/package-directory
```

The package includes the executable, recursively resolved non-system runtime
libraries, licenses and source/binary provenance. It does not depend on the
developer SDK environment at execution time. `check.py --package ...` runs the package source's exact
real executable protocol cases against a controlled host wire fixture. It uses
the actual adapter implementations; it does not prove Product authorization or
public provider connectivity. Product tests separately require
`AXYNDRA_MODEL_PROVIDER_PLUGIN_PACKAGE` and `AXYNDRA_MODEL_PROVIDER_ORIGIN` (the
repository's `plugins/model_providers/tests/origin.py`) and exercise actual
installation, local HTTP, sandbox/gateway, unique Attempts and SQLite facts.

The earlier package revision passed 33/33 actual protocol checks. The host
checkpoint compiled/enumerated 401 Product cases and passed 35 selected actual
Model cases, including all three installed adapters. It did not execute all 401.
Later compact-terminal and internal-Attempt changes have separate validation
records; those earlier counts do not certify the later source graph. Physical
frames remain at 256 KiB. An explicit existing operator `protocol_limits` plus
`payload_limits` profile enables the shared logical JSON chunk/hash protocol:
input ≤4 MiB, result ≤8 MiB, and body≤the approved write bound (below 4 MiB because
its hex form plus envelope must fit the ≤8 MiB prepare limit). Each physical frame
and assembled message must match the same actual Attempt identity. Ordinary
Tool and Service limits are unchanged. The shared allocation budget accounts
for assembly/encoding/DOM copies before allocation and stays owned through the
consumer callback; malformed sequences, offsets, hashes and early EOF fail closed.

Requests larger than 64 KiB use a host-created content-addressed Artifact. The
existing GC transaction pins it to the actual claimed Attempt audit evidence.
No plugin-supplied reference, copied dispatch DTO, obsolete epoch or cancelled
owner can read that body. The fixed launcher revalidates its size/hash and writes
bounded chunks to curl. Credential rotation checks retain only a bounded request
authorization projection, never the large body or a plaintext secret in facts.

The worker has no invented 120 second lifetime. Zero/long provider timeout values
are preserved only through the private actual-ModelAttempt launcher; real Run
cancellation/deadline and the same Run-owned cleanup task remain authoritative.
Zero does not remove Core first-response/idle/wall policies. Ordinary HTTP
requests retain their 120 second validator by default.

This is not complete former transport parity. The old 64 MiB model HTTP response
ceiling exceeds the current explicit result profile (maximum 8 MiB). Full response
memory lifetime, all image/opaque-state parity, endpoint retirement, static
provider deletion, package performance and historical recovery across replaced
instances remain open. The internal approval/compaction migration now claims its actual
internal Attempt before dispatch; its additional Product cases require their
own validation and are outside the 35-case checkpoint. No fallback bypass is
provided. Packaged protocol fixtures and Product/SQLite integration cases remain
separate evidence. See `docs/model-provider-plugin-contract.md` for the exact
checkpoint source/binary/evidence hashes and remaining A6 acceptance work.

# Review-only legacy configuration conversion

The package includes `tools/migrate_configuration.py` (Python 3.9 or newer).
It is an offline operator utility, separate from the ModelProvider worker:

```sh
python3 PACKAGE/tools/migrate_configuration.py \
  --providers SETTINGS/providers.yml --models SETTINGS/models.yml \
  --selection model-migration-selection.json > model-migration-proposal.json
```

The selection names the exact installed package and one explicitly chosen old
credential source per used profile. It contains no credential values:

```json
{
  "namespace": "native:model-providers",
  "package_digest": "sha256:REPLACE_WITH_THE_INSTALLED_64_HEX_DIGEST",
  "package_version": "1.1.0",
  "providers": {
    "myprofile": {
      "credential_source": {"file": "myprofile.key"},
      "private_addresses": []
    }
  }
}
```

Alternatively select `{"environment":"THE_EXISTING_API_KEY_ENV"}`. The old
adapter tried that variable first and then `credentials/PROFILE.key`. The
current generic HTTP credential grant has one source, so this converter requires
an explicit choice; it does not silently preserve or invent fallback authority.
It never reads either credential, examines the environment, resolves DNS,
activates a package, writes settings, or creates an Attempt.

The proposal records SHA-256 of both exact input files and normalized operator
selection. Review its exact URLs, POST methods, injected header names, private
addresses, package version/digest, and model mappings. Explicitly merge only its
`plugin_entry` into `SETTINGS/plugins/services.json` after checking that the
source files and installed package still match. Existing unrelated entries must
remain intact. There is no production configuration CAS/apply API in this
increment, and this manual adoption must be serialized with other operator
configuration changes. A generated proposal itself is never an authorization.

The converter follows explicit protocol/API/dialect selection, never provider
or model name inference. Model headers override profile headers; adapter-owned
request headers keep their existing final precedence. Loopback HTTP remains
explicitly representable but requires an operator-provided address list.
OAuth remains unsupported, as in the old API-key runtime. Ambiguous, duplicate,
unknown, oversized, or unsupported line-oriented YAML input fails explicitly.
This is not a general YAML parser. Input files and the proposal are each bounded
to 1 MiB; unknown credential sources and inline secret fields are rejected.

Keep `providers.yml`, `models.yml`, and historical state: the current host still
uses their catalog and capability metadata. `neutral_model_metadata` records
the equivalent provider-neutral capabilities for the subsequent host-dependency
removal; it is review data and is not another capability registry. Old snapshots
and grants are not rewritten. This migration helper does not complete A6 or
remove the remaining legacy fallback.

`check_migration.py` exercises 18 offline cases including all eight dialects,
three wire APIs, header precedence, thinking budgets, credential non-access,
strict rejection, Unicode CLI output, and unchanged input files. The package
helper runs these before building and hashes the bundled migration utility in
its provenance. Real installed-Product adoption/revocation contracts are authored
separately; their Cangjie execution is still required.
