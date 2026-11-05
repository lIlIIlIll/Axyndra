package agent_host_runtime

import std.collection.*

// Fixed HTTP-only curl runs with a short, sandbox-owned HOME. Curl also
// prepares non-HTTP defaults; a long installed-package HOME can fail before
// any connection when those default paths exceed its bound. Neither
// this literal env assignment nor the executable is package-controlled. The
// original sandbox, network policy, CA bundle, limits and secrets stay intact.
func hostPluginHttpSandboxArguments(arguments: Array<String>): Array<String> {
    let values = ArrayList<String>(["HOME=/tmp", "/usr/bin/curl"])
    values.add(all: arguments)
    values.toArray()
}
