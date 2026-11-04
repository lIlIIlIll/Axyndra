package agent_host_runtime

import std.env.*
import std.fs.*

// This is Host-owned configuration capture, not a sandbox environment or a
// model-selected path. An explicit absolute parent is tried exactly once;
// creation failures keep their original error instead of falling back.
func hostConfigurationTemporaryParent204(environment: (String) -> ?String): String {
    for (name in ["TMPDIR", "TMP", "TEMP"]) {
        match (environment(name)) {
            case Some(value) => if (value != "" && Path(value).isAbsolute()) { return value }
            case None => ()
        }
    }
    "/tmp"
}

func hostConfigurationTemporaryDirectory204(): Path {
    Directory.createTemp(hostConfigurationTemporaryParent204({ name => getVariable(name) }))
}
