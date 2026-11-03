package agent_app

import std.fs.*

// Bundled defaults belong to this installed executable, never to cwd or a
// plugin supplied path. A Minimal package has no neighboring distribution.
func bundledProductDistributionRoot(): String {
    try {
        let executable = canonicalize(Path("/proc/self/exe"))
        let root = executable.parent.parent.join("share/axyndra")
        let manifest = root.join("distribution.json")
        if (exists(manifest) || FileInfo(manifest).isSymbolicLink()) { return root.toString() }
        ""
    } catch (_: Exception) { "" }
}
