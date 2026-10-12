# Native plugin CLI acceptance

This Linux black-box contract runs a real `agent_app` executable with an empty
settings directory and no model credentials. It installs a native web-search
package through `plugin import`, enables its contribution, and invokes it through
`tools`. A loopback HTTP origin receives real requests through the Product broker.
The test does not use `--fixture`, fake registration, or write installation locks.

Build the app first, then run the complete gate:

```sh
scripts/pinned_cangjie cjpm build -m agent_app -o agent_app
bash support_tests/plugin_cli_blackbox/run.sh \
  --candidate target/release/bin/agent_app \
  --output-dir target/gate-evidence/plugin-cli-current
```

The output directory must be new. Without `--output-dir`, the gate creates a
unique directory under `AXYNDRA_EVIDENCE_DIR` or `target/gate-evidence`. The gate
builds and checks a fresh base package through `prepare_web_search_plugin.sh`,
copies the independent source to a new artifact directory, and compiles a real
1.0.1 endpoint. Its manifest, native handshake, package provenance and process
tests all use that version. It never patches executable bytes. The copied source
and exact version patch are retained. The existing pinned SDK and dependency
cache can be reused; this is not a clean dependency-cache claim.

To check already built artifacts without acquiring a compiler:

```sh
scripts/pinned_cangjie python3 support_tests/plugin_cli_blackbox/check.py \
  --candidate /absolute/path/agent_app \
  --package /absolute/path/web-search-1.0.0 \
  --updated-package /absolute/path/web-search-1.0.1 \
  --output-dir /absolute/path/new-evidence-directory
```

`prepare_update.py --help` documents the separately callable update builder. It
requires new, disjoint source, output and evidence directories. Without `--build`
it only prepares the copied source. Source identity changes are exact and fail
closed when the versioned source contract changes.

The checks cover:

- Static help and explicit retired-command diagnostics without creating state;
  unavailable contributions before installation; strict options and JSON limits.
- Actual native help through `plugin commands` and `plugin command`; the seven
  parameter schema from `tools inspect`; hidden HTTP services remaining private.
- `AlwaysAsk` rejection with no HTTP request or child admission, and a trusted
  request backed by explicit package-digest and origin configuration.
- Read-only SQLite evidence for the canonical Direct root, derived HTTP child,
  exact request key, ParentIntent audit, execution handoffs and durable Receipts.
  A real HTTP error must return nonzero from the business tool.
- Disable, reenable, rejection of a manifest-only incompatible update, real
  source-built update, rollback, uninstall, history-preserving GC and doctor.

Rollback restores the old identity with the workspace contribution disabled.
The test proves it cannot be invoked until explicitly enabled. The original HTTP
configuration stays byte-for-byte unchanged throughout: the new digest cannot
inherit its authorization; after explicit reenable the old digest can use its
still-matching grant. Uninstall removes the contribution while referenced history
remains. GC must retain those snapshots rather than deleting rollback data.

Each app invocation gets a deadline and separate stdout/stderr logs. The evidence
includes app and package hashes, origin requests, canonical result proofs and a
summary. The candidate SHA must remain identical before and after the run. Any
failed assertion, missing package, timeout, or unexpected Cangjie exception
fails the gate. This proves a local HTTP fixture, not public-provider availability.

The outer gate forwards termination through the harness to its active App
session, gives owned processes a bounded TERM cleanup interval, then kills any
remaining owned group and reaps its child. Per-invocation hard deadlines retain
their immediate group kill. The Linux cleanup helper observes child termination
without reaping before its final group cleanup, preventing PID reuse in between.
Five real short-process tests cover deadline kills, graceful TERM, ignored TERM,
nested independent sessions, descendant cleanup and an unaffected unrelated
process. They run before the fresh fixture builds.

The phase 4 acceptance checkpoint with the old built-in web implementation removed
passed all 17 checks through 67 actual App invocations. Its App SHA-256 was
`b2b587742050b324c93e38539ff3fb177326d737dfdaf16afc44cf8cb15418f9`
before and after; the evidence summary is `phase4/cli-formal-1/summary.json`.
That checkpoint used prebuilt real base/update packages. A complete gate run
reports its separate fresh-build results and acceptance summary; the checkpoint
does not substitute for those results or for the broader Product test suite.

The subsequent self-contained gate also passed: `phase4/cli-gate-1/summary.json`
records five cleanup tests, a fresh base build with 29 business/30 process checks,
a separate source-built 1.0.1 package with 30 process checks, and all 17 acceptance
checks through 67 App invocations. The candidate SHA above is identical before
fixture preparation and before/after the black-box run. Exact gate source and
base business-test evidence are preserved with that result. The black-box portion
took 781.11 seconds across its independent CLI processes; this is a correctness
checkpoint, not a single-request latency measurement or performance improvement.

The verified base package was also archived as
`axyndra-web-search-plugin-1.0.0-linux-x86_64.tar.gz` (SHA-256
`803f83cdfe65cd96f95e2e5867263618a84ac8baa99e9215ef4af3382f8d3016`).
After native Linux extraction, all 12 files matched the source bytes, the seven
runtime libraries and entry had the expected relative RPATH, and 30 process
checks passed without SDK/loader environment paths. Native staging normalized
DrvFS's uniform 0777 modes to 0755 for executables/directories and 0644 for
JSON/license files. The archive preserves those modes; no binary bytes were
patched. `phase4/web-deliverable-1/summary.json` includes both the final result
and the preserved initial permission failure. This deliverable is version 1.0.0,
not the independently compiled 1.0.1 update fixture.

Separately, the final Product unit gate passed all 122 enumerated cases in isolated
processes, with zero failures/errors/skips and unchanged source manifest
`89c4b3403960c3eb2824f343f1a200d54b0e8a7e2dc9aa8e77b7b22423964578`.
That result is recorded in `phase4/product-full-2/summary.json`; it is not inferred
from this CLI gate's 17 checks or counted as additional CLI coverage.
