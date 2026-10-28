package agent_extension_runtime

import std.collection.*
import std.fs.*
import agent_domain.*

class PluginPackageDigestWorkEntry {
    let relativePath: String
    let size: Int64
    let executable: Bool
    var digest: String = ""
    init(relativePath: String, size: Int64, executable: Bool) {
        this.relativePath = relativePath; this.size = size; this.executable = executable
    }
}

func pluginAppendTreeDigestEntry(payload: StringBuilder, relativePath: String,
    executable: Bool, size: Int64, fileDigest: String): Unit {
    payload.append(relativePath.size.toString()); payload.append(":")
    payload.append(relativePath); payload.append(":")
    payload.append(executable.toString()); payload.append(":")
    payload.append(size.toString()); payload.append(":")
    payload.append(fileDigest); payload.append("\n")
}

// One inspection owns one additional worker, never a cache or background pool.
// Its payer remains owned by the caller until this entire helper has returned.
func pluginParallelContentDigest(root: String, paths: ArrayList<String>, largestPath: String,
    accounting: PluginPackageMetadataAccounting): PluginPackageResult<String> {
    // Per-file retained results/preflight records, one 64 KiB worker scratch,
    // and 8 KiB Future/control. The original scratch belongs to the base frame.
    // Refusal occurs before constructing any of these working objects.
    accounting.beforeDigestWork(paths.size * 1024 + 65536 + 8192)
    let entries = ArrayList<PluginPackageDigestWorkEntry>()
    var verifiedBytes: Int64 = 0
    var selected: Int64 = -1
    // Bound the complete current byte volume before starting either reader.
    // Each reader still enforces this recorded size and all path/type checks.
    for (relativePath in paths) {
        let info = try { FileInfo(Path(root).join(relativePath)) } catch (error: Exception) {
            return pluginPackageError("plugin.package_tree_unreadable", error.message, source: root, field: relativePath)
        }
        if (!info.isRegular() || info.isSymbolicLink()) {
            return pluginPackageError("plugin.package_tree_changed",
                "package file changed while its content digest was being computed", source: root, field: relativePath)
        }
        if (info.size < 0 || info.size > 268435456 - verifiedBytes) {
            return pluginPackageError("plugin.package_tree_limit",
                "package contents exceed the 256 MiB digest limit", source: root, field: relativePath)
        }
        verifiedBytes += info.size
        if (relativePath == largestPath) { selected = entries.size }
        entries.add(PluginPackageDigestWorkEntry(relativePath, info.size, info.canExecute()))
    }
    if (selected < 0) {
        return pluginPackageError("plugin.package_tree_changed", "package file disappeared during verification", source: root)
    }
    let selectedEntry = entries[selected]
    // Capture immutable file facts only, not the payer, state owner or result
    // container. Only this parent writes entries, after the worker has joined.
    let workerPath = selectedEntry.relativePath
    let workerSize = selectedEntry.size
    let workerExecutable = selectedEntry.executable
    let digestScratch = Array<Byte>(65536, repeat: 0)
    let worker = spawn {
        pluginPackageDigestWorkRead(root, workerPath, workerSize, workerExecutable,
            Array<Byte>(65536, repeat: 0))
    }
    var workerDigest: ?PluginPackageResult<String> = None
    try {
        for (index in 0..entries.size) {
            if (index == selected) { continue }
            let entry = entries[index]
            match (pluginPackageDigestWorkRead(root, entry.relativePath, entry.size, entry.executable, digestScratch)) {
                case PluginPackageResult.Ok(value) => entry.digest = value
                case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
            }
        }
    } finally {
        // Also join on an ordinary-file failure or exception. No return can
        // release the inspection owner while its worker still reads bytes.
        workerDigest = Some(worker.get())
    }
    match (workerDigest.getOrThrow()) {
        case PluginPackageResult.Ok(value) => selectedEntry.digest = value
        case PluginPackageResult.Err(error) => return PluginPackageResult.Err(error)
    }
    let payload = StringBuilder()
    payload.append("axyndra-package-tree-v2\n")
    for (entry in entries) {
        pluginAppendTreeDigestEntry(payload, entry.relativePath, entry.executable, entry.size, entry.digest)
    }
    PluginPackageResult.Ok("sha256:" + modelPolicySha256Text(payload.toString()))
}

func pluginPackageDigestWorkRead(root: String, relativePath: String, expectedSize: Int64,
    executable: Bool, scratch: Array<Byte>): PluginPackageResult<String> {
    let path = Path(root).join(relativePath)
    let before = try { FileInfo(path) } catch (_: Exception) {
        return pluginPackageError("plugin.package_tree_changed", "package file disappeared during verification", source: root, field: relativePath)
    }
    if (!before.isRegular() || before.isSymbolicLink() || before.size != expectedSize || before.canExecute() != executable) {
        return pluginPackageError("plugin.package_tree_changed", "package file metadata changed during verification", source: root, field: relativePath)
    }
    let digest = try { pluginPackageFileDigest(path, expectedSize, root, scratch) } catch (_: Exception) {
        return pluginPackageError("plugin.package_tree_changed",
            "package file changed or could not be read within its recorded size", source: root, field: relativePath)
    }
    let after = try { FileInfo(path) } catch (_: Exception) {
        return pluginPackageError("plugin.package_tree_changed", "package file disappeared during verification", source: root, field: relativePath)
    }
    if (!after.isRegular() || after.isSymbolicLink() || after.size != expectedSize || after.canExecute() != executable) {
        return pluginPackageError("plugin.package_tree_changed", "package file metadata changed during verification", source: root, field: relativePath)
    }
    PluginPackageResult.Ok(digest)
}
