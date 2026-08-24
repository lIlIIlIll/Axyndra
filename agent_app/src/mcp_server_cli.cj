package agent_app

import agent_domain.*
import agent_mcp.*
import agent_product.*
import std.collection.*

func runMcpServerCli(
    product: ProductRuntime,
    arguments: Array<String>
): Int64 {
    if (hasArgument(arguments, "--help") || hasArgument(arguments, "-h")) {
        println(
            "axyndra mcp-server [--allow-workspace-write] [--allow-process] " +
                "[--allow-network] [--allow-extension] [--allow-delegate]"
        )
        let _ = product.close()
        return 0
    }
    match (mcpServerArgumentError(arguments)) {
        case Some(message) =>
            eprintln("mcp-server.invalid_arguments: " + message)
            let _ = product.close()
            return 2
        case None => ()
    }
    let options = ProductMcpServerOptions(
        product.ids.nextSessionId(),
        CapabilitySet(values: mcpServerCapabilities(arguments)),
        instructions: "axyndra product tools; host capability and approval policy remain authoritative"
    )
    let result = StdioMcpServer(product.mcpServer(options)).serveConsole()
    let _ = product.close()
    match (result) {
        case Result.Ok(_) => 0
        case Result.Err(error) =>
            // stdout is protocol-only while serving.  After the stream closes,
            // a concise terminal diagnostic is sufficient for the process exit.
            eprintln(error.describe())
            1
    }
}

func mcpServerCapabilities(arguments: Array<String>): Array<Capability> {
    let values = ArrayList<Capability>()
    // Workspace reads are the only ambient authority of the stdio server.
    // Every side-effect or delegation boundary is an independent CLI opt-in.
    values.add(Capability(CapabilityKind.WorkspaceRead))
    if (hasArgument(arguments, "--allow-workspace-write")) {
        values.add(Capability(CapabilityKind.WorkspaceWrite))
    }
    if (hasArgument(arguments, "--allow-process")) {
        values.add(Capability(CapabilityKind.ProcessSpawn))
    }
    if (hasArgument(arguments, "--allow-network")) {
        values.add(Capability(CapabilityKind.NetworkAccess))
    }
    if (hasArgument(arguments, "--allow-extension")) {
        values.add(Capability(CapabilityKind.ExtensionInvoke))
    }
    if (hasArgument(arguments, "--allow-delegate")) {
        values.add(Capability(CapabilityKind.Delegate))
    }
    values.toArray()
}

func mcpServerArgumentError(arguments: Array<String>): ?String {
    for (argument in arguments) {
        if (argument == "--allow-workspace-write" ||
            argument == "--allow-process" ||
            argument == "--allow-network" ||
            argument == "--allow-extension" ||
            argument == "--allow-delegate") {
            continue
        }
        return Some("unexpected argument: " + argument)
    }
    None
}
