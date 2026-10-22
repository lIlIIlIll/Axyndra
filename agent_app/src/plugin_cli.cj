package agent_app

import agent_cli.*
import agent_domain.*
import agent_product.*
import std.collection.*
import std.env.*
import yjson.*
import yjson_support.*

func printPluginHelp(io!: CliIo180 = consoleCliIo180): Unit {
    io.println("axyndra plugin list [--json]\n" +
        "axyndra plugin inspect <path> [--json]\n" +
        "axyndra plugin import <path> [--scope user|workspace]\n" +
        "axyndra plugin update <id> <path> [--scope user|workspace]\n" +
        "axyndra plugin enable|disable|rollback|uninstall <id> [--scope user|workspace]\n" +
        "axyndra plugin doctor\n" +
        "axyndra plugin gc\n" +
        "axyndra plugin serve <operator-grant-id>\n" +
        "axyndra plugin commands [--json]\n" +
        "axyndra plugin views [--json]\n" +
        "axyndra plugin command <route> [one argument string]\n\n" +
        "Local package maintenance does not require a model provider. Import leaves a package disabled.\n" +
        "HTTP capabilities still require explicit operator configuration and normal tool policy.\n" +
        "Git/npm acquisition requires the interactive /plugins import or /plugins update command;\n" +
        "this CLI does not turn a request to download into an approval decision.")
}

func pluginCliUsage(message: String, io!: CliIo180 = consoleCliIo180): Int64 {
    printError(AgentError(AgentErrorKind.InvalidInput, "plugin.cli_usage", message), io: io)
    io.println("Run `axyndra plugin --help` for usage.")
    2
}

func pluginCliError(error: PluginRegistryOwnedError, io!: CliIo180 = consoleCliIo180): Int64 {
    appRegistryCliPrintError83r(error, io: io)
}

func pluginCliScope(scope: PluginInstallScope): String {
    match (scope) { case PluginInstallScope.User => "user"; case PluginInstallScope.Workspace => "workspace" }
}

func pluginCliRecordResult(result: PluginRegistryResult<ProductPluginRecord>, action: String, io!: CliIo180 = consoleCliIo180): Int64 {
    match (result) {
        case PluginRegistryResult.Err(error) => try { pluginCliError(error, io: io) } finally { error.close() }
        case PluginRegistryResult.Ok(record) => appRegistryCliPrintRecord83r(record, action, io: io)
    }
}

// Reuse the existing inspect renderer without adding a runtime-package import
// to this maintenance client. The constant command is reparsed with each argv
// element quoted and round-tripped; no input can become a model prompt or a
// second command. All mutating actions below call the public maintenance API.
func pluginCliInspect(session: ApplicationSession, arguments: Array<String>, io!: CliIo180 = consoleCliIo180): Int64 {
    var command = "/plugins"
    for (argument in arguments) {
        command += " \"" + argument.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
    }
    let parsed = match (parseCommandInput(command)) {
        case Result.Ok(value) => value
        case Result.Err(error) => printError(error, io: io); return 2
    }
    if (parsed.tokens.size != arguments.size + 1 || parsed.tokens[0].value != "/plugins") {
        return pluginCliUsage("plugin inspect arguments could not be preserved", io: io)
    }
    for (index in 0..arguments.size) {
        if (parsed.tokens[index + 1].value != arguments[index]) {
            return pluginCliUsage("plugin inspect argument changed during parsing", io: io)
        }
    }
    match (session.handle(command)) {
        case Result.Err(error) => printError(error, io: io); 1
        case Result.Ok(response) =>
            if (response.text != "") { io.println(response.text) }
            match (response.approval) {
                case Some(_) =>
                    printError(AgentError(AgentErrorKind.PermissionDenied, "plugin.cli_interactive_required",
                        "plugin maintenance requires an interactive approval"), io: io)
                    3
                case None => 0
            }
    }
}

func runPluginCli(session: ApplicationSession, arguments: Array<String>, io!: CliIo180 = consoleCliIo180): Int64 {
    if (arguments.isEmpty() || (arguments.size == 1 && (arguments[0] == "--help" || arguments[0] == "-h"))) {
        printPluginHelp(io: io)
        return 0
    }
    if (arguments.size > 12) { return pluginCliUsage("too many plugin arguments", io: io) }
    for (argument in arguments) {
        if (argument.trimAscii() == "" || argument.size > 16384 || argument.contains("\u{0000}") ||
            argument.contains("\n") || argument.contains("\r")) {
            return pluginCliUsage("plugin arguments must be nonempty bounded text without control separators", io: io)
        }
    }
    let action = arguments[0]
    if (action == "commands") {
        if (arguments.size > 2 || (arguments.size == 2 && arguments[1] != "--json")) {
            return pluginCliUsage("commands accepts only --json", io: io)
        }
        let commands = session.javascriptPluginCommands()
        if (arguments.size == 2) {
            let values = ArrayList<AgentValue>()
            for (command in commands) {
                values.add(objectValue([
                    ValueField("route", textValue(command.routeName)),
                    ValueField("description", textValue(command.description))
                ]))
            }
            io.println(stringifyUnifiedJson(listValue(values.toArray())))
        } else {
            for (command in commands) { io.println(command.routeName + " · " + command.description) }
            if (commands.isEmpty()) { io.println("No plugin commands are enabled.") }
        }
        return 0
    }
    if (action == "views") {
        if (arguments.size > 2 || (arguments.size == 2 && arguments[1] != "--json")) {
            return pluginCliUsage("views accepts only --json", io: io)
        }
        let views = session.javascriptPluginViews()
        if (arguments.size == 2) {
            let values = ArrayList<AgentValue>()
            for (view in views) {
                values.add(objectValue([
                    ValueField("route", textValue(view.routeName)),
                    ValueField("description", textValue(view.description))
                ]))
            }
            io.println(stringifyUnifiedJson(listValue(values.toArray())))
        } else {
            for (view in views) { io.println(view.routeName + " · " + view.description) }
            if (views.isEmpty()) { io.println("No plugin views are enabled.") }
        }
        return 0
    }
    if (action == "command") {
        if ((arguments.size != 2 && arguments.size != 3) || arguments[1].startsWith("-") ||
            arguments[1].size > 512) {
            return pluginCliUsage("command requires one route and at most one bounded argument string", io: io)
        }
        match (session.invokeJavaScriptPluginCommand(arguments[1],
            if (arguments.size == 3) { arguments[2] } else { "" },
            { _, message => if (message != "") { io.println(message) } })) {
            case Result.Ok(_) => return pluginCliReviewCommand(session, io: io)
            case Result.Err(error) => printError(error, io: io); return 1
        }
    }
    if (action == "list") {
        if (arguments.size > 2 || (arguments.size == 2 && arguments[1] != "--json")) {
            return pluginCliUsage("list accepts only --json", io: io)
        }
        return appRegistryCliPrintList158(session.plugins(), arguments.size == 2, io: io)
    }
    if (action == "inspect") {
        if ((arguments.size != 2 && arguments.size != 3) || arguments[1].startsWith("-") ||
            (arguments.size == 3 && arguments[2] != "--json")) {
            return pluginCliUsage("inspect requires a path and optional --json", io: io)
        }
        return pluginCliInspect(session, arguments, io: io)
    }
    if (action == "doctor") {
        if (arguments.size != 1) { return pluginCliUsage("doctor accepts no arguments", io: io) }
        let errors = session.pluginDoctor()
        io.println("Plugin doctor:")
        for (error in errors) { let _ = pluginCliError(error, io: io) }
        if (errors.isEmpty()) { io.println("No plugin issues detected."); return 0 }
        return 1
    }
    if (action == "gc") {
        if (arguments.size != 1) { return pluginCliUsage("gc accepts no arguments", io: io) }
        match (session.garbageCollectPlugins()) {
            case PluginRegistryResult.Err(error) => return pluginCliError(error, io: io)
            case PluginRegistryResult.Ok(paths) =>
                io.println("Garbage-collected " + paths.size.toString() + " plugin generations.")
                return 0
        }
    }
    let baseCount = match (action) {
        case "import" | "enable" | "disable" | "rollback" | "uninstall" => 2
        case "update" => 3
        case _ => return pluginCliUsage("unknown plugin action: " + action, io: io)
    }
    if (arguments.size < baseCount) { return pluginCliUsage("missing argument for plugin " + action, io: io) }
    let sourceIndex = if (action == "import") { 1 } else { 2 }
    let remote = (action == "import" || action == "update") &&
        (arguments[sourceIndex] == "git" || arguments[sourceIndex] == "npm")
    let positionalCount = if (remote) { baseCount + 2 } else { baseCount }
    if (arguments.size < positionalCount) { return pluginCliUsage("Git/npm acquisition requires a locator and exact pin", io: io) }
    for (index in 1..positionalCount) {
        if (arguments[index].startsWith("-")) { return pluginCliUsage("unexpected flag in a positional argument", io: io) }
    }
    var scope: ?PluginInstallScope = None
    var registrySeen = false
    var index = positionalCount
    while (index < arguments.size) {
        if (arguments[index] == "--scope" && scope.isNone() && index + 1 < arguments.size) {
            scope = match (arguments[index + 1]) {
                case "user" => Some(PluginInstallScope.User)
                case "workspace" => Some(PluginInstallScope.Workspace)
                case _ => return pluginCliUsage("scope must be user or workspace", io: io)
            }
        } else if (remote && arguments[sourceIndex] == "npm" && arguments[index] == "--registry" &&
            !registrySeen && index + 1 < arguments.size && !arguments[index + 1].startsWith("-")) {
            registrySeen = true
        } else {
            return pluginCliUsage("unknown, repeated, or incomplete option: " + arguments[index], io: io)
        }
        index += 2
    }
    if (remote) {
        // ApplicationSession's interactive source APIs explicitly supply
        // ApprovalDecision.Approve. A noninteractive wrapper must not silently
        // inherit that decision, even when an exact source pin was supplied.
        printError(AgentError(AgentErrorKind.PermissionDenied, "plugin.cli_interactive_required",
            "Git/npm acquisition requires the interactive /plugins " + action +
                " command and its normal permission checks; import a local package here instead"), io: io)
        return 3
    }
    if (action == "uninstall") {
        let result = match (scope) {
            case Some(value) => session.uninstallPlugin(arguments[1], value)
            case None => session.uninstallPlugin(arguments[1])
        }
        match (result) {
            case PluginRegistryResult.Err(error) => return pluginCliError(error, io: io)
            case PluginRegistryResult.Ok(_) => io.println("Uninstalled plugin " + arguments[1] + "."); return 0
        }
    }
    let result: PluginRegistryResult<ProductPluginRecord> = match (action) {
        case "import" => match (scope) {
            case Some(value) => session.importLocalPlugin(arguments[1], value)
            case None => session.importLocalPlugin(arguments[1])
        }
        case "update" => match (scope) {
            case Some(value) => session.updateLocalPlugin(arguments[1], arguments[2], value)
            case None => session.updateLocalPlugin(arguments[1], arguments[2])
        }
        case "rollback" => match (scope) {
            case Some(value) => session.rollbackPlugin(arguments[1], value)
            case None => session.rollbackPlugin(arguments[1])
        }
        case _ => match (scope) {
            case Some(value) => session.setPluginEnabled(arguments[1], action == "enable", value)
            case None => session.setPluginEnabled(arguments[1], action == "enable")
        }
    }
    pluginCliRecordResult(result, action, io: io)
}

// Generic inherited-stdio entry. Protocol bytes are never printed through the
// interactive command renderer; only the ingress owner writes fd1.
func runPluginStdioCli(product: ProductRuntime, arguments: Array<String>, io!: CliIo180 = consoleCliIo180): Int64 {
    if (arguments.size != 2 || arguments[1] == "" || arguments[1].startsWith("-")) {
        io.eprintln("plugin.ingress_usage: axyndra plugin serve <operator-grant-id>")
        return 2
    }
    match (product.vnext.servePluginStdio(arguments[1],
        input180: io.stdioInput180(),
        callerCancellation180: Some(io.cancellation180()),
        output180: io.stdioOutput180())) {
        case Result.Ok(_) => 0
        case Result.Err(error) => io.eprintln(error.describe()); 1
    }
}

// The process retains the same actual command owner across both reviews. EOF
// is cancellation, never approval or an abandoned prepared Direct operation.
func pluginCliReviewCommand(session: ApplicationSession, io!: CliIo180 = consoleCliIo180): Int64 {
    while (true) {
        let approval = match (session.approval()) { case Some(value) => value; case None => return 0 }
        let details = approvalDetails(approval)
        io.println("Approval required: " + details.toolName + " (" + details.operationId.value + ")")
        io.println(stringifyUnifiedJson(approvalReviewerArguments(approval)))
        io.print("Approve this exact operation? [yes/no]: ")
        let answer = match (io.readln()) { case Some(value) => value.trimAscii()
            case None => let _ = session.cancel(); return 1 }
        if (answer != "yes" && answer != "no") { io.println("Enter yes or no."); continue }
        match (session.decide(approval.operationId.value,
            if (answer == "yes") { ApprovalDecision.Approve } else { ApprovalDecision.Reject })) {
            case Result.Err(error) => printError(error, io: io); let _ = session.cancel(); return 1
            case Result.Ok(response) => if (response.text != "") { io.println(response.text) } }
    }
    0
}
