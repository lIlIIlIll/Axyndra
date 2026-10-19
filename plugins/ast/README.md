# Independent AST plugin

This package owns the `ast_grep` schema, pattern and path validation, structural
query execution, pagination, captures, diagnostics, hashline presentation, and
structural rewrite proposals. The product has no AST executor or default AST
registration. Editing uses the host's existing immutable file plans and approval.
The query checkpoint was version 1.0.0; version 1.1.0 adds the edit contribution
and file-plan protocol. Installed snapshots remain bound to their actual version
and content digest.

The plugin is an independently built Linux x86_64 native executable. Its managed
package contains both `bin/ast-plugin` and a pinned `bin/ast-grep`, with the
Cangjie runtime libraries needed by the executable. There is no dependency on a
registered Shell tool, a persistent shell, Node, or a system ast-grep installation.

## Build and install

Use the repository's pinned Cangjie SDK, Python 3, and `patchelf`. Supply the
ast-grep binary and MIT license identified by [engine.lock.json](engine.lock.json);
the packaging script verifies their exact SHA-256 values before building. It
does not download or execute an unpinned engine, install system dependencies, or
merge into an existing output directory.

```sh
bash plugins/ast/build-package.sh \
  --output /absolute/path/to/new-ast-package \
  --engine /absolute/path/to/ast-grep-0.45.3/ast-grep \
  --engine-license /absolute/path/to/ast-grep-0.45.3/LICENSE.ast-grep
python3 plugins/ast/check.py --package /absolute/path/to/new-ast-package
```

The resulting directory is the installable artifact. Its `package-provenance.json`
records engine, executable, and bundled library digests, and its `licenses/`
directory preserves the engine, runtime, and project licenses. Building this
package does not build the product application.

For executable contract gates, the repository also provides a pinned preparation
helper:

```sh
export AXYNDRA_AST_PLUGIN_PACKAGE="$(python3 scripts/prepare_ast_plugin.py)"
```

It downloads the exact engine and license when absent, verifies the cached or
downloaded bytes, builds a new package, runs its worker/protocol tests, and
prints only the resulting absolute package path on stdout. It requires Linux
x86_64, the pinned SDK/stdx and native build prerequisites, Python, and `patchelf`;
the first engine download needs network access. `vnext_contract_gate.py` and
`release_gate.sh` invoke this helper automatically and pass the package to the
Product contracts. A missing fixture fails preparation instead of skipping AST
coverage. This wiring alone does not establish that either entire gate passed.

In the running product:

```text
/plugins import /absolute/path/to/new-ast-package --scope workspace
/plugins enable axyndra:ast --scope workspace
```

Import creates a disabled content-locked snapshot. Enabling exposes
`plugin.axyndra:ast.ast_grep` and `plugin.axyndra:ast.ast_edit`. Query arguments are `pat` (required), `path`
(default `.`), and `skip` (default `0`). Paths may contain globs or semicolon
separated selections. For example:

```json
{"pat":"return $VALUE","path":"src/**/*.py","skip":0}
```

Results retain `content`, `match_count`, `visible_count`, `file_count`,
`limit_reached`, `scope_path`, `files`, `parse_errors`, and `matches`.
Pages contain at most 50 matches. Empty results are successful. Results exceeding
64 KiB fail explicitly; callers can narrow the pattern or path. Hashline tags use
the same pure normalization and display fingerprint as the host's file tools;
they are not authorization or integrity proofs.

Disable the package with `/plugins disable axyndra:ast --scope workspace`. New
query admission then stops; no built-in query fallback is installed.

## Preview and apply edits

The edit tool accepts non-empty `ops` and `paths` arrays, each with at most 32
entries. Each operation contains a non-empty `pat` and an `out` rewrite string:

```json
{"ops":[{"pat":"return $VALUE","out":"return changed"}],"paths":["src/**/*.py"]}
```

The worker runs the bundled engine without its write flag and reads the exact
original content. It rejects overlapping replacements, source changes during
preview, escaping paths, and proposals exceeding 32 files or 64 KiB. The limit
includes both original and replacement contents and JSON encoding; the complete
worker reply is also bounded to 64 KiB. This replaces the old editor's 1000-file
staging limit with an explicit bounded proposal contract. No files are modified.

For non-empty changes, the endpoint submits only schema and operations to
`file.plan.propose`. The host validates paths and preconditions, binds the actual
plugin origin, and stores a content-addressed plan. The result's
`application_plan` contains `plan_ref`, `plan_digest`, and the review preview.
Apply that exact pair through `apply_file_plan`; its separate workspace-write
authorization and one-time approval remain required. Each file is conditionally
published atomically; a multi-file plan is not one atomic transaction. Existing
partial/unknown outcomes and `recover_file_plan` retain their meaning.

An empty edit result needs no plan. To discard a proposal, leave it unapplied.
There is no plugin pending queue and no `xd://resolve` or `xd://reject` interface.

## Execution boundary

The protocol endpoint starts without workspace access. For a query it requests
the generic `process.readonly` service to run its own packaged executable with
`["--query-worker", "<canonical arguments JSON>"]`. The host binds that request
to the already admitted parent operation and to the immutable package snapshot.
The worker receives the approved workspace as its fixed current directory inside
a read-only sandbox with denied network, shared parent budget, deadline, and
cancellation. Each worker invocation produces a child Operation and Receipt.

Editing with actual matches uses a second read-only child to materialize the
plan. The parent and both children share a three-call budget and can execute
serially in one concurrent tool slot. The plugin never requests workspace-write
authority for preview or plan storage.

The host does not know the AST engine, pattern language, result schema, or
pagination algorithm. Worker arguments cannot choose system executables or the
working directory. The worker independently rejects lexical and symlink escapes,
caps selections, engine output and total match count, and treats engine or worker
truncation as failure. The engine executable comes from the same package snapshot.

The package declares `workspace.read` as a request; callers still need the host's
corresponding grant and extension-invocation authority. Native root calls retain
the host's conservative invocation approval policy, even though these workers
are read-only; that approval never authorizes a later file-plan write.
The supplied manifest is unsigned and follows the isolated
explicit-enable policy described in [the process protocol](../../docs/plugin-process-protocol.md).

The actual product integration passed for this query checkpoint:
`support_tests/product_thread_runtime_contract --ast-plugin-contract`, with
`AXYNDRA_AST_PLUGIN_PACKAGE` set to the packaged directory. It removes Shell and
any remaining AST edit registrations before testing installation, real queries,
pagination, denial, durable child receipts, and deactivation. The evidence log is
`phase2/product-thread-ast.log`; it records `independent AST plugin contract passed`.
This focused result does not imply that the complete Product, RPC, or release
gates passed; their outstanding results are recorded in the
[migration tracker](../../docs/plugin-first-migration.md).

Version 1.1.0 passed all 26 standalone worker/protocol tests and the actual
`support_tests/product_thread_runtime_contract --ast-edit-plugin-contract`
integration. That contract generates real immutable plans with two durable child
receipts, rejects a forged origin before Operation admission, reopens the same
state under the write approval policy, and verifies rejection, cancellation,
conflicting source content, recovery, and approved application. Its log is
`phase3/product-thread-ast-edit.log`, with the marker
`independent AST edit plugin contract passed`. The query contract was also rerun
successfully with 1.1.0 (`phase3/product-thread-ast-query.log`). The Linux x86_64
tar.gz was unpacked and all 26 tests passed again with executable modes preserved;
its SHA-256 is
`bec6a6d643f0ca4fff26b4466cda75da724e4520ef8b8aa759f1084a9a9b91d4`
(21,075,950 bytes; `phase3/ast-deliverable.json`). These results are separate from
the 1.0.0 query checkpoint. The final host checkpoint also passed all 102 Product
unit tests, the complete Product Thread, Product and RPC contracts, and a clean
check/application build on the recorded Linux toolchain. This does not establish
the full release, platform or performance matrix; see the migration tracker for
remaining issue scope and environment limits.
