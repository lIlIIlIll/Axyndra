# Installed model policy

The model-providers 1.2.0 package accepts a configuration-bound neutral capability
snapshot. Product inference requires an installed ModelProvider contribution and
the operator's existing `plugins/services.json` grant. Catalogs and profiles remain
available for selection, pricing, setup UI and history. They no longer select a
wire adapter or infer production execution capabilities.

Each `configuration.model_providers` mapping has exactly these fields:

```json
{
  "version": 2,
  "model": "profile/model",
  "contribution": "openai-responses",
  "wire_model": "wire-model",
  "provider_id": "profile",
  "credential_refs": ["provider-key"],
  "configuration": {
    "base_url": "https://provider.example",
    "provider": "openai",
    "dialect": "openai_responses",
    "headers": {},
    "timeout_ms": 120000,
    "allow_insecure_http": false
  },
  "capabilities": {
    "context_window": 128000,
    "max_output": 16384,
    "endpoint_max_output": null,
    "thinking": {"mode": "none", "levels": [], "tiers": []},
    "tools": true,
    "parallel_tools": true,
    "images": false,
    "structured_output": false,
    "prompt_cache": false
  }
}
```

These are policy data, not network or credential permissions. Existing request
allowlists, opaque credentials, package digest, generation, actual Attempt owner,
cancellation, budgets and resource cleanup remain mandatory. A capability flag
cannot mint a Tool operation or authorize HTTP.

Thinking modes are `none`, `toggle`, `effort`, `budget` and `adaptive`. Levels use
canonical order `minimal, low, medium, high, xhigh, max`; numeric budget tiers are
explicit and exactly cover their levels. Toggle declares all six normalized
levels. Missing booleans, unknown fields, wrong types and inconsistent values are
errors. No provider name, URL or dialect supplies missing neutral policy.

Product normal requests and internal compaction read the same versioned mapping.
The SHA-256 of the exact services document enters the existing capability
fingerprint and resolved-policy payload. InstalledPort independently reloads and
checks that digest before creating the actual provider binding. Changing even a
non-capability header after request construction invalidates that request. Core
still creates the only Attempt and Store persists its normal request/policy
snapshot; there is no parallel model ledger.

Historic capability snapshots without a configuration digest retain their exact
old fingerprint and remain readable. They are not silently promoted to installed
execution proof. Reopening unsupported old provider transcripts is an explicit
recovery incompatibility; this change does not claim automatic historic replay.

The former six-field mapping is rejected with
`model.provider_mapping_migration_required`. Use the package's offline
`tools/migrate_configuration.py` to prepare a reviewable version-2 proposal. It
copies the old explicit capability values, resolves old DeepSeek parallel-tool
policy inside the optional package, and does not read secrets, access a provider,
install anything or write grants. The operator must review and adopt the proposal
for the exact installed 1.2.0 package digest. The old catalog/profile files are not
deleted or rewritten.

Product's existing data-only request constructor still returns a request when
configuration is absent or invalid. Such a request has no optional features and
no configuration fingerprint; InstalledPort returns the precise configuration
error before I/O. Adding a valid mapping later cannot authorize that previously
constructed request, because the required configuration-bound fingerprint differs.

The staged increment has an executed 19-case offline Python migration suite.
Its new Product, Domain, real SQLite retry-continuation assertions and packaged
39-method adapter protocol suite require the serialized build/validation queue.
Neither these authored tests nor old package results establish new-binary parity.
