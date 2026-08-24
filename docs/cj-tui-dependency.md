# Vendored cjtui dependency

Axyndra builds against the repository-local packages under
`vendor/cj_tui/packages/{core,markdown,cj_markdown}`. A sibling checkout is not
required for clean-clone builds.

The imported source is recorded in `vendor/cj_tui/PROVENANCE.json`:

- upstream: `git@github-liliilill:lIlIIlIll/cjtui.git`;
- commit: `ab76bc1b39ed3a9261487beb71b4d1967accc2a2`;
- root tree: `169d78a775b7f2035c345625ca543aa214fed19f`;
- included package trees and the generated API-contract blob are pinned;
- a canonical SHA-256 manifest covers all 60 vendored files.

`scripts/check_cjtui_contract.py` verifies the provenance manifest, package
versions, and `vendor/cj_tui/docs/api-contract-v1.txt` digest. `CJ_TUI_ROOT` remains available
for intentional compatibility checks against another checkout, but production
manifests always consume the vendored copy.

The upstream snapshot contains no `LICENSE`, `COPYING`, or `NOTICE` file. This
is an unresolved publication/legal risk: obtain and add an explicit upstream
license before distributing Axyndra outside the repository owner's scope.
