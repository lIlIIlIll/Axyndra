# Distribution profiles and default artifact

`scripts/package_candidate.sh` defaults to `minimal`. Build the independent
`agent_minimal` executable first; an explicit `AXYNDRA_SOURCE_BINARY` remains a
reviewed input and is recorded in provenance. A fresh destination is required.

| Selection | Host | Bundled/default-enabled packages | Core-required |
| --- | --- | --- | --- |
| unset or `AXYNDRA_DISTRIBUTION=minimal` | `agent_minimal` | none | none |
| `AXYNDRA_DISTRIBUTION=coding` | `agent_app` | nine | none |
| `AXYNDRA_DISTRIBUTION=full` | `agent_app` | seventeen | none |

The exact members are in `packaging/distributions.json` and the corresponding
`profiles/*-plugins.json`. Bundled bytes, default enablement and build dependencies
are separate facts. Minimal publishes an empty adjacent distribution manifest.
Coding/Full package each native plugin independently, validate its content digest,
and keep existing operator settings and explicit disable choices. Bundling supplies
no credentials, network grant, workspace permission, approval or service startup.

```sh
AXYNDRA_DISTRIBUTION=minimal scripts/package_candidate.sh
AXYNDRA_DISTRIBUTION=coding scripts/package_candidate.sh
AXYNDRA_DISTRIBUTION=full scripts/package_candidate.sh
```

Coding/Full require their declared pinned engine/runtime inputs. Existing full
Product release/regression and process-consumer readiness probes retain Coding
when no profile is set and preserve an explicit caller selection, including Full.
An explicit Minimal selection does not make those Product fixtures a Minimal
acceptance gate. These probes are not the new
Minimal release gate or a three-profile release matrix. The current source has
removed the legacy Shell/Eval/Program tool implementations, but Product still
contains the Yield tool and Task result assembly business. Recipe selection alone
does not establish complete retirement or disabled-package parity.

Before release, build and relocate each current artifact, run real empty-config
management/history/missing-provider cases without Node/Bun/credentials/network,
and separately run installed contribution flows with their declared dependencies.
Coding requires a real files/Shell/model/approval/cancel/history/recovery workflow.
Full must preserve the same policy for every optional package. SDK examples and
CLI/RPC/TUI diagnostics must be verified against the resulting artifacts.

Linux scoped evidence does not establish other platforms. Database upgrade is
forward-only through schema v28; restore requires the matching pre-upgrade DB and
all referenced artifact blobs. Plugin rollback only selects retained verified
code and cannot revive revoked authority. See [architecture](architecture.md#schema-v28-evolution-and-rollback-boundary)
and [Run context migration](run-context-migration.md) for unsupported-format and
recovery limits. Publication, CI and a full issue-completion claim are separate.
