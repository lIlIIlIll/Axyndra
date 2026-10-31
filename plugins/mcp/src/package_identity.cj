package mcp_client_plugin

import std.collection.*
import std.fs.*
import yjson.*
import yjson_support.*

// The executable's immutable package, not a peer-provided hello or ambient cwd,
// selects the endpoint identity. Operator-created independent package snapshots
// can share this binary without broadening accepted protocol identities.
func installedMcpPackageId(): String {
    let executable = canonicalize("/proc/self/exe")
    let manifest = executable.parent.parent.join("axyndra.plugin.json")
    let file = File(manifest, OpenMode.Read)
    let bytes = ArrayList<Byte>()
    let buffer = Array<Byte>(4096, repeat: 0)
    try {
        while (true) {
            let count = file.read(buffer)
            if (count <= 0) { break }
            require(bytes.size + count <= 65536, "mcp_plugin.package_identity_invalid")
            bytes.add(all: buffer[..count])
        }
    } finally { file.close() }
    let value = parseUnifiedJson(String.fromUtf8(bytes.toArray()), maxBytes: 65536, maxDepth: 16)
    let id = text(value, "id")
    require(id != "" && id.size <= 128 && text(value, "version") == "1.0.0" &&
        text(value, "entry_kind") == "native-executable" &&
        text(value, "entrypoint") == "bin/mcp-client-plugin", "mcp_plugin.package_identity_invalid")
    for (byte in id.toArray()) {
        require((byte >= b'a' && byte <= b'z') || (byte >= b'0' && byte <= b'9') ||
            byte == b'-' || byte == b'_', "mcp_plugin.package_identity_invalid")
    }
    id
}
