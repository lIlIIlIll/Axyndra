package agent_plugin_registry

import std.collection.*
import std.convert.*
import std.fs.*

foreign func axyndra_registry_writer_acquire(directory: CString): Int64
foreign func axyndra_registry_reader_acquire(directory: CString): Int64
foreign func axyndra_registry_writer_validate(handle: Int64): Int32
foreign func axyndra_registry_writer_publication(handle: Int64, begin: Bool): Int32
foreign func axyndra_registry_writer_release(handle: Int64): Unit

class PluginRegistryWriteError <: Exception {
    let code: String
    init(code: String, message: String) { super(message); this.code = code }
}

func pluginRegistryNativeFailure(value: Int64): Unit {
    if (value >= 0) { return }
    let code = if (value == -11) { "plugin.registry_busy" }
        else if (value == -95) { "plugin.registry_platform_unsupported" }
        else if (value == -17) { "plugin.registry_recovery_required" }
        else { "plugin.registry_lock_failed" }
    throw PluginRegistryWriteError(code, "registry writer fence refused the operation, errno=" + (-value).toString())
}

// The only native handles are owned by one synchronous registry mutation.
// No caller callback runs while these handles or registryLock are held.
class PluginRegistryWriterFence {
    private let handles = ArrayList<Int64>()
    private var workspaceHandle: Int64 = -1
    private var closed = false
    private let shared: Bool

    init(settingsRoot: String, workspaceRoot: String, shared!: Bool = false) {
        this.shared = shared
        if (settingsRoot.trimAscii() == "" || settingsRoot.contains("\u{0000}") || workspaceRoot.contains("\u{0000}")) {
            throw PluginRegistryWriteError("plugin.registry_path_invalid", "registry paths must be identified and contain no NUL")
        }
        let user = settingsRoot + "/plugins"
        let workspace = if (workspaceRoot.trimAscii() == "") { "" } else { workspaceRoot + "/.axyndra/plugins" }
        let directories = if (workspace == "" || workspace == user) { [user] }
            else if (workspace < user) { [workspace, user] } else { [user, workspace] }
        try {
            for (directory in directories) {
                let handle = unsafe {
                    let raw = LibC.mallocCString(directory)
                    try { if (shared) { axyndra_registry_reader_acquire(raw) }
                        else { axyndra_registry_writer_acquire(raw) } } finally { LibC.free(raw) }
                }
                pluginRegistryNativeFailure(handle)
                handles.add(handle)
                if (directory == workspace) { workspaceHandle = handle }
            }
        } catch (error: Exception) { close(); throw error }
    }

    func validate(): Unit {
        if (closed) { throw PluginRegistryWriteError("plugin.registry_lock_closed", "registry writer fence is closed") }
        for (handle in handles) { pluginRegistryNativeFailure(Int64(unsafe { axyndra_registry_writer_validate(handle) })) }
    }

    func publication(begin: Bool): Unit {
        if (shared) { throw PluginRegistryWriteError("plugin.registry_read_only", "read fence cannot publish registry state") }
        validate()
        if (workspaceHandle < 0) { throw PluginRegistryWriteError("plugin.workspace_scope_missing", "workspace writer fence is unavailable") }
        pluginRegistryNativeFailure(Int64(unsafe { axyndra_registry_writer_publication(workspaceHandle, begin) }))
    }

    func close(): Unit {
        if (closed) { return }
        closed = true
        for (handle in handles) { unsafe { axyndra_registry_writer_release(handle) } }
        handles.clear()
    }
}

func pluginRegistryPublicationMarker(workspaceRoot: String): String {
    workspaceRoot + "/.axyndra/plugins/.registry-publication.pending"
}

func pluginRequireRegistryPublicationComplete(settingsRoot: String, workspaceRoot: String): Unit {
    if (workspaceRoot.trimAscii() == "") { return }
    let directory = workspaceRoot + "/.axyndra/plugins"
    if (!exists(Path(directory))) { return }
    pluginRequireWorkspaceStorage(workspaceRoot, workspaceRoot + "/.axyndra", directory)
    // Enumerating the entry also detects a dangling link. No pending record is
    // interpreted as authority and no automatic recovery rewrites either file.
    for (entry in Directory.readFrom(directory) where entry.name == ".registry-publication.pending" ||
        entry.name.startsWith("lock.jsonl.txn-")) {
        throw PluginRegistryWriteError("plugin.registry_recovery_required",
            "workspace registry publication was interrupted; preserve and review the lock/grant pair and backups")
    }
}
