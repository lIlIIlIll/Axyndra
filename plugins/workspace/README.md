# Workspace native plugin (candidate 1.0.0)

This independently built Linux x86_64 package implements workspace file reads,
hashline formatting and patch parsing, ripgrep search/globs, and immutable file
change proposals. It links generic value/hash/JSON/process libraries and has no
Product, SDK business extension, or Tool Runtime dependency. The host registers
five names from the installed package: `plugin.axyndra:workspace.read`, `grep`,
`glob`, `edit`, and `write` (with the same namespace prefix for each).

No production replacement has been applied or validated yet. Old Workspace
tools remain installed by default. This candidate is not completion of A4-01.

## Process and write authority

The endpoint prepares a package-relative worker request and resource paths without
reading them. The host expands and classifies metadata, freezes exact file
identities and the operator configuration digest, and obtains any required
approval. During actual canonical execution, `process.readview` accepts only
`{intent_id}`. Its durable ParentIntent child rechecks authorization and object
identity, copies approved regular files through link-free verified handles, and
mounts only that private snapshot and the installed package for
`bin/workspace-plugin --view-worker <tool> <json>`. The original workspace is not
mounted; cwd is the snapshot, ambient environment is not inherited, and network is denied.

Read/hashline/search/edit algorithms remain in this package. The worker resolves
its pinned `bin/rg` beside itself. It never invokes a Shell Tool or chooses a
search engine from ambient PATH. The host primitive only enumerates metadata,
copies authorized bytes, and supervises the bounded isolated process. It does
not interpret grep patterns, hashline edits or business results. Directory
views exclude sensitive names, Product state/settings roots, and internal
`.axyndra`, `.git`, `.hg`, `.svn`, credential and key directories independently
of plugin glob flags. Explicit special files require approval; special directory
walks are rejected. Every symlink, magic link, hard-linked regular file and
non-regular object is rejected or excluded before content is read.

`edit` reads the current files, validates full-file hashline tags and overlapping
line operations, and creates whole-file `replace` proposals containing exact
`expected_content`. `write` proposes `create` or `replace`; it does not overwrite
files immediately. The endpoint sends only `{proposal}` to `file.plan.propose`.
The host creates the immutable v2 artifact with the actual parent and generating
Operation provenance. The result contains `application_plan.plan_ref` and
`plan_digest`; call the existing `apply_file_plan` to review and approve those
exact bytes. Existing host CAS/preflight and atomic application remain the only
write authority. Rejecting or leaving a plan unapplied changes no workspace file.
Identical content returns `changed:false,applied:false` without a plan.

Read/search uses two shared tool calls (parent + read-only process); a changed
edit/write proposal needs three (parent + process + file-plan service). Each uses
the same single parent tool slot serially. Two distinct receipts, exact identity
correlation and matching request IDs are required before returning a plan.
Cancellation clears the pending invocation; a late reply or reused invocation ID
cannot complete another call. A failed or truncated worker never produces a plan.
`settings/plugins/services.json` can contain an operator `tool_read_grants` entry
for an exact ordinary Tool name, package digest and `process.readview` service.
This is separate from dynamic Service `read_only_tools`. Only that host grant
makes an ordinary non-special resource view ReadOnly under AlwaysAsk. Sensitive,
temp and outside files keep explicit one-time approval. Ungranted contributions
still require the original broad WorkspaceRead capability for the existing
`file.plan.propose` path; a read grant cannot invoke that path or upgrade a narrow
read capability. Applying a plan still requires independent write authority.

Write mode currently prompts on ExtensionInvoke even with an operator read
grant. The candidate tests that conservative behavior and does not claim parity
with the former built-in Read policy in that mode. The product's separate
`allow_workspace_writes` default may allow low-risk writes; it does not grant
sensitive reads or native extension execution. See [read views](../../docs/plugin-read-views.md).

## Inputs and retained behavior

* `read`: `path`, optional `offset`/`limit` (positive lines; null keeps defaults).
  Default 2,000 lines, maximum 10,000. `:L2-L4`, `:L2+3`, `:L2`, and `:raw`
  retain their existing meanings. Every formatted range uses the hash of the
  complete file, not the returned range. Directory entries are sorted, folders
  end in `/`, and at most 2,000 entries are retained.
* `grep`: `pattern`, optional `path` (semicolon-separated literal paths or glob
  selectors), `case` (false by default), `count`, `gitignore` (true), `skip`.
  Regex matching, stable path order and up to 1,000 matched lines are retained.
  Count mode returns per-file counts and total; as in the old implementation,
  `skip` affects line mode only. The engine receives argv directly and `--no-config`.
  Count results now cap the file list at 1,000 while retaining the full total;
  `truncated` means omitted files. This fixes the old unbounded count list and
  its false truncation flag at exactly 1,000 files.
* `glob`: `pattern`, optional `hidden`, `gitignore`, positive `limit` clamped to
  200. Selection follows the pinned ripgrep engine's glob/ignore semantics:
  positive explicit glob matches override ignore and hidden filtering, as with
  the former Product argv. Use `pattern:"."` for normal ignore-based discovery.
* `edit`: `input` with `[path#TAG]` sections and `SWAP N:`/`SWAP N..=M:`,
  `DEL N`/`DEL N..=M`, `INS.HEAD:`, `INS.TAIL:`, `INS.PRE N:`, `INS.POST N:`.
  Bodies use `+` lines. Stale anchors, overlapping operations, missing lines,
  duplicate/aliased targets and malformed syntax are rejected before proposing.
* `write`: `path`, `content` (UTF-8, including empty content). Parent directory
  must already exist. This deliberately changes immediate-write behavior into a
  reviewed immutable plan; consumers must call `apply_file_plan` explicitly.

## Bounds and open compatibility gaps

Input JSON is at most 16 KiB. Result and complete proposal JSON are at most
64 KiB, and protocol frames at most 256 KiB. JSON escaping counts towards these
limits. Read pages shrink on UTF-8 boundaries to fit; a large search result or
edit proposal returns an explicit limit error. Whole-file reads are bounded at
16 MiB; rg output at 16 MiB before rendering, with a 15-second deadline. These
bounds are smaller than the former 1 MiB read pages and unbounded full-file read.
Edit/write snapshots are individually capped at 64 KiB before constructing a
proposal, and edit rejects more than 32 sections before reading any of them.
Larger payloads need a generic immutable payload service, not silent truncation
of edits. Service-only capacity profiles do not enlarge these ordinary Tool
limits. At most 32 changed files fit a proposal, subject to its total byte bound.

Workspace paths and explicit individually authorized outside/temp/sensitive
regular-file reads are implemented by this candidate. They preserve the
original authored path in read results and hashline headers. URI/Blob reads,
artifact export, remote writes, special directory traversal, symlinks/hardlinks,
and full legacy large-payload behavior remain unavailable here; old Product
entries remain installed. Read views contain at most 1,024 resource entries,
16 MiB of total source bytes, and depth 32. Search currently requests one bounded
workspace snapshot, so large workspaces must use the retained old path until
bounded selection/payload parity is implemented. New files appearing after
preparation do not enter an already-frozen view. Existing selected files must
retain their frozen object identity and metadata at actual copy time.

The old Product Server was separately observed to return an entire 1 MiB `:raw`
read; its old write schema permits 32 KiB. This package still has the smaller
16 KiB input and 64 KiB result/proposal limits above. It has not gained those
legacy capacities merely because Service payload profiles exist.

## Build and validation

The package pins the official ripgrep 15.2.0 musl archive by SHA-256, then checks
the extracted binary and licenses independently. `engine.lock.json` records the
official GitHub URL and all hashes. The MIT license, COPYING notice and alternative
UNLICENSE are included, along with Axyndra and Cangjie runtime notices.

With the repository's pinned Cangjie SDK/stdx, native process bridge and
`patchelf` available on Linux:

```sh
python3 scripts/prepare_workspace_plugin.py
# Or supply already verified engine files:
plugins/workspace/build-package.sh --output /new/package \
  --engine /pinned/rg --engine-license /pinned/LICENSE-MIT
python3 plugins/workspace/check.py --package /new/package
export AXYNDRA_WORKSPACE_PLUGIN_PACKAGE=/new/package
export AXYNDRA_READ_VIEW_PLUGIN_FIXTURE="$PWD/support_tests/read_view_fixture/main.py"
# Include plugin_workspace_test.cj (3 cases) and plugin_read_view_test.cj
# (9 cases) in the coordinated Product unit inventory. The independent
# package check contains 34 actual process cases; no zero-match PASS is valid.
```

The package process tests run with SDK environment variables removed. Product
tests import the actual package, remove static read/grep/glob/edit/write and Shell
registrations, inspect real Direct/Committed child receipts, and test durable
hashline plan approval, rejection, cancellation, restart and multi-file CAS.
None of these candidate tests has been compiled or executed yet.
