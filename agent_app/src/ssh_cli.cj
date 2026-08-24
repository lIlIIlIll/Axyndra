package agent_app

import agent_domain.*
import agent_product.*
import model_adapters.*
import std.collection.*
import std.convert.*

func runSshCli(
    session: ApplicationSession,
    arguments: Array<String>
): Int64 {
    if (hasArgument(arguments, "--help") ||
        hasArgument(arguments, "-h")) {
        printSshHelp()
        return 0
    }
    match (sshParseError(arguments)) {
        case Some(message) =>
            eprintln("error: " + message)
            return 2
        case None => ()
    }
    let positionals = sshPositionals(arguments)
    let action = if (positionals.isEmpty()) {
        "list"
    } else {
        positionals[0]
    }
    if (action == "list") {
        return runSshList(
            session,
            hasArgument(arguments, "--json")
        )
    }
    let name = if (positionals.size > 1) {
        positionals[1]
    } else {
        ""
    }
    if (action == "add") {
        return runSshAdd(session, arguments, name)
    }
    if (action == "remove") {
        return runSshRemove(session, arguments, name)
    }
    println("Unknown action: " + action)
    println("Valid actions: add, remove, list")
    1
}

func printSshHelp(): Unit {
    println(
        "Manage SSH host configurations\n\n" +
        "USAGE\n" +
        "  $ axyndra ssh [ACTION] [TARGETS...] [FLAGS]\n\n" +
        "ARGUMENTS\n" +
        "  ACTION    SSH action (add|remove|list)\n" +
        "  TARGETS   Host name or arguments\n\n" +
        "FLAGS\n" +
        "      --json           Output JSON\n" +
        "      --host=<value>   Host address\n" +
        "      --user=<value>   Username\n" +
        "      --port=<value>   Port number\n" +
        "      --key=<value>    Identity key path\n" +
        "      --desc=<value>   Host description\n" +
        "      --compat         Enable compatibility mode\n" +
        "      --scope=<value>  Config scope (project|user)"
    )
}

func sshParseError(arguments: Array<String>): ?String {
    for (name in [
        "--host", "--user", "--port", "--key", "--desc", "--scope"
    ]) {
        if (hasArgument(arguments, name) &&
            argumentValue(arguments, name) == "") {
            return Some("Flag " + name + " expects a value")
        }
    }
    let scope = argumentValue(arguments, "--scope")
    if (scope != "" && scope != "project" && scope != "user") {
        return Some(
            "Expected --scope to be one of: project, user; got \"" +
                scope + "\""
        )
    }
    var skipNext = false
    var positionals: Int64 = 0
    for (argument in arguments) {
        if (skipNext) {
            skipNext = false
            continue
        }
        if (argument == "--host" || argument == "--user" ||
            argument == "--port" || argument == "--key" ||
            argument == "--desc" || argument == "--scope") {
            skipNext = true
            continue
        }
        if (argument == "--json" || argument == "--compat" ||
            argument == "--help" || argument == "-h" ||
            argument.startsWith("--host=") ||
            argument.startsWith("--user=") ||
            argument.startsWith("--port=") ||
            argument.startsWith("--key=") ||
            argument.startsWith("--desc=") ||
            argument.startsWith("--scope=")) {
            continue
        }
        if (argument.startsWith("-")) {
            return Some("Nonexistent flag: " + argument)
        }
        positionals += 1
        if (positionals > 2) {
            return Some("Unexpected argument: " + argument)
        }
    }
    None
}

func sshPositionals(arguments: Array<String>): Array<String> {
    let values = ArrayList<String>()
    var skipNext = false
    for (argument in arguments) {
        if (skipNext) {
            skipNext = false
            continue
        }
        if (argument == "--host" || argument == "--user" ||
            argument == "--port" || argument == "--key" ||
            argument == "--desc" || argument == "--scope") {
            skipNext = true
            continue
        }
        if (argument == "--json" || argument == "--compat" ||
            argument == "--help" || argument == "-h" ||
            argument.startsWith("--host=") ||
            argument.startsWith("--user=") ||
            argument.startsWith("--port=") ||
            argument.startsWith("--key=") ||
            argument.startsWith("--desc=") ||
            argument.startsWith("--scope=")) {
            continue
        }
        values.add(argument)
    }
    values.toArray()
}

func runSshList(
    session: ApplicationSession,
    json: Bool
): Int64 {
    let hosts = match (session.listSshHosts()) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            println("Error: " + error.message)
            return 1
    }
    if (json) {
        println(encodeAgentValue(objectValue([
            ValueField("project", sshHostMapValue(hosts.project)),
            ValueField("user", sshHostMapValue(hosts.user))
        ])))
        return 0
    }
    if (hosts.project.isEmpty() && hosts.user.isEmpty()) {
        println("No SSH hosts configured")
        println("Add one with: axyndra ssh add <name> --host <address>")
        return 0
    }
    if (!hosts.project.isEmpty()) {
        println("Project SSH Hosts (.axyndra/ssh.json):")
        printSshHosts(hosts.project)
    }
    if (!hosts.project.isEmpty() && !hosts.user.isEmpty()) {
        println("")
    }
    if (!hosts.user.isEmpty()) {
        println("User SSH Hosts (~/.axyndra/ssh.json):")
        printSshHosts(hosts.user)
    }
    0
}

func runSshAdd(
    session: ApplicationSession,
    arguments: Array<String>,
    name: String
): Int64 {
    if (name == "") {
        println("Error: Host name required")
        println(
            "Usage: axyndra ssh add <name> --host <address> " +
                "[--user <user>] [--port <port>] [--key <path>]"
        )
        return 1
    }
    let address = argumentValue(arguments, "--host")
    if (address == "") {
        println("Error: --host is required")
        println("Usage: axyndra ssh add <name> --host <address>")
        return 1
    }
    let authoredPort = argumentValue(arguments, "--port")
    var port: ?Int64 = None
    if (authoredPort != "") {
        let parsed = try {
            Int64.parse(authoredPort)
        } catch (_: Exception) {
            println(
                "Error: Port must be an integer between 1 and 65535"
            )
            return 1
        }
        if (parsed < 1 || parsed > 65535) {
            println(
                "Error: Port must be an integer between 1 and 65535"
            )
            return 1
        }
        port = Some(parsed)
    }
    let scope = sshScope(arguments)
    match (session.addSshHost(
        scope,
        ProductSshHost(
            name,
            address,
            username: argumentValue(arguments, "--user"),
            port: port,
            keyPath: argumentValue(arguments, "--key"),
            description: argumentValue(arguments, "--desc"),
            compat: hasArgument(arguments, "--compat")
        )
    )) {
        case Result.Ok(_) =>
            println(
                "Added SSH host \"" + name + "\" to " +
                    scope + " config"
            )
            0
        case Result.Err(error) =>
            println("Error: " + error.message)
            1
    }
}

func runSshRemove(
    session: ApplicationSession,
    arguments: Array<String>,
    name: String
): Int64 {
    if (name == "") {
        println("Error: Host name required")
        println(
            "Usage: axyndra ssh remove <name> " +
                "[--scope project|user]"
        )
        return 1
    }
    let scope = sshScope(arguments)
    match (session.removeSshHost(scope, name)) {
        case Result.Ok(_) =>
            println(
                "Removed SSH host \"" + name + "\" from " +
                    scope + " config"
            )
            0
        case Result.Err(error) =>
            println("Error: " + error.message)
            1
    }
}

func sshScope(arguments: Array<String>): String {
    let value = argumentValue(arguments, "--scope")
    if (value == "") { "project" } else { value }
}

func sshHostMapValue(hosts: Array<ProductSshHost>): AgentValue {
    let values = ArrayList<ValueField>()
    for (host in hosts) {
        let fields = ArrayList<ValueField>()
        fields.add(ValueField("host", textValue(host.host)))
        if (host.username != "") {
            fields.add(ValueField(
                "username",
                textValue(host.username)
            ))
        }
        match (host.port) {
            case Some(value) =>
                fields.add(ValueField("port", integerValue(value)))
            case None => ()
        }
        if (host.keyPath != "") {
            fields.add(ValueField(
                "keyPath",
                textValue(host.keyPath)
            ))
        }
        if (host.description != "") {
            fields.add(ValueField(
                "description",
                textValue(host.description)
            ))
        }
        if (host.compat) {
            fields.add(ValueField("compat", boolValue(true)))
        }
        values.add(ValueField(
            host.name,
            objectValue(fields.toArray())
        ))
    }
    objectValue(values.toArray())
}

func printSshHosts(hosts: Array<ProductSshHost>): Unit {
    for (host in hosts) {
        var line = "  " + host.name + "  " + host.host
        if (host.username != "") {
            line += "  " + host.username
        }
        match (host.port) {
            case Some(value) =>
                if (value != 22) {
                    line += "  port:" + value.toString()
                }
            case None => ()
        }
        if (host.keyPath != "") {
            line += "  " + host.keyPath
        }
        if (host.description != "") {
            line += "  - " + host.description
        }
        println(line)
    }
}
