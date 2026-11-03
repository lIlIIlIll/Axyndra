# Installed execution freshness

This candidate adds a restrictive admission check to the existing Registry API
2.0 writer fence. It does not create a Run, permission, receipt, capability, or
second registry. Linux x86_64 is the supported native implementation. Other
platforms reject the new path; they are not counted as validated platforms.

The actual Product or Minimal host owns its existing PluginRegistry. Mounting an
installed package reloads the real metadata under the same ordered shared OS
locks used by management writers. Only that operation can create an execution
pin. Caller records and plugin JSON cannot create one. The mounted generation
uses the newly inspected installed record, not a caller's cached descriptor.

Each pin retains no-follow file descriptors, inode identity, and complete bytes
for both applicable lock files and the workspace grant. Memory is charged to the
existing bounded native owner pool before copying metadata. Every admission
checks the paths, retained descriptors, complete bytes, and pending-publication
marker while holding shared locks. A persistent marker, malformed data,
replacement, rewrite, or changed grant rejects the old generation. A transient
busy writer also rejects that attempt, without permanently invalidating a pin
whose metadata did not change. No modification-time-only cache is used.

The shared locks cover only actual canonical execution admission/handoff,
process creation, or one nonblocking physical stdin write of at most 4096 bytes.
Pipe readiness waits, plugin callbacks, HTTP responses, and worker replies are
outside that lock. The original source, approval, capability, budget, live-owner,
and Store guards still apply. HTTP and model process creation use their actual
retained host binding. Installed ordinary and managed Tool executors provide the
restriction at the same ToolPipeline admission points; derived children also
retain the actual canonical root executor's restriction.

If revocation follows a partial physical frame, remaining bytes are denied and
the existing worker cleanup path retains the real process until acknowledgement.
There is no fabricated successful request or receipt. Cancellation and close
control frames remain available for cleanup. An active short lease retains its
pin's snapshots until that lease actually closes, including concurrent pin close.

Compatibility and limits:

- Any relevant registry metadata publication conservatively invalidates the old
  pin, even if another namespace changed or disable/enable restored equal content.
  The host must remount from freshly inspected state; this candidate does not
  promise transparent hot reload or automatic replay.
- Ordinary unguarded process APIs retain their original implementations. A
  restricted legacy interactive process path explicitly refuses execution because
  it cannot fence each physical write. It cannot silently fall back to an
  unrestricted subprocess.
- Metadata uses the existing shared 128 MiB allocation pool, including its
  conservative expansion accounting and per-value ceiling. Large sets can be
  refused; no unbounded metadata retention or separate accounting is added.
- The writer candidate remains a prerequisite. Its uncertain workspace-publish
  recovery and complete original lock/grant backups are unchanged.

Authored verification, all pending real execution in this candidate:

- Registry units: retain the original 11 and add 8 pin/ABA/lease/metadata cases.
- Process units: 3 real-pipe cases check binary transfer, revocation after the first
  physical chunk, and a full pipe with no responding reader.
- Build both `support_tests/registry_process_contract` and
  `support_tests/registry_execution_contract`, then run the latter's `check.py`
  with `--library`, `--writer`, and `--worker` pointing to their fresh artifacts.
  Its 8 cases use actual OS processes, kernel locks, and installed Cangjie Registry
  objects. Missing prerequisites and unsupported platforms fail rather than skip.
- Product adds 4 tests with a still-running host and an independent Registry
  management object, covering native read-view execution, service writes, pending
  approval, HTTP request count, canonical handoff, and actual cleanup. These are
  separate objects in one process; the support tests supply process separation.
- Minimal still derives its full inventory from source: 19 Registry plus 4
  History cases. Its original nine CLI black-box cases are unchanged.

Source checks, patch inverse checks, and authored tests are not runtime passes.
Actual Product/Minimal/registry/process results and throughput remain pending.
