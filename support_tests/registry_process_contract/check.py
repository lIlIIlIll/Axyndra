#!/usr/bin/env python3
"""Actual Linux kernel/registry process contracts; no in-memory lock substitute.

Requires the already-built production native library and Cangjie helper. Does
not compile, create a WSL process, or accept absent prerequisites as a skip.
"""
import argparse
import ctypes
import errno
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import tempfile
import time
import unittest


def native(path):
    lib = ctypes.CDLL(str(path))
    lib.axyndra_registry_writer_acquire.argtypes = [ctypes.c_char_p]
    lib.axyndra_registry_writer_acquire.restype = ctypes.c_int64
    lib.axyndra_registry_writer_validate.argtypes = [ctypes.c_int64]
    lib.axyndra_registry_writer_validate.restype = ctypes.c_int32
    lib.axyndra_registry_writer_publication.argtypes = [ctypes.c_int64, ctypes.c_bool]
    lib.axyndra_registry_writer_publication.restype = ctypes.c_int32
    lib.axyndra_registry_writer_release.argtypes = [ctypes.c_int64]
    lib.axyndra_registry_writer_release.restype = None
    return lib


def hold(library, directory, mode):
    lib = native(library)
    held = lib.axyndra_registry_writer_acquire(os.fsencode(directory))
    if held <= 0:
        raise RuntimeError(f"acquire failed {held}")
    if mode == "pending":
        if lib.axyndra_registry_writer_publication(held, True) != 0:
            raise RuntimeError("cannot begin publication")
    if mode == "exec":
        os.execv(sys.executable, [sys.executable, "-c", "print('EXEC',flush=True); input()"])
    print("HELD", flush=True)
    try:
        sys.stdin.buffer.read(1)
    finally:
        lib.axyndra_registry_writer_release(held)


class RegistryProcesses(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="axyndra-registry-process-")
        self.root = Path(self.temp.name)
        self.children = []
        self.lib = native(OPTIONS.library)

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.kill()
            child.communicate(timeout=5)
        self.temp.cleanup()

    def spawn_hold(self, directory, mode="plain"):
        child = subprocess.Popen([sys.executable, __file__, "--hold", OPTIONS.library,
                                  str(directory), mode], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.children.append(child)
        import select
        self.assertTrue(select.select([child.stdout], [], [], 5)[0], "real holder did not become ready")
        self.assertEqual(child.stdout.readline().strip(), b"EXEC" if mode == "exec" else b"HELD")
        return child

    def acquire(self, directory):
        return self.lib.axyndra_registry_writer_acquire(os.fsencode(directory))

    def package(self, name, version):
        source = self.root / f"{name}-{version}"
        (source / "extensions").mkdir(parents=True)
        (source / "package.json").write_text(json.dumps({"name": name, "version": version,
                                                         "pi": {"extensions": ["extensions/index.js"]}}))
        (source / "extensions/index.js").write_text("throw new Error('MANAGEMENT_MUST_NOT_EXECUTE');")
        return source

    def worker(self, mode, source="", namespace="", settings=None, workspace=None):
        gate = self.root / f"gate-{len(self.children)}"
        environment = dict(os.environ, PATH="/no-runtime-is-installed-here")
        child = subprocess.Popen([OPTIONS.worker, str(settings or self.root / "settings"),
                                  str(workspace or self.root), str(gate), mode, str(source), namespace],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
        self.children.append(child)
        deadline = time.monotonic() + 10
        while not Path(str(gate) + ".ready").exists():
            self.assertIsNone(child.poll(), "actual Cangjie registry worker exited before READY")
            self.assertLess(time.monotonic(), deadline, "actual Cangjie worker readiness timed out")
            time.sleep(0.005)
        return child, gate

    def run_worker(self, pair, expected=0):
        child, gate = pair
        Path(str(gate) + ".go").write_text("go")
        output, error = child.communicate(timeout=15)
        self.assertEqual(child.returncode, expected, (output[:1024], error[:1024]))
        self.assertLess(len(output), 4096)
        return output.decode().strip()

    def test_kernel_exclusion_kill_release_retains_stable_inode(self):
        directory = self.root / "state"
        child = self.spawn_hold(directory)
        identity = (directory / ".registry-writer.lock").stat().st_ino
        self.assertEqual(self.acquire(directory), -errno.EAGAIN)
        child.send_signal(signal.SIGKILL); child.wait(timeout=5)
        handle = self.acquire(directory)
        self.assertGreater(handle, 0)
        try:
            self.assertEqual(self.lib.axyndra_registry_writer_validate(handle), 0)
            self.assertEqual((directory / ".registry-writer.lock").stat().st_ino, identity)
        finally:
            self.lib.axyndra_registry_writer_release(handle)

    def test_exec_does_not_inherit_writer_ownership(self):
        directory = self.root / "state"
        child = self.spawn_hold(directory, "exec")
        self.assertIsNone(child.poll())
        handle = self.acquire(directory)
        self.assertGreater(handle, 0)
        self.lib.axyndra_registry_writer_release(handle)

    def test_symlink_parent_lock_fifo_and_hardlink_are_rejected(self):
        external = self.root / "outside"; external.mkdir()
        link = self.root / "linked"; link.symlink_to(external, target_is_directory=True)
        self.assertLess(self.acquire(link / "plugins"), 0)
        self.assertFalse((external / "plugins").exists())
        for kind in ["symlink", "fifo", "hardlink"]:
            directory = self.root / kind; directory.mkdir()
            lock = directory / ".registry-writer.lock"
            target = external / kind; target.write_text("preserve")
            if kind == "symlink": lock.symlink_to(target)
            elif kind == "fifo": os.mkfifo(lock)
            else: os.link(target, lock)
            self.assertLess(self.acquire(directory), 0)
            self.assertEqual(target.read_text(), "preserve")

    def test_inode_replacement_invalidates_held_fence(self):
        directory = self.root / "state"
        handle = self.acquire(directory); self.assertGreater(handle, 0)
        try:
            lock = directory / ".registry-writer.lock"
            lock.rename(directory / "retained-old-lock")
            lock.write_text("")
            self.assertEqual(self.lib.axyndra_registry_writer_validate(handle), -errno.ESTALE)
        finally:
            self.lib.axyndra_registry_writer_release(handle)

    def test_crash_pending_marker_refuses_real_registry_mutation(self):
        directory = self.root / ".axyndra/plugins"
        child = self.spawn_hold(directory, "pending")
        child.kill(); child.wait(timeout=5)
        marker = directory / ".registry-publication.pending"
        before = marker.read_bytes()
        output = self.run_worker(self.worker("import", self.package("interrupted", "1.0.0")), expected=2)
        self.assertEqual(output, "plugin.registry_recovery_required")
        self.assertEqual(marker.read_bytes(), before)
        self.assertFalse((self.root / "settings/plugins/lock.jsonl").exists())

    def test_two_actual_stale_registries_preserve_distinct_imports(self):
        first = self.worker("import", self.package("first", "1.0.0"))
        second = self.worker("import", self.package("second", "1.0.0"))
        self.run_worker(first); self.run_worker(second)
        rows = [json.loads(line) for line in (self.root / "settings/plugins/lock.jsonl").read_text().splitlines()]
        self.assertEqual({row["id"] for row in rows}, {"first", "second"})
        self.assertEqual(len(rows), 2)

    def test_actual_stale_update_and_gc_keep_new_generation_and_history(self):
        # Both workers deliberately hold their old empty in-memory registry.
        first = self.worker("import", self.package("versions", "1.0.0"))
        update = self.worker("update", self.package("versions", "2.0.0"), "versions")
        gc = self.worker("gc")
        self.run_worker(first); self.run_worker(update); self.run_worker(gc)
        rows = [json.loads(line) for line in (self.root / "settings/plugins/lock.jsonl").read_text().splitlines()]
        self.assertEqual(len(rows), 2)
        self.assertEqual({row["version"] for row in rows}, {"1.0.0", "2.0.0"})
        self.assertEqual([row["version"] for row in rows if "history_for" not in row], ["2.0.0"])
        self.assertTrue(all(Path(row["root"]).is_dir() for row in rows))

    def test_same_workspace_different_settings_cannot_publish_while_locked(self):
        directory = self.root / ".axyndra/plugins"
        holder = self.spawn_hold(directory)
        source = self.package("shared-workspace", "1.0.0")
        one = self.worker("workspace", source, settings=self.root / "settings-one")
        two = self.worker("workspace", source, settings=self.root / "settings-two")
        self.assertEqual(self.run_worker(one, expected=2), "plugin.registry_busy")
        self.assertEqual(self.run_worker(two, expected=2), "plugin.registry_busy")
        self.assertFalse((directory / "lock.jsonl").exists())
        holder.kill(); holder.wait(timeout=5)
        self.run_worker(self.worker("workspace", source, settings=self.root / "settings-one"))
        self.assertFalse((directory / ".registry-publication.pending").exists())


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "--hold":
        hold(*sys.argv[2:]); sys.exit(0)
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--worker", required=True)
    OPTIONS = parser.parse_args()
    if platform.system() != "Linux" or platform.machine() not in {"x86_64", "AMD64"}:
        parser.error("actual contract requires supported Linux x86_64; no skip counts as PASS")
    for name in ["library", "worker"]:
        setattr(OPTIONS, name, str(Path(getattr(OPTIONS, name)).resolve(strict=True)))
    unittest.main(argv=[sys.argv[0]], verbosity=2)
