# Actual generic stdio ingress acceptance

After building the candidate App and independent MCP Server package:

```sh
python3 support_tests/plugin_ingress_blackbox/check.py \
  --app /absolute/packaged/app \
  --package /absolute/mcp-server-package \
  --evidence /absolute/new/evidence-directory
python3 libs/process4cj/native/test_borrowed_writer.py \
  --library /absolute/rebuilt/libprocess4cj_native.so
```

The App harness has nine required scenarios. It imports/enables the actual
package, writes an explicit operator grant in a fresh settings directory,
communicates over inherited pipes, then queries the actual SQLite ToolCall,
origin, handoff/Receipt and absence of fabricated model decisions. It also checks
approval refusal, typed IDs, active/queued cancellation with a later successful
call, full-pipe deadline, EOF interruption of a backpressured writer, closed
stdout and an empty export list. There is no fake Tool executor or authorizer.

The native test has five required real descriptor scenarios. It covers bounded
poll/write on a full pipe, original flag restoration without closing the caller
fd, SIGPIPE suppression with the default signal disposition, descriptor-number
reuse, and unsupported output rejection without mutation.

These harnesses do not build implicitly and require actual binaries; missing
fixtures never count as skips. The phase-5 candidate is uncompiled/unrun. The
existing SQLite External foundation contract additionally runs received-frame
v3 source binding, foreign/reused seal rejection, real handoff/Receipt and queued
cancellation. Run that full contract too; a package wire test cannot replace it.
