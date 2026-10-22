package agent_app

import yjson_support.*

import yjson.*

import agent_domain.*
import logical_json_payload.LogicalJsonCopiedDisplayAllocation as ImportedLogicalJsonCopiedDisplayAllocation
import agent_core.*
import agent_runtime.*
import agent_app_protocol.*
import agent_cli.*
import agent_product.*
import agent_rpc.*
import agent_embed.*
import agent_tui.*
import process4cj.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.process.*
import std.sync.*
import std.time.*
import tool_runtime.*


main(): Int64 {
    let rawArguments = getCommandLine()
    if (isProductProcessBrokerWorker(rawArguments)) {
        return runProductProcessBrokerWorker(rawArguments, AppProductOwnerFrontend180())
    }
    if (isProductProcessBrokerClient(rawArguments)) {
        return runProductProcessBrokerClient(rawArguments)
    }
    tuiStartupStage("runtime_initialization_completed")
    let cliCommandIndex = directCliCommandIndex(rawArguments)
    let cliCommand = directCliCommand(rawArguments)
    match (reservedCliCommandRegistry().resolve(cliCommand)) {
        case Some(spec) => if (spec.replacement != "") {
            printError(AgentError(AgentErrorKind.Configuration, "cli.command_moved",
                spec.replacement, fields: [ErrorField("command", cliCommand)]))
            return 2
        }
        case None => ()
    }
    if (cliCommand == "tools") {
        let toolArguments = cliCommandTail(rawArguments, cliCommandIndex)
        if (toolArguments.isEmpty() || (toolArguments.size == 1 &&
            (toolArguments[0] == "--help" || toolArguments[0] == "-h"))) {
            printToolsHelp()
            return 0
        }
    }
    if (cliCommand == "plugin") {
        let pluginArguments = cliCommandTail(rawArguments, cliCommandIndex)
        if (pluginArguments.isEmpty() || (pluginArguments.size == 1 &&
            (pluginArguments[0] == "--help" || pluginArguments[0] == "-h"))) {
            printPluginHelp()
            return 0
        }
    }
    if ((rawArguments.size > 1 && rawArguments[1] == "setup") || cliCommand == "setup") {
        return runSetup()
    }
    if (cliCommand == "" && (hasArgument(rawArguments, "--help") || hasArgument(rawArguments, "-h"))) {
        printHelp()
        return 0
    }
    if (cliCommand == "" && (hasArgument(rawArguments, "--version") || hasArgument(rawArguments, "-v"))) {
        println("axyndra/17.2.3")
        return 0
    }
    if ((rawArguments.size > 1 && rawArguments[1] == "completions") || cliCommand == "completions") {
        return runCompletionsCli(cliCommandTail(rawArguments, cliCommandIndex))
    }
    if (cliCommand == "") {
        match (argumentParseError(rawArguments)) {
            case Some(message) =>
                println("Error: " + message)
                println("Run `axyndra --help` for available flags.")
                return 2
            case None => ()
        }
    }
    let fixture = hasArgument(rawArguments, "--fixture")
    let approvalRoutingMode = if (cliCommand == "reviewer-dry-run") {
        Some(ApprovalRoutingMode.Ai)
    } else {
        approvalRoutingModeFrom(rawArguments)
    }
    let approvalMode = match (approvalRoutingMode) {
        case Some(ApprovalRoutingMode.Trusted) => ApprovalMode.Yolo
        case _ => approvalModeFrom(rawArguments)
    }
    var mode = argumentValue(rawArguments, "--mode")
    if (cliCommand == "acp") {
        mode = "acp"
    }
    if (mode != "" && mode != "text" && mode != "json" && mode != "rpc" && mode != "rpc-ui" && mode != "acp") {
        println("Error: invalid mode: " + mode)
        return 2
    }
    let shellNetworkModeOverride = match (shellNetworkModeFrom(rawArguments)) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            printError(error)
            return 2
    }
    var arguments = withoutRuntimeArguments(rawArguments)
    tuiStartupStage("configuration_loading_started")
    let productConfig = ProductConfig(
        stateRoot: if (fixture) {
            defaultStateRoot() + "/fixture"
        } else {
            defaultStateRoot()
        },
        workspaceRoot: argumentValueOr(
            rawArguments,
            "--cwd",
            "."
        ),
        shellNetworkModeOverride: shellNetworkModeOverride,
        distributionRoot: bundledProductDistributionRoot(),
        fixture: fixture,
        approvalMode: approvalMode,
        approvalRoutingModeOverride: approvalRoutingMode,
        modelOverride: argumentValue(rawArguments, "--model"),
        wallTimeoutMillis: wallTimeoutFrom(rawArguments),
        modelAttemptRecovery: modelAttemptRecoveryFrom(rawArguments),
        modelStreamFaultProfile: modelStreamFaultProfileFrom(rawArguments)
    )
    let localCommand = localMaintenanceCommand(rawArguments, cliCommand)
    if (localCommand != "") {
        let localArguments = cliCommandTail(rawArguments, cliCommandIndex)
        let localStateRoot = if (localCommand == "gc") {
            argumentValueOr(localArguments, "--agent-dir", productConfig.stateRoot)
        } else {
            productConfig.stateRoot
        }
        return runLocalMaintenanceCommand(
            localCommand,
            localArguments,
            ProductConfig(
                settingsRoot: productConfig.settingsRoot,
                stateRoot: localStateRoot,
                workspaceRoot: productConfig.workspaceRoot,
                distributionRoot: productConfig.distributionRoot,
                fixture: productConfig.fixture,
                unsafeDirectLaunchForTests: productConfig.unsafeDirectLaunchForTests,
                approvalMode: productConfig.approvalMode,
                approvalRoutingModeOverride: productConfig.approvalRoutingModeOverride,
                shellNetworkModeOverride: productConfig.shellNetworkModeOverride,
                modelOverride: productConfig.modelOverride,
                asyncEnabled: productConfig.asyncEnabled,
                wallTimeoutMillis: productConfig.wallTimeoutMillis,
                modelAttemptRecovery: productConfig.modelAttemptRecovery,
                modelStreamFaultProfile: productConfig.modelStreamFaultProfile,
                extensionSignatureVerifier: productConfig.extensionSignatureVerifier,
                compactionOverride: productConfig.compactionOverride,
                startupMode: ProductStartupMode.LocalMaintenance
            ),
            rawArguments180: rawArguments
        )
    }
    if (cliCommand == "gallery") {
        return runGalleryCli(cliCommandTail(rawArguments, cliCommandIndex))
    }
    if ((rawArguments.size > 1 && rawArguments[1] == "launch") || cliCommand == "launch" ||
        (rawArguments.size > 1 && rawArguments[1] == "acp") || cliCommand == "acp") {
        arguments = stripCliCommand(arguments)
    }
    let direct = cliCommand == "models" || cliCommand == "reviewer-dry-run" || cliCommand == "__complete" ||
        cliCommand == "token" || cliCommand == "shell"
    if (!direct && cliCommand != "" && cliCommand != "launch" && cliCommand != "acp") {
        printError(unavailableCliCommand(cliCommand, cliCommandTail(rawArguments, cliCommandIndex)))
        return 1
    }
    let frontendRoot = reserveProductControlMetadata113(65536)
    let status = runNativeOwnerFrontend180(productConfig, rawArguments, arguments, cliCommand,
        cliCommandIndex, mode, direct, frontendRoot)
    frontendRoot.close()
    status
}

func localMaintenanceCommand(
    arguments: Array<String>,
    command: String
): String {
    let candidate = if (command != "") {
        command
    } else if (arguments.size > 1) {
        canonicalCliCommand(arguments[1])
    } else {
        ""
    }
    if (candidate == "read" || candidate == "config" || candidate == "grep" ||
        candidate == "agents" || candidate == "worktree" ||
        candidate == "tools" || candidate == "plugin" || candidate == "gc" || candidate == "usage" || candidate == "stats" ||
        candidate == "grievances" || candidate == "ssh") {
        candidate
    } else {
        ""
    }
}

func runLocalMaintenanceCommand(
    command: String,
    arguments: Array<String>,
    config: ProductConfig,
    rawArguments180!: Array<String> = []
): Int64 {
    let paid = reserveProductControlMetadata113(65536)
    let request = ownerFrontendRequest180("cli", rawArguments180, command, arguments)
    let status = runOwnerFrontendClient180(config, request, paid)
    paid.close()
    status
}

func runNativeOwnerFrontend180(config: ProductConfig, rawArguments: Array<String>, arguments: Array<String>,
    command: String, commandIndex: Int64, mode: String, direct: Bool,
    frontendRoot: LogicalJsonOwnerReservation): Int64 {
    let frontend = if (direct) { "cli" } else if (mode == "rpc" || mode == "rpc-ui") { "rpc" }
        else if (mode == "acp") { "acp" } else if (mode == "json") { "json" }
        else if (mode == "text" || hasArgument(rawArguments, "--print") || hasArgument(rawArguments, "-p")) { "text" }
        else { "tui" }
    var bytes: Int64 = 65536
    for (argument in rawArguments) { bytes += argument.size * 16 + 4096 }
    frontendRoot.ensureRetainedPeak(bytes)
    let request = ownerFrontendRequest180(frontend, rawArguments, command, cliCommandTail(rawArguments, commandIndex))
    if (frontend == "tui") {
        let allocate = { extent: Int64 =>
            let paid = frontendRoot.deriveRetainedLease()
            try { paid.ensureRetainedPeak(extent); paid }
            catch (error: Exception) { paid.close(); throw error }
        }
        return runProductOwnerClientFrontend180(config, request,
            { peer => createOwnerProductTuiClientFrontend180(peer, joinArguments(arguments, 1)) },
            allocate: allocate)
    }
    if (frontend == "text" || frontend == "json") {
        var prompt = joinArguments(arguments, 1)
        if (prompt == "") { prompt = readStdinPrompt() }
        if (frontend == "text" && prompt == "") { return 0 }
        return runOwnerFrontendClient180(config, request, frontendRoot, prompt: Some(prompt))
    }
    runOwnerFrontendClient180(config, request, frontendRoot)
}

func unavailableCliCommand(
    command: String,
    arguments: Array<String>
): AgentError {
    if (command == "join") {
        return AgentError(
            AgentErrorKind.Configuration,
            "collaboration_not_available",
            "collaboration relay support is not available in this release"
        )
    }
    if (command == "update" && !hasArgument(arguments, "--plugins")) {
        return AgentError(
            AgentErrorKind.Configuration,
            "update.source_unconfigured",
            "application update source is not configured"
        )
    }
    if ((command == "auth-broker" || command == "auth-gateway") && (containsArgument(arguments, "login") ||
        containsArgument(arguments, "logout"))) {
        return AgentError(
            AgentErrorKind.Configuration,
            "oauth_not_supported",
            "OAuth profiles are not supported in this release"
        )
    }
    AgentError(
        AgentErrorKind.Configuration,
        "cli.capability_unavailable",
        "CLI capability is unavailable",
        fields: [ErrorField("command", command)]
    )
}

func containsArgument(arguments: Array<String>, expected: String): Bool {
    for (argument in arguments) {
        if (argument == "--") { break }
        if (argument == expected) { return true }
    }
    false
}

func directCliCommand(arguments: Array<String>): String {
    let index = directCliCommandIndex(arguments)
    if (index < 0) {
        return ""
    }
    canonicalCliCommand(arguments[index])
}

func directCliCommandIndex(arguments: Array<String>): Int64 {
    var index: Int64 = 1
    while (index < arguments.size) {
        let candidate = arguments[index]
        if (candidate == "--") {
            return -1
        }
        if (candidate == "--help" || candidate == "-h" || candidate == "--version" || candidate == "-v") {
            return -1
        }
        if (candidate == "--approval-mode" || candidate == "--mode" || candidate == "--model" || candidate == "--cwd" ||
            candidate == "--max-time" || candidate == "--model-attempt-recovery" ||
            candidate == "--model-stream-idle-timeout-ms" || candidate == "--model-stream-fault-profile" ||
            candidate == "--shell-network-mode") {
            if (index + 1 >= arguments.size || arguments[index + 1] == "--") { return -1 }
            index += 2
            continue
        }
        if (candidate.startsWith("-")) {
            index += 1
            continue
        }
        if (canonicalCliCommand(candidate) != "") {
            return index
        }
        return -1
    }
    -1
}

func canonicalCliCommand(candidate: String): String {
    match (reservedCliCommandRegistry().resolve(candidate)) {
        case Some(spec) => spec.name
        case None => ""
    }
}

func cliCommandTail(
    arguments: Array<String>,
    index: Int64
): Array<String> {
    if (index < 0 || index + 1 >= arguments.size) {
        return []
    }
    arguments[index + 1..arguments.size]
}

func runModelsCli(
    session: ApplicationSession,
    arguments: Array<String>
, io!: CliIo180 = consoleCliIo180): Int64 {
    if (hasArgument(arguments, "--help") || hasArgument(arguments, "-h")) {
        io.println("axyndra models [ls|find <substring>|refresh|<provider>] " + "[--json]")
        return 0
    }
    let json = hasArgument(arguments, "--json")
    let positional = cliPositionals(arguments, ["--json"])
    var action = "ls"
    var pattern = ""
    if (!positional.isEmpty()) {
        match (positional[0]) {
            case "ls" | "list" =>
                if (positional.size > 1) {
                    pattern = positional[1]
                }
            case "find" =>
                action = "find"
                if (positional.size > 1) {
                    pattern = positional[1]
                }
            case "refresh" => action = "refresh"
            case value => pattern = value
        }
    }
    if (action == "find" && pattern.trimAscii() == "") {
        io.println("`axyndra models find` requires a search substring, " + "e.g. `axyndra models find deepseek`")
        return 1
    }
    if (action == "refresh") {
        io.println("Error: model catalog refresh requires the OMP-compatible " + "catalog service, which is not installed.")
        return 1
    }
    let models = filteredModels(session, pattern, action == "find")
    if (json) {
        let values = ArrayList<AgentValue>()
        for (model in models) {
            values.add(cliModelValue(session, model))
        }
        io.println(encodeAgentValue(objectValue([ValueField("models", listValue(values.toArray()))])))
        return 0
    }
    if (session.models().isEmpty()) {
        io.println("No models available. Set API keys in environment variables.")
        return 0
    }
    if (models.isEmpty()) {
        io.println("No models matching \"" + pattern + "\"")
        return 0
    }
    var activeProvider = ""
    var providerCount: Int64 = 0
    for (model in models) {
        let provider = session.modelProvider(model)
        if (provider != activeProvider) {
            if (activeProvider != "") {
                io.println()
            }
            activeProvider = provider
            providerCount = countProviderModels(session, models, provider)
            io.println(provider + " (" + providerCount.toString() + ")")
            io.println("model")
        }
        io.println(session.rawModelId(model))
    }
    0
}

// Strip only flags already owned by the application's configuration parser.
// The sentinel is retained, so subsequent tool-shaped words remain literal.
func workspaceFrontendCliArguments(arguments: Array<String>): Array<String> {
    let values=ArrayList<String>();var skipNext=false;var positionalOnly=false
    let globals=["--approval-mode","--mode","--model","--cwd","--max-time","--model-attempt-recovery",
        "--model-stream-idle-timeout-ms","--model-stream-fault-profile","--shell-network-mode"]
    for(argument in arguments){
        if(positionalOnly){values.add(argument);continue}
        if(skipNext){skipNext=false;continue}
        if(argument=="--"){values.add(argument);positionalOnly=true;continue}
        if(globals.contains(argument)){skipNext=true;continue}
        var configured=false
        for(flag in globals where argument.startsWith(flag+"=")){configured=true}
        if(configured || ["--fixture","--print","-p","--version","-v","--json"].contains(argument)){continue}
        values.add(argument)
    }
    values.toArray()
}

func runReadCli(session: ApplicationSession, arguments: Array<String>, io!: CliIo180 = consoleCliIo180): Int64 {
    if(hasArgument(arguments,"--help") || hasArgument(arguments,"-h")){
        io.println("axyndra read <path-or-resource> [--destination <workspace-file>] [--interactive]");return 0}
    let toolArguments=workspaceFrontendCliArguments(arguments)
    let input=ArrayList<ValueField>();let positional=ArrayList<String>();var destination="";var index:Int64=0;var positionalOnly=false
    while(index<toolArguments.size){
        if(positionalOnly){positional.add(toolArguments[index]);index++;continue}
        if(toolArguments[index]=="--"){positionalOnly=true;index++;continue}
        if(toolArguments[index]=="--destination"){
            if(index+1>=toolArguments.size){io.println("error: destination is required");return 1}
            destination=toolArguments[index+1];index+=2;continue}
        if(toolArguments[index]!="--interactive"){positional.add(toolArguments[index])};index++}
    if(positional.size!=1){io.println("error: one path or resource is required");return 1}
    input.add(ValueField("path",textValue(positional[0])))
    if(destination!=""){input.add(ValueField("destination",textValue(destination)))}
    runSelectedWorkspaceCli(session,"read",objectValue(input.toArray()),hasArgument(arguments,"--interactive"), io: io)
}

func runConfigCli(
    session: ApplicationSession,
    arguments: Array<String>
, io!: CliIo180 = consoleCliIo180): Int64 {
    if (hasArgument(arguments, "--help") || hasArgument(arguments, "-h")) {
        io.println("axyndra config [list|get|set|reset|path] [key] [value] " + "[--json]")
        return 0
    }
    let json = hasArgument(arguments, "--json")
    let positional = cliPositionals(arguments, ["--json"])
    let action = if (positional.isEmpty()) {
        "list"
    } else {
        positional[0]
    }
    if (action == "path") {
        io.println(session.configRoot() + "/config.yml")
        return 0
    }
    let settings = match (loadProductSettings(session.configRoot())) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            printError(error, io: io)
            return 1
    }
    if (action == "list") {
        if (json) {
            io.println(
                encodeAgentValue(
                    objectValue(
                        [
                            ValueField(
                                "schema_version",
                                textValue("1")
                            ),
                            ValueField(
                                "default_model",
                                textValue(settings.model)
                            ),
                            ValueField(
                                "async.enabled",
                                boolValue(settings.asyncEnabled)
                            ),
                            ValueField(
                                "shell.network_mode",
                                textValue(shellNetworkModeName(settings.shellNetworkMode))
                            ),
                            ValueField(
                                "sandbox.ca_bundle",
                                textValue(settings.sandboxCaBundle)
                            )
                        ]
                    )
                )
            )
        } else {
            io.println("Settings:")
            io.println("  schema_version = 1")
            io.println("  default_model = " + if (settings.model == "") {
                "(not set)"
            } else {
                settings.model
            })
            io.println("  async.enabled = " + settings.asyncEnabled.toString())
            io.println("  shell.network_mode = " + shellNetworkModeName(settings.shellNetworkMode))
            io.println("  sandbox.ca_bundle = " + if (settings.sandboxCaBundle == "") {
                "(not set)"
            } else {
                settings.sandboxCaBundle
            })
        }
        return 0
    }
    if (action == "get") {
        if (positional.size < 2) {
            io.println("Usage: axyndra config get <key>")
            return 1
        }
        return printConfigValue(
            settings,
            positional[1],
            json
        , io: io)
    }
    if (action == "set") {
        if (positional.size < 3) {
            io.println("Usage: axyndra config set <key> <value>")
            return 1
        }
        let value = joinArguments(positional, 2)
        let edits = ArrayList<ProductConfigEdit>()
        match (positional[1]) {
            case "default_model" =>
                if (value.trimAscii() == "") {
                    io.println("default_model must not be empty")
                    return 1
                }
                edits.add(ProductConfigEdit(
                    "default_model",
                    ProductConfigScalar.Text(value.trimAscii())
                ))
            case "async.enabled" =>
                let parsed = parseCliBool(value)
                if (parsed.isNone()) {
                    io.println("Invalid boolean value: " + value + ". Use true/false, yes/no, on/off, or 1/0")
                    return 1
                }
                edits.add(ProductConfigEdit(
                    "async.enabled",
                    ProductConfigScalar.Boolean(parsed.getOrThrow())
                ))
            case "shell.network_mode" =>
                let parsed = match (parseShellNetworkMode(value)) {
                    case Result.Ok(mode) => mode
                    case Result.Err(error) =>
                        io.println(error.message)
                        return 1
                }
                edits.add(ProductConfigEdit(
                    "shell.network_mode",
                    ProductConfigScalar.Text(shellNetworkModeName(parsed))
                ))
            case "sandbox.ca_bundle" =>
                edits.add(ProductConfigEdit(
                    "sandbox.ca_bundle",
                    ProductConfigScalar.Text(value.trimAscii())
                ))
            case key =>
                io.println("Unknown setting: " + key)
                return 1
        }
        return saveCliSettings(
            session.configRoot(),
            edits.toArray(),
            json,
            positional[1]
        , io: io)
    }
    if (action == "reset") {
        let key = if (positional.size > 1) {
            positional[1]
        } else {
            ""
        }
        if (key != "" && key != "default_model" && key != "async.enabled" &&
            key != "shell.network_mode" && key != "sandbox.ca_bundle") {
            io.println("Unknown setting: " + key)
            return 1
        }
        let edits = ArrayList<ProductConfigEdit>()
        if (key == "" || key == "default_model") {
            edits.add(ProductConfigEdit(
                "default_model",
                ProductConfigScalar.Text("")
            ))
        }
        if (key == "" || key == "async.enabled") {
            edits.add(ProductConfigEdit(
                "async.enabled",
                ProductConfigScalar.Boolean(true)
            ))
        }
        if (key == "" || key == "shell.network_mode") {
            edits.add(ProductConfigEdit(
                "shell.network_mode",
                ProductConfigScalar.Text("restricted")
            ))
        }
        if (key == "" || key == "sandbox.ca_bundle") {
            edits.add(ProductConfigEdit(
                "sandbox.ca_bundle",
                ProductConfigScalar.Text("")
            ))
        }
        return saveCliSettings(
            session.configRoot(),
            edits.toArray(),
            json,
            key
        , io: io)
    }
    io.println("Unknown config command: " + action + "\nValid commands: list, get, set, reset, path")
    1
}

func printConfigValue(
    settings: ProductSettings,
    key: String,
    json: Bool
, io!: CliIo180 = consoleCliIo180): Int64 {
    let value: AgentValue
    match (key) {
        case "schema_version" => value = textValue("1")
        case "default_model" => value = textValue(settings.model)
        case "async.enabled" => value = boolValue(settings.asyncEnabled)
        case "shell.network_mode" =>
            value = textValue(shellNetworkModeName(settings.shellNetworkMode))
        case "sandbox.ca_bundle" => value = textValue(settings.sandboxCaBundle)
        case _ =>
            io.println("Unknown setting: " + key)
            return 1
    }
    if (json) {
        io.println(
            encodeAgentValue(
                objectValue(
                    [
                        ValueField("key", textValue(key)),
                        ValueField("value", value)
                    ]
                )
            )
        )
    } else {
        match (value.unifiedKind) {
            case ValueKind.Text => io.println(value.text)
            case ValueKind.Boolean => io.println(value.asBool().toString())
            case _ => io.println(encodeAgentValue(value))
        }
    }
    0
}

func saveCliSettings(
    root: String,
    edits: Array<ProductConfigEdit>,
    json: Bool,
    key: String
, io!: CliIo180 = consoleCliIo180): Int64 {
    let path = root + "/config.yml"
    match (updateProductConfig(root, edits)) {
        case Result.Ok(_) => ()
        case Result.Err(error) =>
            printError(error, io: io)
            return 1
    }
    if (json) {
        io.println(
            encodeAgentValue(
                objectValue(
                    [
                        ValueField("key", textValue(key)),
                        ValueField("updated", boolValue(true))
                    ]
                )
            )
        )
    } else {
        io.println("Updated " + path)
    }
    0
}

func parseCliBool(value: String): ?Bool {
    match (value.trimAscii().toAsciiLower()) {
        case "true" | "1" | "yes" | "on" => Some(true)
        case "false" | "0" | "no" | "off" => Some(false)
        case _ => None
    }
}

func runGrepCli(session: ApplicationSession, arguments: Array<String>, io!: CliIo180 = consoleCliIo180): Int64 {
    if(hasArgument(arguments,"--help") || hasArgument(arguments,"-h")){
        io.println("axyndra grep <pattern> [path-or-globs] [--count] [--case] [--no-gitignore] [--skip <n>] [--interactive]");return 0}
    let toolArguments=workspaceFrontendCliArguments(arguments)
    let positional=ArrayList<String>();var skip:Int64=0;var index:Int64=0;var positionalOnly=false
    while(index<toolArguments.size){
        let argument=toolArguments[index]
        if(positionalOnly){positional.add(argument);index++;continue}
        if(argument=="--"){positionalOnly=true;index++;continue}
        if(argument=="--skip"){
            if(index+1>=toolArguments.size){io.println("error: skip requires an integer");return 1}
            skip=parseCliInteger(toolArguments[index+1],-1);if(skip<0){io.println("error: skip requires a nonnegative integer");return 1}
            index+=2;continue}
        if(!["--count","--case","--no-gitignore","--interactive"].contains(argument)){
            if(argument.startsWith("-")){io.println("error: unsupported native grep flag: "+argument);return 1};positional.add(argument)}
        index++}
    if(positional.size<1 || positional.size>2){io.println("error: pattern and optional native path filter are required");return 1}
    runSelectedWorkspaceCli(session,"grep",objectValue([ValueField("pattern",textValue(positional[0])),
        ValueField("path",textValue(if(positional.size==2){positional[1]}else{""})),
        ValueField("count",boolValue(hasArgument(arguments,"--count"))),ValueField("case",boolValue(hasArgument(arguments,"--case"))),
        ValueField("gitignore",boolValue(!hasArgument(arguments,"--no-gitignore"))),ValueField("skip",integerValue(skip))]),hasArgument(arguments,"--interactive"), io: io)
}

func parseCliInteger(value: String, fallback: Int64): Int64 {
    try {
        Int64.parse(value)
    } catch (_: Exception) {
        fallback
    }
}









func joinCliLines(lines: Array<String>): String {
    var output = ""
    for (line in lines) {
        if (output != "") {
            output += "\n"
        }
        output += line
    }
    output
}

func runAgentsCli(
    session: ApplicationSession,
    arguments: Array<String>
, io!: CliIo180 = consoleCliIo180): Int64 {
    if (arguments.isEmpty() || hasArgument(arguments, "--help") || hasArgument(arguments, "-h")) {
        io.println("axyndra agents unpack [--force] [--json] " + "[--dir <path>|--user|--project]")
        return 0
    }
    if (arguments[0] != "unpack") {
        io.println("Unknown agents action: " + arguments[0])
        return 1
    }
    var force = false
    var json = false
    var user = false
    var project = false
    var authoredDirectory = ""
    var index: Int64 = 1
    while (index < arguments.size) {
        let argument = arguments[index]
        if (argument == "--force" || argument == "-f") {
            force = true
        } else if (argument == "--json") {
            json = true
        } else if (argument == "--user") {
            user = true
        } else if (argument == "--project") {
            project = true
        } else if (argument == "--dir") {
            if (index + 1 >= arguments.size) {
                io.println("Error: --dir requires a path")
                return 1
            }
            authoredDirectory = arguments[index + 1]
            index += 1
        } else if (argument == "--fixture") {
            ()
        } else {
            io.println("Error: unknown agents flag: " + argument)
            return 1
        }
        index += 1
    }
    if (user && project) {
        io.println("Choose either --user or --project, not both.")
        return 1
    }
    if (authoredDirectory != "" && (user || project)) {
        io.println("--dir cannot be combined with --user or --project.")
        return 1
    }
    let target = if (authoredDirectory != "") {
        match (LocalWorkspace(session.workspaceRoot()).resolve(
            authoredDirectory,
            allowDirectory: true
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                printError(error, io: io)
                return 1
        }
    } else if (project) {
        session.workspaceRoot() + "/.axyndra/agents"
    } else {
        session.configRoot() + "/agents"
    }
    try {
        if (!exists(Path(target))) {
            Directory.create(target, recursive: true)
        } else if (!FileInfo(target).isDirectory()) {
            io.println("error: agent target is not a directory: " + target)
            return 1
        }
    } catch (error: Exception) {
        io.println("error: cannot create agent directory: " + error.message)
        return 1
    }
    let written = ArrayList<String>()
    let skipped = ArrayList<String>()
    let agents = match (session.bundledAgents()) {
        case Result.Err(error) =>
            io.println("error: installed workflow roles are unavailable: " + error.code + ": " + error.message)
            return 1
        case Result.Ok(value) => value }
    for (agent in agents) {
        let path = target + "/" + agent.name + ".md"
        if (exists(Path(path)) && !force) {
            skipped.add(path)
            continue
        }
        let temporary = path + ".tmp"
        try {
            File.writeTo(
                temporary,
                serializeBundledAgent(agent).toArray()
            )
            rename(temporary, to: path, overwrite: true)
            written.add(path)
        } catch (error: Exception) {
            let _ = removeIfExists(temporary)
            io.println("error: cannot write agent " + agent.name + ": " + error.message)
            return 1
        }
    }
    if (json) {
        io.println(
            encodeAgentValue(
                objectValue(
                    [
                        ValueField("targetDir", textValue(target)),
                        ValueField(
                            "total",
                            integerValue(agents.size)
                        ),
                        ValueField("written", cliStringList(written.toArray())),
                        ValueField("skipped", cliStringList(skipped.toArray()))
                    ]
                )
            )
        )
    } else {
        io.println("Bundled agents: " + agents.size.toString())
        io.println("Target directory: " + target)
        io.println("Written: " + written.size.toString())
        if (!skipped.isEmpty()) {
            io.println("Skipped existing: " + skipped.size.toString() + " (use --force to overwrite)")
        }
        for (path in written) {
            io.println("  + " + path)
        }
        for (path in skipped) {
            io.println("  = " + path)
        }
    }
    0
}

func serializeBundledAgent(agent: ProductBundledAgentDefinition): String {
    var result = "---\n" + "name: " + yamlQuote(agent.name) + "\n" + "description: " + yamlQuote(agent.description) +
        "\n"
    if (agent.spawns != "") {
        result += "spawns: " + yamlQuote(agent.spawns) + "\n"
    }
    if (agent.model != "") {
        result += "model: " + yamlQuote(agent.model) + "\n"
    }
    if (agent.thinkingLevel != "") {
        result += "thinkingLevel: " + yamlQuote(agent.thinkingLevel) + "\n"
    }
    result + "---\n\n" + agent.prompt.trimAscii() + "\n"
}

func cliStringList(values: Array<String>): AgentValue {
    let items = ArrayList<AgentValue>()
    for (value in values) {
        items.add(textValue(value))
    }
    listValue(items.toArray())
}

func cliPositionals(
    arguments: Array<String>,
    flags: Array<String>
): Array<String> {
    let values = ArrayList<String>()
    var skipNext = false
    var positionalOnly = false
    for (argument in arguments) {
        if (positionalOnly) { values.add(argument)
            continue }
        if (argument == "--") { positionalOnly = true
            continue }
        if (skipNext) {
            skipNext = false
            continue
        }
        if (argument == "--approval-mode" || argument == "--mode" || argument == "--model" || argument == "--cwd" ||
            argument == "--max-time" || argument == "--model-attempt-recovery" ||
            argument == "--model-stream-idle-timeout-ms" || argument == "--model-stream-fault-profile") {
            skipNext = true
            continue
        }
        var isFlag = argument.startsWith("-")
        for (flag in flags where argument == flag) {
            isFlag = true
        }
        if (!isFlag) {
            values.add(argument)
        }
    }
    values.toArray()
}

func stripCliCommand(arguments: Array<String>): Array<String> {
    if (arguments.size <= 1) {
        return arguments
    }
    let values = ArrayList<String>()
    values.add(arguments[0])
    for (index in 2..arguments.size) {
        values.add(arguments[index])
    }
    values.toArray()
}

func filteredModels(
    session: ApplicationSession,
    pattern: String,
    broad: Bool
): Array<String> {
    let values = ArrayList<String>()
    let needle = pattern.toAsciiLower()
    for (model in session.models()) {
        let provider = session.modelProvider(model)
        let raw = session.rawModelId(model)
        let matches = needle == "" || if (!broad && provider.toAsciiLower() == needle) {
            true
        } else {
            model.toAsciiLower().contains(needle) || provider.toAsciiLower().contains(needle) ||
                raw.toAsciiLower().contains(needle)
        }
        if (matches) {
            insertCliModel(values, model)
        }
    }
    values.toArray()
}

func insertCliModel(values: ArrayList<String>, model: String): Unit {
    values.add(model)
    var index = values.size - 1
    while (index > 0 && values[index] < values[index - 1]) {
        let previous = values[index - 1]
        values[index - 1] = values[index]
        values[index] = previous
        index -= 1
    }
}

func countProviderModels(
    session: ApplicationSession,
    models: Array<String>,
    provider: String
): Int64 {
    var count: Int64 = 0
    for (model in models where session.modelProvider(model) == provider) {
        count += 1
    }
    count
}

func cliModelValue(
    session: ApplicationSession,
    model: String
): AgentValue {
    let provider = session.modelProvider(model)
    let raw = session.rawModelId(model)
    let metadata = session.modelMetadata(model)
    objectValue(
        [
            ValueField("provider", textValue(provider)),
            ValueField("id", textValue(raw)),
            ValueField(
                "selector",
                textValue(provider + "/" + raw)
            ),
            ValueField("name", textValue(raw)),
            ValueField("contextWindow", cliOptionalModelInteger(match (metadata) {
                case Some(value) => value.contextWindow
                case None => None
            })),
            ValueField("maxTokens", cliOptionalModelInteger(match (metadata) {
                case Some(value) => value.maxOutputTokens
                case None => None
            })),
            ValueField("reasoning", cliModelBoolean(match (metadata) {
                case Some(value) => Some(match (value.thinking) {
                    case Some(capabilities) => capabilities.mode != ThinkingControlMode.NoThinking
                    case None => false
                })
                case None => None
            })),
            ValueField("thinking", nullValue()),
            ValueField("input", cliModelInput(match (metadata) {
                case Some(value) => value.inputModalities
                case None => None
            })),
            ValueField(
                "cost",
                objectValue(
                    [
                        ValueField("input", cliModelCost(match (metadata) {
                            case Some(value) => value.inputCostMicrosPerMillion
                            case None => None
                        })),
                        ValueField("output", cliModelCost(match (metadata) {
                            case Some(value) => value.outputCostMicrosPerMillion
                            case None => None
                        })),
                        ValueField("cacheRead", cliModelCost(match (metadata) {
                            case Some(value) => value.cacheReadCostMicrosPerMillion
                            case None => None
                        })),
                        ValueField("cacheWrite", cliModelCost(match (metadata) {
                            case Some(value) => value.cacheWriteCostMicrosPerMillion
                            case None => None
                        }))
                    ]
                )
            )
        ]
    )
}

func cliOptionalModelInteger(value: ?Int64): AgentValue {
    match (value) {
        case Some(number) => integerValue(number)
        case None => nullValue()
    }
}

func cliModelBoolean(value: ?Bool): AgentValue {
    match (value) {
        case Some(enabled) => boolValue(enabled)
        case None => boolValue(false)
    }
}

func cliModelInput(value: ?Array<String>): AgentValue {
    match (value) {
        case Some(items) =>
            let values = ArrayList<AgentValue>()
            for (item in items) { values.add(textValue(item)) }
            listValue(values.toArray())
        case None => listValue([textValue("text")])
    }
}

func cliModelCost(value: ?Int64): AgentValue {
    match (value) {
        case Some(micros) => numberValue((Float64(micros) / 1000000.0).toString())
        case None => integerValue(0)
    }
}

func runSetup(): Int64 {
    let root = defaultProductHome()
    match (ensureProductLayout(root)) {
        case Result.Ok(_) => ()
        case Result.Err(error) =>
            printError(error)
            return 1
    }
    println("axyndra provider setup")
    println("Choose from the menus; no provider protocol knowledge is required.")
    let providerKind = chooseProvider()
    let protocol = if (providerKind == "custom") {
        chooseCompatibleProtocol()
    } else if (providerKind == "anthropic") {
        "messages"
    } else {
        "responses"
    }
    let baseUrl = if (providerKind == "custom") {
        readHttpUrl("Base URL (without /v1, for example http://127.0.0.1:11434)")
    } else {
        chooseOfficialBaseUrl(providerKind)
    }
    let profileId = readProfileId(
        root,
        suggestedProfileId(providerKind, baseUrl)
    )
    let model = chooseModel(providerKind)
    let apiKeyEnv = readSetting(
        "API key environment variable name (used if no key is stored)",
        suggestedApiKeyEnvironment(profileId, providerKind, baseUrl)
    )
    let configuredModel = profileId + "/" + model
    let target = root + "/config.yml"
    try {
        let dialect = configuredDialectForSetup(providerKind, protocol, baseUrl)
        match (upsertProviderProfile(
            root,
            ProviderProfile(
                profileId,
                providerKind,
                protocol,
                baseUrl,
                apiKeyEnv,
                dialect: dialect
            )
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                println("error: " + error.message)
                return 1
        }
        match (upsertModelCatalogEntry(
            root,
            ModelCatalogEntry(
                model,
                providerProfile: profileId,
                thinking: Some(configuredThinkingForDialect(dialect))
            )
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                println("error: " + error.message)
                return 1
        }
        let credentialMode = match (configureSetupCredential(
            root,
            profileId,
            apiKeyEnv
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                println("error: " + error.message)
                return 1
        }
        match (updateProductConfig(root, [
            ProductConfigEdit("default_model", ProductConfigScalar.Text(configuredModel))
        ])) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                println("error: " + error.message)
                return 1
        }
        println("wrote " + target)
        println("Provider profile: " + profileId)
        println("Model: " + configuredModel)
        if (credentialMode == "environment") {
            println("Before starting axyndra, set your API key:\n" + "  export " + apiKeyEnv + "='your-api-key'")
        } else if (credentialMode == "later") {
            println("No API key was configured. Run setup again or set " + apiKeyEnv + " before starting axyndra.")
        } else {
            println("API key stored for provider profile: " + profileId)
        }
        0
    } catch (error: Exception) {
        println("error: cannot write configuration: " + error.message)
        1
    }
}

func suggestedProfileId(provider: String, baseUrl: String): String {
    if (provider == "anthropic" && baseUrl == "https://api.anthropic.com") {
        "anthropic-official"
    } else if (provider == "openai" && baseUrl == "https://api.openai.com") {
        "openai-official"
    } else if (provider == "anthropic") {
        "anthropic-custom"
    } else if (provider == "openai") {
        "openai-custom"
    } else {
        "openai-compatible"
    }
}

func readProfileId(root: String, fallback: String): String {
    while (true) {
        let value = readSetting(
            "Provider profile ID (unique name for endpoint and API key)",
            fallback
        )
        match (providerCredentialPath(root, value)) {
            case Result.Ok(_) => return value
            case Result.Err(error) => println(error.message)
        }
    }
    fallback
}

func suggestedApiKeyEnvironment(
    profileId: String,
    provider: String,
    baseUrl: String
): String {
    if (provider == "anthropic" && baseUrl == "https://api.anthropic.com") {
        return "ANTHROPIC_API_KEY"
    }
    if (provider == "openai" && baseUrl == "https://api.openai.com") {
        return "OPENAI_API_KEY"
    }
    profileId.toAsciiUpper().replace("-", "_").replace(".", "_") + "_API_KEY"
}

func configureSetupCredential(
    root: String,
    profileId: String,
    apiKeyEnv: String
): Result<String> {
    while (true) {
        println("")
        println("Configure the API key for " + profileId + ":")
        println("  1) Enter and store it now   saved with file mode 0600")
        println("  2) Use " + apiKeyEnv + " environment variable")
        println("  3) Configure later")
        let choice = readSetting("API key", "1").toAsciiLower()
        match (choice) {
            case "1" | "store" =>
                let credential = match (readSecretFromTerminal()) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                match (saveProviderCredential(
                    root,
                    profileId,
                    credential
                )) {
                    case Result.Ok(_) => return Result.Ok("stored")
                    case Result.Err(error) => return Result.Err(error)
                }
            case "2" | "environment" | "env" => return Result.Ok("environment")
            case "3" | "later" => return Result.Ok("later")
            case _ => println("Please enter 1, 2, or 3.")
        }
    }
    Result.Ok("later")
}

func readSecretFromTerminal(): Result<String> {
    let script = "old=$(stty -g < /dev/tty) || exit 1; " + "trap 'stty \"$old\" < /dev/tty' EXIT; " +
        "stty -echo < /dev/tty || exit 1; " + "printf 'API key (input hidden): ' > /dev/tty; " +
        "IFS= read -r secret < /dev/tty || exit 1; " + "printf '\\n' > /dev/tty; " + "printf '%s' \"$secret\""
    let (code, output, error) = executeWithOutput(
        "/bin/bash",
        ["--noprofile", "--norc", "-c", script]
    )
    if (code != 0) {
        return Result.Err(
            AgentError(
                AgentErrorKind.Configuration,
                "credential.terminal_unavailable",
                "cannot read a hidden API key from this terminal; " + "choose the environment-variable option instead",
                fields: [
                    ErrorField(
                        "stderr",
                        String.fromUtf8(error).trimAscii()
                    )
                ]
            )
        )
    }
    let credential = String.fromUtf8(output)
    if (credential.trimAscii() == "") {
        Result.Err(
            AgentError(
                AgentErrorKind.Configuration,
                "credential.empty",
                "API key must not be empty"
            )
        )
    } else {
        Result.Ok(credential)
    }
}

func chooseProvider(): String {
    while (true) {
        println("")
        println("Choose a provider:")
        println("  1) OpenAI              recommended; uses Responses API")
        println("  2) Anthropic           uses Messages API")
        println("  3) OpenAI-compatible   custom or local endpoint")
        let choice = readSetting("Provider", "1").toAsciiLower()
        match (choice) {
            case "1" | "openai" => return "openai"
            case "2" | "anthropic" => return "anthropic"
            case "3" | "custom" | "openai-compatible" => return "custom"
            case _ => println("Please enter 1, 2, or 3.")
        }
    }
    "openai"
}

func chooseOfficialBaseUrl(provider: String): String {
    let official = if (provider == "anthropic") {
        "https://api.anthropic.com"
    } else {
        "https://api.openai.com"
    }
    while (true) {
        println("")
        println("Choose an endpoint:")
        println("  1) Official endpoint   " + official)
        println("  2) Custom endpoint     proxy, gateway, or private deployment")
        let choice = readSetting("Endpoint", "1").toAsciiLower()
        match (choice) {
            case "1" | "official" => return official
            case "2" | "custom" => return readHttpUrl("Base URL (without /v1, for example https://gateway.example.com)")
            case _ => println("Please enter 1 or 2.")
        }
    }
    official
}

func chooseCompatibleProtocol(): String {
    while (true) {
        println("")
        println("Choose the API protocol supported by your endpoint:")
        println("  1) Chat Completions    supported by most compatible endpoints")
        println("  2) Responses           select only if the endpoint documents it")
        let choice = readSetting("Protocol", "1").toAsciiLower()
        match (choice) {
            case "1" | "completions" | "chat-completions" => return "completions"
            case "2" | "responses" => return "responses"
            case _ => println("Please enter 1 or 2.")
        }
    }
    "completions"
}

func chooseModel(provider: String): String {
    while (true) {
        println("")
        if (provider == "openai") {
            println("Choose a model:")
            println("  1) gpt-5")
            println("  2) gpt-5-mini")
            println("  3) Enter another model ID")
            let choice = readSetting("Model", "1").toAsciiLower()
            match (choice) {
                case "1" | "gpt-5" => return "gpt-5"
                case "2" | "gpt-5-mini" => return "gpt-5-mini"
                case "3" | "custom" => return readRequired("Model ID (copy it from your provider dashboard)")
                case _ => println("Please enter 1, 2, or 3.")
            }
        } else if (provider == "anthropic") {
            println("Choose a model:")
            println("  1) claude-sonnet-4-20250514")
            println("  2) claude-opus-4-20250514")
            println("  3) Enter another model ID")
            let choice = readSetting("Model", "1").toAsciiLower()
            match (choice) {
                case "1" | "claude-sonnet-4-20250514" => return "claude-sonnet-4-20250514"
                case "2" | "claude-opus-4-20250514" => return "claude-opus-4-20250514"
                case "3" | "custom" => return readRequired("Model ID (copy it from your provider dashboard)")
                case _ => println("Please enter 1, 2, or 3.")
            }
        } else {
            return readRequired("Model ID (copy it from your endpoint documentation)")
        }
    }
    ""
}

func readRequired(label: String): String {
    while (true) {
        let value = readSetting(label, "")
        if (value != "") {
            return value
        }
        println("This value is required.")
    }
    ""
}

func readHttpUrl(label: String): String {
    while (true) {
        let value = readRequired(label).removeSuffix("/")
        if (value.startsWith("http://") || value.startsWith("https://")) {
            return value
        }
        println("Enter a URL beginning with http:// or https://.")
    }
    ""
}

func readSetting(label: String, fallback: String): String {
    print(label + if (fallback == "") {
        ": "
    } else {
        " [" + fallback + "]: "
    })
    let value = match (getStdIn().readln()) {
        case Some(text) => text.trimAscii()
        case None => ""
    }
    if (value == "") {
        fallback
    } else {
        value
    }
}

func yamlQuote(value: String): String {
    "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
}

func hasArgument(arguments: Array<String>, expected: String): Bool {
    for (argument in arguments) {
        if (argument == "--") { break }
        if (argument == expected) { return true }
    }
    false
}

func argumentParseError(arguments: Array<String>): ?String {
    let valueOptions = [
        "--approval-mode",
        "--mode",
        "--model",
        "--cwd",
        "--max-time",
        "--model-attempt-recovery",
        "--model-stream-idle-timeout-ms",
        "--model-stream-fault-profile",
        "--shell-network-mode"
    ]
    let flagOptions = [
        "--fixture",
        "--print",
        "-p",
        "--help",
        "-h",
        "--version",
        "-v"
    ]
    var index = 1
    var positionalOnly = false
    while (index < arguments.size) {
        let argument = arguments[index]
        if (positionalOnly) {
            index++
            continue
        }
        if (argument == "--") {
            positionalOnly = true
            index++
            continue
        }
        var consumesValue = false
        for (option in valueOptions where argument == option) {
            consumesValue = true
        }
        if (consumesValue) {
            if (index + 1 >= arguments.size || arguments[index + 1] == "--") {
                return Some("missing value for flag: " + argument)
            }
            index += 2
            continue
        }
        var known = false
        for (option in flagOptions where argument == option) {
            known = true
        }
        for (option in valueOptions where argument.startsWith(option + "=")) {
            known = true
            if (argument == option + "=") {
                return Some("missing value for flag: " + option)
            }
        }
        if (!known && argument.startsWith("-")) {
            return Some("unknown flag: " + argument)
        }
        index++
    }
    let recovery = argumentValue(arguments, "--model-attempt-recovery")
    if (recovery != "" && recovery != "disabled" && recovery != "recovery-v1") {
        return Some("invalid --model-attempt-recovery: " + recovery)
    }
    let streamIdleTimeout = argumentValue(arguments, "--model-stream-idle-timeout-ms")
    if (streamIdleTimeout != "") {
        let parsed = try { Int64.parse(streamIdleTimeout) } catch (_: Exception) { 0 }
        if (parsed < 1) {
            return Some("--model-stream-idle-timeout-ms must be a positive integer")
        }
    }
    let fault = argumentValue(arguments, "--model-stream-fault-profile")
    if (fault != "" && fault != "incomplete-text-attempt-1-v1" &&
        fault != "incomplete-text-attempt-1-idle-v1" &&
        fault != "incomplete-text-attempts-1-2-idle-v1") {
        return Some("invalid --model-stream-fault-profile: " + fault)
    }
    None
}
func shellNetworkModeFrom(arguments: Array<String>): Result<?ShellNetworkMode> {
    let raw = argumentValue(arguments, "--shell-network-mode")
    if (raw.trimAscii() == "") {
        return Result.Ok(None)
    }
    match (parseShellNetworkMode(raw)) {
        case Result.Ok(value) => Result.Ok(Some(value))
        case Result.Err(error) => Result.Err(error)
    }
}


func withoutRuntimeArguments(arguments: Array<String>): Array<String> {
    let result = ArrayList<String>()
    var skipNext = false
    var positionalOnly = false
    for (argument in arguments) {
        if (skipNext) {
            skipNext = false
            continue
        }
        if (argument == "--" && !positionalOnly) {
            positionalOnly = true
            continue
        }
        if (positionalOnly) {
            result.add(argument)
            continue
        }
        if (argument == "--approval-mode" || argument == "--mode" || argument == "--model" || argument == "--cwd" ||
            argument == "--max-time" || argument == "--model-attempt-recovery" ||
            argument == "--model-stream-idle-timeout-ms" ||
            argument == "--model-stream-fault-profile" ||
            argument == "--shell-network-mode") {
            skipNext = true
            continue
        }
        if (argument == "--fixture" || argument == "--print" ||
            argument == "-p" || argument == "--help" || argument == "-h" || argument == "--version" || argument == "-v" ||
            argument.startsWith("--approval-mode=") || argument.startsWith("--mode=") || argument.startsWith("--model=") ||
            argument.startsWith("--cwd=") || argument.startsWith("--max-time=") ||
            argument.startsWith("--model-attempt-recovery=") ||
            argument.startsWith("--model-stream-idle-timeout-ms=") ||
            argument.startsWith("--model-stream-fault-profile=") ||
            argument.startsWith("--shell-network-mode=")) {
            continue
        }
        result.add(argument)
    }
    result.toArray()
}

func modelStreamFaultProfileFrom(arguments: Array<String>): ?ModelStreamFaultProfile {
    match (argumentValue(arguments, "--model-stream-fault-profile")) {
        case "" => None
        case "incomplete-text-attempt-1-v1" => Some(ModelStreamFaultProfile(
            "IncompleteStreamFaultProfileV1",
            triggerAttemptOrdinal: 1,
            partialText: "controlled incomplete stream"
        ))
        case "incomplete-text-attempt-1-idle-v1" => Some(ModelStreamFaultProfile(
            "IncompleteStreamIdleFaultProfileV1",
            triggerAttemptOrdinal: 1,
            partialText: "controlled idle stream",
            faultDelayMillis: 3000
        ))
        case "incomplete-text-attempts-1-2-idle-v1" => Some(ModelStreamFaultProfile(
            "IncompleteStreamIdleFaultProfileAttempts1And2V1",
            triggerAttemptOrdinal: 1,
            maxInjectedAttempts: 2,
            partialText: "controlled idle stream",
            faultDelayMillis: 3000
        ))
        case _ => throw IllegalArgumentException("invalid model stream fault profile")
    }
}

func argumentValue(arguments: Array<String>, name: String): String {
    var expectValue = false
    for (argument in arguments) {
        if (argument == "--") { break }
        if (expectValue) {
            return argument
        }
        if (argument == name) {
            expectValue = true
            continue
        }
        let prefix = name + "="
        if (argument.startsWith(prefix)) {
            return argument[prefix.size..]
        }
    }
    ""
}

func argumentValueOr(
    arguments: Array<String>,
    name: String,
    fallback: String
): String {
    let value = argumentValue(arguments, name)
    if (value == "") {
        fallback
    } else {
        value
    }
}

// Parses --max-time as seconds or a duration like "5s", "10m", "1h"
// (OMP-compatible). Returns 0 (no wall-clock limit) when absent; an
// unparsable explicit value falls back to the default limit.
func wallTimeoutFrom(arguments: Array<String>): Int64 {
    let value = argumentValue(arguments, "--max-time")
    if (value == "") {
        return 0
    }
    var multiplier: Int64 = 1
    var number = value
    if (number.endsWith("h")) {
        multiplier = 3600
        number = number[0..number.size - 1]
    } else if (number.endsWith("m")) {
        multiplier = 60
        number = number[0..number.size - 1]
    } else if (number.endsWith("s")) {
        multiplier = 1
        number = number[0..number.size - 1]
    }
    let seconds = try {
        Int64.parse(number.trimAscii())
    } catch (_: Exception) {
        0
    }
    if (seconds < 1) {
        return 0
    }
    seconds * multiplier * 1000
}

func modelAttemptRecoveryFrom(arguments: Array<String>): ModelAttemptRecoveryPolicy {
    let authoredMode = argumentValue(arguments, "--model-attempt-recovery")
    let mode = match (authoredMode) {
        case "" | "recovery-v1" => ModelAttemptRecoveryMode.RecoveryV1
        case "disabled" => ModelAttemptRecoveryMode.Disabled
        case _ => throw IllegalArgumentException("invalid model attempt recovery mode")
    }
    let authoredIdleTimeout = argumentValue(arguments, "--model-stream-idle-timeout-ms")
    let timeout = if (authoredIdleTimeout != "") {
        Int64.parse(authoredIdleTimeout)
    } else {
        120000
    }
    ModelAttemptRecoveryPolicy(
        mode: mode,
        streamIdleMillis: timeout,
        maxRecoveryRetries: match (mode) {
            case ModelAttemptRecoveryMode.Disabled => 0
            case ModelAttemptRecoveryMode.RecoveryV1 => 1
        }
    )
}

func approvalModeFrom(arguments: Array<String>): ApprovalMode {
    match (approvalRoutingModeFrom(arguments)) {
        case Some(ApprovalRoutingMode.Trusted) => ApprovalMode.Yolo
        case _ => ApprovalMode.AlwaysAsk
    }
}

func approvalRoutingModeFrom(arguments: Array<String>): ?ApprovalRoutingMode {
    var expectValue = false
    for (argument in arguments) {
        if (argument == "--") { break }
        if (expectValue) {
            return approvalRoutingModeValue(argument)
        }
        if (argument == "--approval-mode") {
            expectValue = true
            continue
        }
        if (argument.startsWith("--approval-mode=")) {
            return approvalRoutingModeValue(argument[16..])
        }
    }
    None
}

func approvalRoutingModeValue(value: String): ?ApprovalRoutingMode {
    match (value.trimAscii().toAsciiLower()) {
        case "manual" => Some(ApprovalRoutingMode.Manual)
        case "ai" => Some(ApprovalRoutingMode.Ai)
        case "never" => Some(ApprovalRoutingMode.Never)
        case "trusted" => Some(ApprovalRoutingMode.Trusted)
        case _ => None
    }
}

class ProtocolInputPoll {
    let line: ?String
    let eof: Bool

    init(line!: ?String = None, eof!: Bool = false) {
        this.line = line
        this.eof = eof
    }
}

class PollingJsonlInput {
    private let maxLineBytes: Int64 = 8388608
    private var pending = ArrayList<Byte>()
    private var ready: Array<String> = []
    private var readyIndex: Int64 = 0

    func poll(timeoutMillis: Int32): ProtocolInputPoll {
        if (readyIndex < ready.size) {
            let line = ready[readyIndex]
            readyIndex += 1
            return ProtocolInputPoll(line: Some(line))
        }
        if (!waitReadableFd(0, timeoutMillis)) { return ProtocolInputPoll() }
        match (readFdChunk(0)) {
            case None =>
                if (!pending.isEmpty()) {
                    let bytes = pending.toArray()
                    pending = ArrayList<Byte>()
                    let end = if (!bytes.isEmpty() && bytes[bytes.size - 1] == b'\r') {
                        bytes.size - 1
                    } else {
                        bytes.size
                    }
                    return ProtocolInputPoll(line: Some(String.fromUtf8(bytes[..end])))
                }
                ProtocolInputPoll(eof: true)
            case Some(chunk) =>
                let frames = ArrayList<String>()
                for (byte in chunk) {
                    if (byte == b'\n') {
                        let bytes = pending.toArray()
                        let end = if (!bytes.isEmpty() && bytes[bytes.size - 1] == b'\r') {
                            bytes.size - 1
                        } else {
                            bytes.size
                        }
                        frames.add(String.fromUtf8(bytes[..end]))
                        pending = ArrayList<Byte>()
                    } else {
                        if (pending.size >= maxLineBytes) {
                            pending = ArrayList<Byte>()
                            throw ProcessError(
                                ProcessErrorKind.Frame,
                                "line frame exceeds configured byte limit"
                            )
                        }
                        pending.add(byte)
                    }
                }
                ready = frames.toArray()
                readyIndex = 0
                if (ready.isEmpty()) { return ProtocolInputPoll() }
                let line = ready[0]
                readyIndex = 1
                ProtocolInputPoll(line: Some(line))
        }
    }
}

func serveOwnedAcpBody113(server: ProductAcpServer, input: AcpOwnedJsonlInput113): Int64 {
    var status: Int64 = 0
    try {
        while (true) {
            let _ = server.collectOwnedCheckpointFailures113()
            let (eof, line) = input.poll113(50)
            if (eof) { break }
            match (line) {
                case None => continue
                case Some(actual) =>
                    // Main performs no bare String handle/write. The whole
                    // parser/dispatch/output helper returns before source ACK.
                    match (server.handleOwnedInput113(actual)) {
                        case Result.Err(_) => status = 1; break
                        case Result.Ok(_) => () }
            }
            if (!server.afterOwnedInputHelperReturn113(line.getOrThrow())) { status = 1; break }
            if (!input.retireHandledInputAfterHelperReturn113()) { status = 1; break }
            server.flushDeferred()
        }
    } catch (error: OwnedCanonicalPaidFailure113) {
        server.retainFrontendFailure113(error.takeConsumer())
        let _ = server.writeFrontendFailure113({ frame => writeOwnedAcpFrontendFailure113(frame) })
        status = 1
    } catch (error: OwnedCanonicalDataFailure113) {
        server.retainFrontendFailure113(error.error)
        let _ = server.writeFrontendFailure113({ frame => writeOwnedAcpFrontendFailure113(frame) })
        status = 1
    } catch (error: Exception) {
        server.retainFrontendFailure113(error)
        let _ = server.writeFrontendFailure113({ frame => writeOwnedAcpFrontendFailure113(frame) })
        status = 1
    }
    match (server.closeOwned113()) {
        case AcpOwnedCloseStatus113.Complete => status
        case AcpOwnedCloseStatus113.Failed =>
            // Full original close error and every real secondary are produced
            // and offered only once; flush/helper return precedes any ACK.
            let _ = server.writeOwnedClose113({ frame => writeOwnedAcpClose113(frame) })
            1
        case AcpOwnedCloseStatus113.FailedConsumed => 1
        case AcpOwnedCloseStatus113.Held => 1 }
}

func writeOwnedAcpClose113(frame: AcpOwnedResponse113, io!: CliIo180 = consoleCliIo180): OwnedFailureDataOutcome113<Unit> {
    let answer = writeOwnedAcpCloseHelper113(frame, io: io)
    match (answer) {
        case OwnedFailureDataOutcome113.Failure(_) => answer
        case OwnedFailureDataOutcome113.Value(_) =>
            try {
                match (frame.acknowledgeAfterWriteHelperReturn113()) {
                    case Result.Ok(_) => OwnedFailureDataOutcome113<Unit>.Value(())
                    case Result.Err(error) => frame.captureOutputFailure113(error) }
            } catch (failure: OwnedCanonicalPaidFailure113) { frame.captureOutputFailure113(failure.takeConsumer()) }
            catch (failure: OwnedCanonicalDataFailure113) { frame.captureOutputFailure113(failure.error) }
            catch (failure: Exception) { frame.captureOutputException113(failure) }
    }
}
func writeOwnedAcpFrontendFailure113(frame: AcpOwnedResponse113, io!: CliIo180 = consoleCliIo180): OwnedFailureDataOutcome113<Unit> {
    let answer = writeOwnedAcpFrontendFailureHelper113(frame, io: io)
    match (answer) {
        case OwnedFailureDataOutcome113.Failure(_) => answer
        case OwnedFailureDataOutcome113.Value(_) =>
            try {
                match (frame.acknowledgeAfterWriteHelperReturn113()) {
                    case Result.Ok(_) => OwnedFailureDataOutcome113<Unit>.Value(())
                    case Result.Err(error) => frame.captureOutputFailure113(error) }
            } catch (failure: OwnedCanonicalPaidFailure113) { frame.captureOutputFailure113(failure.takeConsumer()) }
            catch (failure: OwnedCanonicalDataFailure113) { frame.captureOutputFailure113(failure.error) }
            catch (failure: Exception) { frame.captureOutputException113(failure) }
    }
}
func writeOwnedAcpFrontendFailureHelper113(frame: AcpOwnedResponse113, io!: CliIo180 = consoleCliIo180): OwnedFailureDataOutcome113<Unit> {
    frame.withResponse113({ value => io.flush(); io.eprintln(value); Result<Unit>.Ok(()) })
}

func writeOwnedAcpCloseHelper113(frame: AcpOwnedResponse113, io!: CliIo180 = consoleCliIo180): OwnedFailureDataOutcome113<Unit> {
    frame.withResponse113({ value => io.flush(); io.println(value); Result<Unit>.Ok(()) })
}

func acpSessionProductConfig(
    config: ProductConfig,
    workspaceRoot: String
): ProductConfig {
    ProductConfig(
        settingsRoot: config.settingsRoot,
        stateRoot: config.stateRoot,
        workspaceRoot: workspaceRoot,
        distributionRoot: config.distributionRoot,
        fixture: config.fixture,
        unsafeDirectLaunchForTests: config.unsafeDirectLaunchForTests,
        approvalMode: config.approvalMode,
        approvalRoutingModeOverride: config.approvalRoutingModeOverride,
        shellNetworkModeOverride: config.shellNetworkModeOverride,
        modelOverride: config.modelOverride,
        asyncEnabled: config.asyncEnabled,
        wallTimeoutMillis: config.wallTimeoutMillis,
        modelAttemptRecovery: config.modelAttemptRecovery,
        modelStreamFaultProfile: config.modelStreamFaultProfile,
        compactionOverride: config.compactionOverride,
        startupMode: config.startupMode,
        extensionSignatureVerifier: config.extensionSignatureVerifier,
        fixtureTransactionCommitMonitor: config.fixtureTransactionCommitMonitor,
        fixtureDerivedSettlementFailureObserver: config.fixtureDerivedSettlementFailureObserver
    )
}

// This control cell is separately prepaid in the actual output share.
class OwnedRpcFailureAnswer113 {
    var value = OwnedFailureDataOutcome113<Unit>.Value(())
}

class RpcOutput <: OwnedRpcFrameOutput & OwnedRpcFailureOutput113 & AcpOwnedResponseOutput113 {
    private let lock = Mutex()
    private let io: CliIo180
    init(io!: CliIo180 = consoleCliIo180) { this.io = io }

    public func writeAcpResponse113(value: AcpOwnedResponse113): OwnedFailureDataOutcome113<Unit> {
        let answer = writeAcpResponseHelper113(value)
        match (answer) {
            case OwnedFailureDataOutcome113.Failure(_) => answer
            case OwnedFailureDataOutcome113.Value(_) =>
                try {
                    match (value.acknowledgeAfterWriteHelperReturn113()) {
                        case Result.Err(error) => value.captureOutputFailure113(error)
                        case Result.Ok(_) => OwnedFailureDataOutcome113<Unit>.Value(()) }
                } catch (failure: OwnedCanonicalPaidFailure113) { value.captureOutputFailure113(failure.takeConsumer()) }
                catch (failure: OwnedCanonicalDataFailure113) { value.captureOutputFailure113(failure.error) }
                catch (failure: Exception) { value.captureOutputException113(failure) }
        }
    }
    private func writeAcpResponseHelper113(value: AcpOwnedResponse113): OwnedFailureDataOutcome113<Unit> {
        lock.lock()
        try { value.withResponse113({ frame => io.flush(); io.println(frame); Result<Unit>.Ok(()) }) }
        finally { lock.unlock() }
    }

    public func write(frame: OwnedRpcOutputFrame): Result<Unit> {
        lock.lock()
        let result = try {
            frame.withFrame({ value => io.flush(); io.println(value); Result.Ok(()) })
        } finally { lock.unlock() }
        match (result) { case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => frame.closeAfterFrameRetirement() }
    }

    public func writeFailureFrame113(value: OwnedFailureRunPublication113,
        render: (AgentError, (Int64) -> Result<Unit>) -> Result<String>): OwnedFailureDataOutcome113<Unit> {
        lock.lock()
        let answer = try { writeFailurePublicationFrame113(value, render) } finally { lock.unlock() }
        match (answer) {
            case OwnedFailureDataOutcome113.Failure(failure) => OwnedFailureDataOutcome113<Unit>.Failure(failure)
            case OwnedFailureDataOutcome113.Value(_) =>
                // Paid holder, error, encoder, String and stdout helper frames
                // have returned before this distinct output share can ACK.
                match (value.acknowledgeAfterConsumption()) {
                    case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
                    case Result.Ok(_) => OwnedFailureDataOutcome113<Unit>.Value(()) }
        }
    }
    public func writeFailureFrame113(value: OwnedFailureDataConsumer113,
        render: (AgentError, (Int64) -> Result<Unit>) -> Result<String>): OwnedFailureDataOutcome113<Unit> {
        lock.lock()
        let answer = try { writeFailureDataFrame113(value, render) } finally { lock.unlock() }
        match (answer) {
            case OwnedFailureDataOutcome113.Failure(failure) => OwnedFailureDataOutcome113<Unit>.Failure(failure)
            case OwnedFailureDataOutcome113.Value(_) =>
                match (value.acknowledgeAfterConsumption()) {
                    case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
                    case Result.Ok(_) => OwnedFailureDataOutcome113<Unit>.Value(()) }
        }
    }
    private func writeFailurePublicationFrame113(value: OwnedFailureRunPublication113,
        render: (AgentError, (Int64) -> Result<Unit>) -> Result<String>): OwnedFailureDataOutcome113<Unit> {
        match (value.withError({ _, fund => fund(4096) })) {
            case Result.Err(error) => throw OwnedCanonicalDataFailure113(error); case Result.Ok(_) => () }
        let answer = OwnedRpcFailureAnswer113()
        let borrowed = value.withError({ error, fund =>
            answer.value = writeFailureLoan113(error, fund, render,
                { failed => value.captureFailure113<Unit>(failed) })
            Result<Unit>.Ok(())
        })
        match (borrowed) { case Result.Err(error) => throw OwnedCanonicalDataFailure113(error); case Result.Ok(_) => answer.value }
    }
    private func writeFailureDataFrame113(value: OwnedFailureDataConsumer113,
        render: (AgentError, (Int64) -> Result<Unit>) -> Result<String>): OwnedFailureDataOutcome113<Unit> {
        match (value.withError({ _, fund =>
            match (fund(4096)) {
                case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
                case Result.Ok(_) => ()
            }
        })) { case Result.Err(error) => throw OwnedCanonicalDataFailure113(error); case Result.Ok(_) => () }
        let answer = OwnedRpcFailureAnswer113()
        let borrowed = value.withError({ error, fund =>
            answer.value = writeFailureLoan113(error, fund, render,
                { failed => value.captureFailure113<Unit>(failed) })
        })
        match (borrowed) { case Result.Err(error) => throw OwnedCanonicalDataFailure113(error); case Result.Ok(_) => answer.value }
    }
    private func writeFailureLoan113(error: AgentError, fund: (Int64) -> Result<Unit>,
        render: (AgentError, (Int64) -> Result<Unit>) -> Result<String>,
        capture: (AgentError) -> OwnedFailureDataOutcome113<Unit>): OwnedFailureDataOutcome113<Unit> {
        try {
            match (render(error, fund)) {
                case Result.Err(failure) => capture(failure)
                case Result.Ok(frame) =>
                    io.flush()
                    io.println(frame)
                    OwnedFailureDataOutcome113<Unit>.Value(())
            }
        } catch (failure: OwnedCanonicalPaidFailure113) {
            OwnedFailureDataOutcome113<Unit>.Failure(failure.takeConsumer())
        } catch (failure: OwnedCanonicalDataFailure113) {
            // Preserve all original AgentError fields while this typed
            // producer and the actual input borrow are still alive.
            capture(failure.error)
        } catch (failure: Exception) {
            let bytes = failure.message.size
            if (bytes > (Int64.Max - 32768) / 8) {
                throw IllegalStateException("failure output exception payment overflow") }
            match (fund(32768 + bytes * 8)) {
                case Result.Err(pressure) => throw OwnedCanonicalDataFailure113(pressure)
                case Result.Ok(_) => () }
            capture(AgentError(AgentErrorKind.Transport, "rpc.failure_frame_write_failed",
                failure.message, retryable: false, fallbackAllowed: false))
        }
    }

    func write(frame: String): Unit {
        lock.lock()
        try {
            io.flush()
            io.println(frame)
        } finally {
            lock.unlock()
        }
    }
}

func runPrint(product: ProductRuntime, prompt: String, failures: CliFailureOutput113, io!: CliIo180 = consoleCliIo180,
    session180!: ?ApplicationSession = None<ApplicationSession>): Int64 {
    let session = session180 ?? product.applicationSession()
    failures.bindSession(session)
    let stream = StreamState()
    io.subscribeOwned180(session, {
        event => match (event.payload) {
            case AgentEventPayload.TextDelta(text) => if (text != "") {
                    io.print(text)
                    stream.wroteText = true
                }
            case AgentEventPayload.Extension(_, detail) =>
                if (extensionCode(detail) == "model.text_delta") {
                    let text = eventText(event, "text")
                    if (text != "") {
                        io.print(text)
                        stream.wroteText = true
                    }
                }
            case _ => ()
        }
    }, CallbackOwnedAgentEventSink({ event => ignoreOwnedPrintToolLifecycle(event) }),
        failures: Some<OwnedFailureEventSink113>(failures))
    match (session.resumeStartup()) {
        case Result.Err(error) =>
            if (stream.wroteText) { io.println() }
            if (!failures.consumeCaller(session, error)) { printError(error, io: io) }
            return 1
        case Result.Ok(Some(response)) => match (response.approval) {
            case Some(approval) =>
                if (stream.wroteText) { io.println() }
                io.println("approval required: " + approval.operationId.value)
                return 3
            case None => ()
        }
        case Result.Ok(None) => ()
    }
    match (session.ownedRegistryCommand161(prompt)) {
        case Some(owned) => return appConsumeOwnedRegistryPlain161(owned, session, stream, failures, io: io)
        case None => ()
    }
    match (session.handle(prompt)) {
        case Result.Err(error) =>
            if (stream.wroteText) {
                io.println()
            }
            if (!failures.consumeCaller(session, error)) { printError(error, io: io) }
            1
        case Result.Ok(response) =>
            if (stream.wroteText) {
                io.println()
            } else if (response.text != "") {
                io.println(response.text)
            }
            match (response.approval) {
                case Some(approval) =>
                    io.println("approval required: " + approval.operationId.value)
                    3
                case None => 0
            }
    }
}

func runJsonStream(product: ProductRuntime, prompt: String, failures: CliFailureOutput113, io!: CliIo180 = consoleCliIo180,
    session180!: ?ApplicationSession = None<ApplicationSession>): Int64 {
    let session = session180 ?? product.applicationSession()
    failures.bindSession(session)
    io.println(
        encodeAgentValue(
            redactJsonAgentValue(objectValue(
                [
                    ValueField("type", textValue("session")),
                    ValueField("version", integerValue(3)),
                    ValueField("id", textValue(session.id().value)),
                    ValueField(
                        "timestamp",
                        textValue(DateTime.nowUTC().toString())
                    ),
                    ValueField("cwd", textValue(product.workspace.rootPath()))
                ]
            ))
        )
    )
    let stream = ApplicationJsonEventStream({ event =>
        appWriteRegistryLineChecked181(encodeAgentValue(applicationJsonEventValue(event)), io: io)
    }, io: io)
    io.subscribeOwned180(session, { event => stream.accept(event) },
        CallbackOwnedAgentEventSink({ event => stream.acceptOwned(event) }),
        failures: Some<OwnedFailureEventSink113>(failures))
    match (session.resumeStartup()) {
        case Result.Err(error) =>
            stream.finish()
            if (!failures.consumeCaller(session, error)) { printError(error, io: io) }
            return 1
        case Result.Ok(Some(_)) => if (prompt == "") {
            stream.finish()
            return 0
        }
        case Result.Ok(None) => ()
    }
    if (prompt == "") { return 0 }
    match (session.ownedRegistryCommand161(prompt)) {
        case Some(owned) => return appConsumeOwnedRegistryJson161(owned, session, stream, failures, io: io)
        case None => ()
    }
    match (session.handle(prompt)) {
        case Result.Err(error) =>
            stream.finish()
            if (!failures.consumeCaller(session, error)) {
            io.println(
                encodeAgentValue(
                    redactJsonAgentValue(objectValue(
                        [
                            ValueField("type", textValue("error")),
                            ValueField("code", textValue(error.code)),
                            ValueField("message", textValue(error.message))
                        ]
                    ))
                )
            )
            }
            1
        case Result.Ok(response) =>
            stream.finish()
            let fields = ArrayList<ValueField>()
            fields.add(ValueField("type", textValue("result")))
            fields.add(
                ValueField(
                    "agent_invoked",
                    boolValue(response.agentInvoked)
                )
            )
            match (response.snapshot) {
                case Some(snapshot) =>
                    fields.add(
                        ValueField(
                            "run_id",
                            textValue(snapshot.runId.value)
                        )
                    )
                    fields.add(
                        ValueField(
                            "session_id",
                            textValue(snapshot.sessionId.value)
                        )
                    )
                    fields.add(
                        ValueField(
                            "status",
                            textValue(runStatusName(snapshot.status))
                        )
                    )
                case None => ()
            }
            match (response.approval) {
                case Some(approval) =>
                    let details = approvalDetails(approval)
                    fields.add(
                        ValueField(
                            "approval",
                            objectValue(
                                [
                                    ValueField(
                                        "operation_id",
                                        textValue(details.operationId.value)
                                    ),
                                    ValueField(
                                        "tool",
                                        textValue(details.toolName)
                                    ),
                                    ValueField(
                                        "call_id",
                                        textValue(details.callId)
                                    ),
                                    ValueField(
                                        "capability",
                                        textValue(capabilityDisplayName(details.capability.kind))
                                    ),
                                    ValueField(
                                        "resource",
                                        textValue(details.capability.resource)
                                    ),
                                    ValueField(
                                        "risk",
                                        textValue(approvalRiskName(details.risk))
                                    ),
                                    ValueField(
                                        "preview",
                                        redactJsonAgentValue(details.arguments)
                                    )
                                ]
                            )
                        )
                    )
                case None => ()
            }
            io.println(encodeAgentValue(redactJsonAgentValue(
                objectValue(fields.toArray())
            )))
            if (response.approval.isSome()) {
                3
            } else {
                0
            }
    }
}

func applicationJsonEventValue(event: AgentEvent): AgentValue {
    redactJsonAgentValue(objectValue([
        ValueField("type", textValue("event")),
        ValueField("sequence", integerValue(event.sequence)),
        ValueField("run_id", textValue(event.runId.value)),
        ValueField("event", applicationJsonEventDetail(event))
    ]))
}

// Typed core events deliberately keep their domain payload free of transport
// field names. The JSON App Protocol still promises a stable `code`, so add it
// at this projection boundary. Extension payloads already own their code and
// must round-trip unchanged.
func applicationJsonEventDetail(event: AgentEvent): AgentValue {
    eventProtocolDetail(event)
}

class ApplicationJsonEventStream {
    private let lock = Mutex()
    private let output: AgentEventSink
    private let io: CliIo180
    private let text = ApplicationJsonDeltaStream()
    private let reasoning = ApplicationJsonDeltaStream()
    private let tools = ArrayList<ApplicationJsonToolStream>()

    init(output: AgentEventSink, io!: CliIo180 = consoleCliIo180) {
        this.output = output; this.io = io
    }

    func accept(event: AgentEvent): Unit {
        lock.lock()
        try {
            match (event.payload) {
                case AgentEventPayload.TextDelta(delta) =>
                    emit(
                        text.push(event, delta),
                        { value => AgentEventPayload.TextDelta(value) }
                    )
                    return
                case AgentEventPayload.ReasoningDelta(delta) =>
                    emit(
                        reasoning.push(event, delta),
                        { value => AgentEventPayload.ReasoningDelta(value) }
                    )
                    return
                case AgentEventPayload.ToolOutput(callId, channel, delta) =>
                    let stream = toolStream(callId, channel)
                    emit(
                        stream.delta.push(event, delta),
                        { value => AgentEventPayload.ToolOutput(callId, channel, value) }
                    )
                    return
                case AgentEventPayload.ToolCompleted(callId, _, _) =>
                    flushTool(callId)
                case AgentEventPayload.TurnCompleted(_) => flushModel()
                case AgentEventPayload.RunCompleted =>
                    flushModel()
                    flushTools()
                case _ => ()
            }
            output(event)
        } finally {
            lock.unlock()
        }
    }

    func acceptOwned(event: OwnedAgentEvent): Result<Unit> {
        lock.lock()
        try { writeOwnedApplicationJsonEvent(event, io: io) }
        finally { lock.unlock() }
    }

    func finish(): Unit {
        lock.lock()
        try {
            flushModel()
            flushTools()
        } finally {
            lock.unlock()
        }
    }

    private func emit(
        value: ?ApplicationJsonRedactedDelta,
        payload: (String) -> AgentEventPayload
    ): Unit {
        match (value) {
            case Some(item) => output(AgentEvent(item.meta, payload(item.text)))
            case None => ()
        }
    }

    private func flushModel(): Unit {
        emit(text.finish(), { value => AgentEventPayload.TextDelta(value) })
        emit(
            reasoning.finish(),
            { value => AgentEventPayload.ReasoningDelta(value) }
        )
    }

    private func toolStream(
        callId: ToolCallId,
        channel: ToolOutputChannel
    ): ApplicationJsonToolStream {
        for (value in tools where value.callId.value == callId.value &&
            value.channel == channel) {
            return value
        }
        let value = ApplicationJsonToolStream(callId, channel)
        tools.add(value)
        value
    }

    private func flushTool(callId: ToolCallId): Unit {
        var index: Int64 = 0
        while (index < tools.size) {
            let value = tools[index]
            if (value.callId.value == callId.value) {
                emit(
                    value.delta.finish(),
                    { text => AgentEventPayload.ToolOutput(
                        value.callId,
                        value.channel,
                        text
                    ) }
                )
                tools.remove(at: index)
            } else {
                index += 1
            }
        }
    }

    private func flushTools(): Unit {
        for (value in tools) {
            emit(
                value.delta.finish(),
                { text => AgentEventPayload.ToolOutput(
                    value.callId,
                    value.channel,
                    text
                ) }
            )
        }
        tools.clear()
    }
}

class ApplicationJsonRedactedDelta {
    let meta: EventMeta
    let text: String

    init(meta: EventMeta, text: String) {
        this.meta = meta
        this.text = text
    }
}

class ApplicationJsonDeltaStream {
    private let redactor = StreamingJsonTextRedactor()
    private var firstMeta: ?EventMeta = None

    func push(event: AgentEvent, value: String): ?ApplicationJsonRedactedDelta {
        if (firstMeta.isNone()) { firstMeta = Some(event.meta) }
        let redacted = redactor.push(value)
        if (redacted == "") { return None }
        let meta = firstMeta.getOrThrow()
        firstMeta = if (redactor.hasPending()) {
            Some(event.meta)
        } else {
            None
        }
        Some(ApplicationJsonRedactedDelta(meta, redacted))
    }

    func finish(): ?ApplicationJsonRedactedDelta {
        let redacted = redactor.finish()
        if (redacted == "") {
            firstMeta = None
            return None
        }
        let meta = match (firstMeta) {
            case Some(value) => value
            case None => return None
        }
        firstMeta = None
        Some(ApplicationJsonRedactedDelta(meta, redacted))
    }
}

class ApplicationJsonToolStream {
    let callId: ToolCallId
    let channel: ToolOutputChannel
    let delta = ApplicationJsonDeltaStream()

    init(callId: ToolCallId, channel: ToolOutputChannel) {
        this.callId = callId
        this.channel = channel
    }
}

func readStdinPrompt(): String {
    var result = ""
    while (true) {
        match (getStdIn().readln()) {
            case Some(line) =>
                if (result != "") {
                    result += "\n"
                }
                result += line
            case None => break
        }
    }
    result.trimAscii()
}

func printHelp(): Unit {
    println("axyndra [options] [message]\nCommands:")
    for (spec in reservedCliCommandRegistry().visibleCommands()) {
        println("  " + spec.name + "\t" + spec.description)
    }
    println(
        "Options:\n" + "  -p, --print                 print one response\n" +
            "  --mode text|json|rpc|rpc-ui|acp select non-interactive mode\n" +
            "  --model <profile/model>     override the default model\n" +
            "  --cwd <path>                set workspace root\n" +
            "  --max-time <duration>       stop a turn after this duration (e.g., 120, 5m, 1h)\n" +
            "  --approval-mode <mode>      manual, ai, never, trusted\n" +
            "  --shell-network-mode <mode> restricted, proxy, trusted-host\n" +
            "  --fixture                   explicit deterministic test provider")
}

class StreamState {
    var wroteText: Bool = false
}

class TuiPendingSubagentApproval {
    let subagentId: String
    let approval: ApprovalRequest

    init(subagentId: String, approval: ApprovalRequest) {
        this.subagentId = subagentId
        this.approval = approval
    }
}

func workspaceBranch(root: String): String {
    try {
        let (code, output, _) = executeWithOutput(
            "git",
            ["branch", "--show-current"],
            workingDirectory: Path(root)
        )
        if (code == 0) {
            let value = String.fromUtf8(output).trimAscii()
            if (value != "") {
                return value
            }
        }
    } catch (_: Exception) {
        ()
    }
    "detached"
}

class TuiRunEventCursor {
    private let lock = Mutex()
    private var running = false
    private var activeRunId = ""

    func begin(expectedRunId!: String = ""): Unit {
        lock.lock()
        try {
            running = true
            activeRunId = expectedRunId
        } finally { lock.unlock() }
    }

    func finish(): Unit {
        lock.lock()
        try {
            running = false
            activeRunId = ""
        } finally { lock.unlock() }
    }

    func accept(event: AgentEvent): Bool {
        lock.lock()
        try {
            if (!running) { return false }
            let outOfBand = match (event.payload) {
                case AgentEventPayload.ContextCompacted(_, _) => true
                case AgentEventPayload.Extension(_, detail) =>
                    match (detail.field("code")) {
                        case Some(value) => value.unifiedKind == ValueKind.Text &&
                            (value.text == "run.summary" || value.text == "task.summary")
                        case None => false
                    }
                case _ => false
            }
            if (outOfBand) {
                // Compaction and summary events are emitted after the completed
                // run has cleared activeRunId. A later run must not inherit a
                // delayed synthetic event from the previous UI generation.
                return activeRunId == ""
            }
            if (activeRunId == "") {
                match (event.payload) {
                    case AgentEventPayload.RunStarted => activeRunId = event.runId.value
                    case _ => return false
                }
            }
            if (event.runId.value != activeRunId) { return false }
            match (event.payload) {
                case AgentEventPayload.RunCompleted => activeRunId = ""
                case AgentEventPayload.RunStateChanged(_, to, _) =>
                    if (isTerminalRunState(to)) { activeRunId = "" }
                case _ => ()
            }
            true
        } finally { lock.unlock() }
    }
}

class ProductTuiBackend <: AgentTuiBackend & OwnedAgentTuiBackend & OwnedFailureAgentTuiBackend113 {
    private let session: ApplicationSession
    private let product: ProductRuntime
    private var branchLabel: String = ""
    private let lock = Mutex()
    private var running = false
    private let uiRunEvents = TuiRunEventCursor()
    private let appEvents: AppEventCursor
    private var appCommandSequence: Int64 = 0
    private var sink: ?TuiAgentEventSink = None
    private var observerSink: ?TuiAgentEventSink = None
    private var ownedDisplayOutput: ?OwnedTuiToolDisplayOutput = None
    private var ownedFailureDisplayOutput113: ?OwnedTuiFailureDisplayOutput113 = Option<OwnedTuiFailureDisplayOutput113>.None
    private let ownedFailureQueue113 = OwnedTuiFailureQueue113()
    // This is only the exact fixed marker from the still-paid actual App
    // slot, never a copied or displayed dynamic error. Clear it before the
    // accepted caller's loan/ACK can retire that slot's control metadata.
    private var pendingFailureMarker113: ?AgentError = Option<AgentError>.None
    private var retainedCopiedDisplays: ?OwnedTuiDisplayRegistration = None
    private var copiedDisplayProducerClosing = false
    private var copiedDisplayProducerBorrows: Int64 = 0
    private var retiringRegistryMetadata: ?LogicalJsonCopiedDisplayAllocation = None
    private var retainedRegistryResponses167: ?OwnedTuiRegistryRegistration167 = None
    private var pendingRegistryScope167: ?OwnedApplicationRegistryResponse161 = None
    private var pendingRegistryMetadata167: ?LogicalJsonCopiedDisplayAllocation = None
    private var pendingRegistryProjectionFailure167: ?AgentError = None
    private var retiringRegistryResponseMetadata167: ?LogicalJsonCopiedDisplayAllocation = None
    private var registryConstructing167 = false
    private var focusedSubagentId = ""
    private var pendingSubagentApproval: ?TuiPendingSubagentApproval = None
    private let queuedSubagentApprovals = ArrayList<TuiPendingSubagentApproval>()
    private var ownerSubscription180: ?ApplicationOwnedSubscription113 = None
    private var ownerControls180: ?ApplicationControlSubscription180 = None
    private var ownerSerializerLifetime180: ?OwnedTuiSerializerLifetime180 = None
    private let ownerAllocation180: ?((Int64) -> LogicalJsonOwnerReservation)
    private var pendingOwnerSubscription180: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var pendingOwnerControls180: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var initializerEntered180 = false
    init(product: ProductRuntime, applicationSession!: ApplicationSession,
        ownerAllocation180!: ?((Int64) -> LogicalJsonOwnerReservation) = None,
        ownerSerializerLifetime180!: ?OwnedTuiSerializerLifetime180 = None) {
        this.product = product; this.session = applicationSession
        this.appEvents = AppEventCursor(ThreadId(applicationSession.id().value))
        this.ownerSerializerLifetime180 = ownerSerializerLifetime180
        this.ownerAllocation180 = ownerAllocation180
    }
    func initializeFrontend180(): Unit {
        if (initializerEntered180) { throw IllegalStateException("TUI frontend initialization already entered") }
        initializerEntered180 = true
        branchLabel = workspaceBranch(session.workspaceRoot())
        match (ownerAllocation180) {
            case Some(allocate) =>
                pendingOwnerSubscription180 = Some(allocate(65536))
                ownerSubscription180 = Some(session.subscribeRetirableOwned113(pendingOwnerSubscription180.getOrThrow(),
                    { event => forward(event) }, CallbackOwnedAgentEventSink({ event => forwardOwnedDisplay(event) }),
                    failures: Some<OwnedFailureEventSink113>(OwnedTuiFailureAdmission113(ownedFailureQueue113))))
                pendingOwnerSubscription180 = None<LogicalJsonOwnerReservation>
                pendingOwnerControls180 = Some(allocate(65536))
                ownerControls180 = Some(session.subscribeRetirableControls180(pendingOwnerControls180.getOrThrow(),
                    { request => forwardAsk(request) }, { event => forwardJob(event) }, { event => forwardSubagent(event) }))
                pendingOwnerControls180 = None<LogicalJsonOwnerReservation>
            case None =>
                session.subscribeOwned({ event => forward(event) },
                    CallbackOwnedAgentEventSink({ event => forwardOwnedDisplay(event) }),
                    failures: Some<OwnedFailureEventSink113>(OwnedTuiFailureAdmission113(ownedFailureQueue113)))
                session.subscribeAsyncJobs({ event => forwardJob(event) })
                session.subscribeSubagents({ event => forwardSubagent(event) })
                session.subscribeAsks({ request => forwardAsk(request) })
        }
        session.setAskInteractive(true)
        let _ = session.resumeStartup()
    }


    public func observe(events: TuiAgentEventSink): Unit {
        lock.lock()
        try {
            if (copiedDisplayProducerClosing) { throw Exception("display.producer_references_closed") }
            observerSink = Some(events)
        } finally {
            lock.unlock()
        }
    }

    public func observeOwnedToolDisplay(output: OwnedTuiToolDisplayOutput): Unit {
        lock.lock()
        try {
            if (copiedDisplayProducerClosing) { throw Exception("display.producer_references_closed") }
            ownedDisplayOutput = Some(output)
        } finally { lock.unlock() }
    }

    public func observeOwnedFailureDisplay113(output: OwnedTuiFailureDisplayOutput113): Unit {
        lock.lock()
        try {
            if (copiedDisplayProducerClosing) { throw Exception("display.producer_references_closed") }
            ownedFailureDisplayOutput113 = Some(output)
        } finally { lock.unlock() }
        drainOwnedFailureDisplays113()
    }
    public func pollOwnedFailureDisplays113(): Unit { drainOwnedFailureDisplays113() }
    private func drainOwnedFailureDisplays113(): Unit {
        if (!beginCopiedDisplayProducerBorrow()) { return }
        try {
            lock.lock(); let output = ownedFailureDisplayOutput113; lock.unlock()
            match (output) { case Some(actual) => ownedFailureQueue113.drain(actual); case None => () }
            session.collectOwnedCheckpointFailure113()
            lock.lock(); let pending = pendingFailureMarker113; lock.unlock()
            match (pending) {
                case Some(marker) =>
                    let admitted = session.pollAndAdmitOwnedCheckpointFailure113(marker,
                        { actual => ownedFailureQueue113.admit(actual) })
                    if (admitted) {
                        lock.lock()
                        try { match (pendingFailureMarker113) {
                            case Some(current) => if (refEq(current, marker)) {
                                pendingFailureMarker113 = Option<AgentError>.None }
                            case None => () } }
                        finally { lock.unlock() }
                        match (output) { case Some(actual) => ownedFailureQueue113.drain(actual); case None => () }
                        session.collectOwnedCheckpointFailure113()
                    }
                case None => () }
        } finally { endCopiedDisplayProducerBorrow() }
    }
    private func emitTuiTurnFailure113(result: Result<ApplicationResponse>, events: TuiAgentEventSink): Bool {
        match (result) {
            case Result.Err(marker) => if (session.hasOwnedCheckpointFailure113(marker)) {
                lock.lock(); try { pendingFailureMarker113 = Some(marker) } finally { lock.unlock() }
                drainOwnedFailureDisplays113()
                return true
            }
            case Result.Ok(_) => () }
        emitTurnError(result, events)
        false
    }
    private func tuiTurnData113(result: Result<ApplicationResponse>, prompt: String, paidFailure: Bool): TuiTurnResult {
        // Fixed status is metadata. Full error data travels only through the
        // independently paid mailbox/card path; the canonical result is not
        // reclassified and an App marker is never formatted as the error.
        if (paidFailure) { TuiTurnResult("", "error") } else { tuiResult(result, prompt) }
    }

    private func beginCopiedDisplayProducerBorrow(): Bool {
        lock.lock()
        try { if (copiedDisplayProducerClosing) { return false }; copiedDisplayProducerBorrows++; true }
        finally { lock.unlock() }
    }
    private func endCopiedDisplayProducerBorrow(): Unit {
        lock.lock(); try { copiedDisplayProducerBorrows-- } finally { lock.unlock() } }
    func awaitRootSerializerFrames180(): Bool {
        while (true) {
            lock.lock()
            let framesEnded = copiedDisplayProducerClosing && copiedDisplayProducerBorrows == 0
            let callersHeld = registryConstructing167 || pendingRegistryScope167.isSome() || pendingFailureMarker113.isSome()
            lock.unlock()
            if (framesEnded) { return !callersHeld }
            sleep(Duration.millisecond)
        }
        false
    }
    func cancelOwnerTurn180(): Result<Unit> { session.cancel() }
    func retireRootSerializer180(receipt: TuiRootSerializerRetirement180): Result<Unit> {
        if (!receipt.acknowledges180(this)) { return ownedTuiDisplayError("display.serializer_retirement_unknown") }
        lock.lock()
        let live = !copiedDisplayProducerClosing || copiedDisplayProducerBorrows != 0 ||
            registryConstructing167 || pendingRegistryScope167.isSome() || pendingFailureMarker113.isSome()
        lock.unlock()
        if (live) { return ownedTuiDisplayError("display.serializer_producer_pending") }
        match (ownedFailureQueue113.discardRegisteredOriginalsAfterActualFrames113()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        session.collectOwnedCheckpointFailure113()
        match (ownerControls180) {
            case Some(token) =>
                while (!session.unsubscribeRetirableControls180(token)) { sleep(Duration.millisecond) }
                if (!token.retireAfterUnsubscribe180()) { return ownedTuiDisplayError("display.control_subscription_pending") }
                ownerControls180 = None
            case None => () }
        match (ownerSubscription180) {
            case Some(token) =>
                while (!session.unsubscribeRetirableOwned113(token)) { sleep(Duration.millisecond) }
                if (!token.retireAfterUnsubscribe113()) { return ownedTuiDisplayError("display.subscription_pending") }
                ownerSubscription180 = None
            case None => () }
        while (retainedCopiedDisplays.isSome() || retiringRegistryMetadata.isSome()) {
            if (retiringRegistryMetadata.isSome()) {
                match (retiringRegistryMetadata.getOrThrow().closeAfterCopiedDisplayRetirement()) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => retiringRegistryMetadata = None }
            } else {
                match (detachRootToolMetadata180(receipt)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            }
        }
        while (retainedRegistryResponses167.isSome() || retiringRegistryResponseMetadata167.isSome()) {
            if (retiringRegistryResponseMetadata167.isSome()) {
                match (retiringRegistryResponseMetadata167.getOrThrow().closeAfterCopiedDisplayRetirement()) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => retiringRegistryResponseMetadata167 = None }
            } else {
                match (detachRootRegistryMetadata180(receipt)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            }
        }
        match (ownedFailureQueue113.retireRootSerializedRegistry180(receipt, this)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        ownerSerializerLifetime180 = None
        Result<Unit>.Ok(())
    }
    private func detachRootToolMetadata180(receipt: TuiRootSerializerRetirement180): Result<Unit> {
        let node = retainedCopiedDisplays.getOrThrow()
        match (node.retireRootSerializedData180(receipt, this)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        retiringRegistryMetadata = Some(node.takeMetadataAfterDataRetirement())
        retainedCopiedDisplays = node.next; node.next = None
        Result<Unit>.Ok(())
    }
    private func detachRootRegistryMetadata180(receipt: TuiRootSerializerRetirement180): Result<Unit> {
        let node = retainedRegistryResponses167.getOrThrow()
        match (node.retireRootSerializedData180(receipt, this)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        retiringRegistryResponseMetadata167 = Some(node.takeMetadataAfterDataRetirement167())
        retainedRegistryResponses167 = node.next; node.next = None
        Result<Unit>.Ok(())
    }
    public func beginOwnedToolDisplayProducerClosing(): Unit {
        lock.lock()
        try {
            copiedDisplayProducerClosing = true
            ownedDisplayOutput = None; ownedFailureDisplayOutput113 = Option<OwnedTuiFailureDisplayOutput113>.None
            observerSink = None; sink = None
            ownedFailureQueue113.beginClosing()
        } finally { lock.unlock() }
        let _ = session.cancel()
    }
    public func awaitOwnedToolDisplayProducerReferencesRetired(): Bool {
        while (true) {
            lock.lock()
            let done = copiedDisplayProducerClosing && copiedDisplayProducerBorrows == 0
            lock.unlock()
            if (done) {
                lock.lock(); let registryPending = registryConstructing167 || pendingRegistryScope167.isSome(); lock.unlock()
                return !registryPending && !ownedFailureQueue113.hasOriginalDebt() }
            sleep(Duration.millisecond)
        }
        false
    }
    public func discardOwnedFailureInputsAfterProducerRetirement113(retired: RetiredOwnedTuiFailureProducerFrames113): Result<Unit> {
        if (!retired.acknowledges(this)) { return ownedTuiDisplayError("display.failure_producer_retirement_unknown") }
        lock.lock()
        let actualFramesEnded = copiedDisplayProducerClosing && copiedDisplayProducerBorrows == 0
        let callerStillHeld = pendingFailureMarker113.isSome()
        lock.unlock()
        // The Screen receipt carries its actual native/async/Window/Terminal
        // retirement; these counters cover this backend's live copy/drain
        // helper frames. An untransferred App caller stays explicitly OPEN.
        if (!actualFramesEnded || callerStillHeld) { return ownedTuiDisplayError("display.failure_input_pending") }
        match (ownedFailureQueue113.discardRegisteredOriginalsAfterActualFrames113()) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => session.collectOwnedCheckpointFailure113(); Result<Unit>.Ok(()) }
    }
    public func retireOwnedToolDisplayRegistry(retired: RetiredOwnedTuiScreenReferences): Result<Unit> {
        if (!retired.copiedReferencesRetired() || !awaitOwnedToolDisplayProducerReferencesRetired()) {
            return ownedTuiDisplayError("display.registry_producer_pending") }
        while (retainedCopiedDisplays.isSome()) {
            var node = retainedCopiedDisplays
            match (node.getOrThrow().retireCopiedData(retired)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            retiringRegistryMetadata = Some(node.getOrThrow().takeMetadataAfterDataRetirement())
            retainedCopiedDisplays = node.getOrThrow().next
            node.getOrThrow().next = None; node = None
            // Actual node/data/next helper references cleared before its
            // distinct same-bank metadata payment can be retired.
            match (retiringRegistryMetadata.getOrThrow().closeAfterCopiedDisplayRetirement()) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => retiringRegistryMetadata = None }
        }
        match (retireRegistryResponses167(retired)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        ownedFailureQueue113.retireCopiedRegistry(retired)
    }
    private func forwardOwnedDisplay(event: OwnedAgentEvent): Result<Unit> {
        if (!beginCopiedDisplayProducerBorrow()) { return ownedTuiDisplayError("display.producer_references_closed") }
        try { forwardOwnedDisplayFrame(event) } finally { endCopiedDisplayProducerBorrow() }
    }
    private func forwardOwnedDisplayFrame(event: OwnedAgentEvent): Result<Unit> {
        lock.lock(); let output = ownedDisplayOutput; lock.unlock()
        match (output) {
            case None =>
                // Preserve the legacy actual observer behavior without
                // manufacturing its full-DOM lifetime acknowledgement.
                return event.withEvent(1048576, {actual =>
                    forward(actual); ownedTuiDisplayError("display.owned_observer_required") })
            case Some(target) =>
                match (event.ensureAdditionalRetainedPeak(4096)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                let decision = OwnedTuiCursorDecision()
                match (event.withEvent(65536, {actual => decision.accepted = acceptUiRunEvent(actual); Result.Ok(()) })) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                if (!decision.accepted) { return event.closeAfterEventRetirement() }
                // Pay the actual linked registry metadata independently of
                // the original row high-water, before the node allocation.
                let registryPayment = match (event.acquireCopiedDisplayAllocation(4096)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                let registration = try { OwnedTuiDisplayRegistration(registryPayment) }
                    catch (error: Exception) { let _ = registryPayment.closeAfterCopiedDisplayRetirement(); throw error }
                lock.lock()
                try { registration.next = retainedCopiedDisplays; retainedCopiedDisplays = Some(registration) }
                finally { lock.unlock() }
                let display = match (copyOwnedTuiToolEvent(event, {copy => registration.install(copy)})) {
                    case Result.Err(error) =>
                        // Builder cleanup cleared its actual copied event.
                        // Remove the real registered token reference; this
                        // empty linked node keeps its own metadata paid.
                        registration.clearFailedDisplayReference(); return Result.Err(error)
                    case Result.Ok(value) => value }
                match (target.accept(display)) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(_) => () }
                // The mailbox has only genuinely copied, independently
                // prepaid display bytes. The original DOM loan ended before
                // this original alias ACK. Copied payment remains retained.
                event.closeAfterEventRetirement()
        }
    }

    public func welcome(): Array<TuiAgentEvent> {
        let events = ArrayList<TuiAgentEvent>()
        for (profile in product.providers() where profile.allowInsecureHttp) {
            events.add(TuiAgentEvent.Warning(
                "Insecure HTTP: " + profile.id,
                "Provider uses plaintext HTTP at " + profile.baseUrl +
                    "; API keys and prompts may be intercepted."
            ))
        }
        if (product.shellNetworkMode == ShellNetworkMode.TrustedHost) {
            events.add(TuiAgentEvent.Warning(
                "Trusted host network",
                "Shell commands can reach the host network; file, environment, credentials, and approval boundaries remain active."
            ))
        }
        if (session.model() == "unconfigured") {
            events.add(TuiAgentEvent.Setup(
                "Run `axyndra setup`, or create " + defaultProductHome() + "/config.yml, models.yml, and providers.yml; " +
                    "then restart axyndra. Fixture mode is never selected " + "implicitly."
            ))
        }
        events.toArray()
    }

    public func submit(
        prompt: String,
        events: TuiAgentEventSink
    ): TuiTurnResult {
        let focused = focusedSubagent()
        if (focused != "") {
            return match (session.messageSubagent(focused, prompt)) {
                case Result.Ok(_) => TuiTurnResult(
                    "",
                    "sent to subagent " + focused
                )
                case Result.Err(error) => TuiTurnResult(
                    "",
                    "subagent message failed: " + error.message
                )
            }
        }
        begin(events)
        let first = handleRegistryResponse167(prompt)
        var result = first[0]
        var registration = first[1]
        while (true) {
            match (session.takeQueuedAtSafeBoundary(result)) {
                case Some(next) =>
                    let following = handleRegistryResponse167(next.input)
                    result = following[0]; registration = following[1]
                case None => break
            }
        }
        finalRegistryTurn167(result, prompt, registration, events)
    }

    private func handleRegistryResponse167(input: String): (Result<ApplicationResponse>, ?OwnedTuiRegistryRegistration167) {
        lock.lock()
        try {
            if (copiedDisplayProducerClosing || registryConstructing167 || pendingRegistryScope167.isSome()) {
                throw Exception("display.registry_unregistered_response_pending") }
            registryConstructing167 = true
        } finally { lock.unlock() }
        try {
            match (session.ownedRegistryCommand161(input)) {
                case None => (session.handle(input), Option<OwnedTuiRegistryRegistration167>.None)
                case Some(actual) =>
                    lock.lock(); try { pendingRegistryScope167 = Some(actual) } finally { lock.unlock() }
                    // The actual source is reachable before either of these
                    // fallible allocations; no unknown error refunds it.
                    actual.prepayConsumerCopies161(4096)
                    match (actual.acquireTuiCopiedDisplay167(4096)) {
                        case Result.Err(error) =>
                            pendingRegistryProjectionFailure167 = Some(error)
                            throw Exception("display.registry_projection_pending")
                        case Result.Ok(value) =>
                            lock.lock(); try { pendingRegistryMetadata167 = Some(value) } finally { lock.unlock() } }
                    let node = OwnedTuiRegistryRegistration167(actual, pendingRegistryMetadata167.getOrThrow())
                    lock.lock()
                    try {
                        node.next = retainedRegistryResponses167; retainedRegistryResponses167 = Some(node)
                        pendingRegistryMetadata167 = None; pendingRegistryScope167 = None
                    } finally { lock.unlock() }
                    node.installProjection167(this, serializerLifetime180: ownerSerializerLifetime180)
                    (node.originalResult167(), Some(node))
            }
        } finally {
            lock.lock(); try { registryConstructing167 = false } finally { lock.unlock() }
        }
    }
    private func finalRegistryTurn167(result: Result<ApplicationResponse>, prompt: String,
        registration: ?OwnedTuiRegistryRegistration167, events: TuiAgentEventSink): TuiTurnResult {
        match (registration) {
            case None =>
                let paidFailure113 = emitTuiTurnFailure113(result, events)
                emitApproval(result); finish()
                tuiTurnData113(result, prompt, paidFailure113)
            case Some(node) =>
                let display = node.copiedDisplay167()
                match (display.prepareQueueAndScreenCopies167(65536)) {
                    case Result.Err(error) =>
                        node.rememberProjectionFailure167(error)
                        throw Exception("display.registry_projection_pending")
                    case Result.Ok(_) => () }
                // Preserve the old error text/UI semantics, now with the
                // actual maintenance-data payment across mailbox and cards.
                match (result) {
                    case Result.Err(error) => events(TuiAgentEvent.OwnedRegistryError167(display, error.describe()))
                    case Result.Ok(_) => () }
                emitApproval(result); finish()
                let original = tuiTurnData113(result, prompt, false)
                TuiTurnResult(original.text, original.status, action: original.action,
                    planReviewDisposition: original.planReviewDisposition,
                    ownedRegistryDisplay167: Some(display))
        }
    }
    private func retireRegistryResponses167(retired: RetiredOwnedTuiScreenReferences): Result<Unit> {
        if (!retired.acknowledgesRegistryProducer167(this)) {
            return Result<Unit>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "display.registry_screen_retirement_unknown", "actual maintenance Screen is required")) }
        let original = RetiredActualRegistryTuiReferences167(retired, this)
        // A failed close retains the exact old metadata field. A later
        // call must finish it before another node can reuse that slot.
        match (retiringRegistryResponseMetadata167) {
            case Some(value) => match (value.closeAfterCopiedDisplayRetirement()) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => retiringRegistryResponseMetadata167 = None }
            case None => () }
        while (retainedRegistryResponses167.isSome()) {
            var node = retainedRegistryResponses167
            match (node.getOrThrow().retireResponseData167(retired, original)) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => () }
            retiringRegistryResponseMetadata167 = Some(node.getOrThrow().takeMetadataAfterDataRetirement167())
            retainedRegistryResponses167 = node.getOrThrow().next
            node.getOrThrow().next = None; node = None
            match (retiringRegistryResponseMetadata167.getOrThrow().closeAfterCopiedDisplayRetirement()) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => retiringRegistryResponseMetadata167 = None }
        }
        Result<Unit>.Ok(())
    }

    public func steer(correlationId: String, prompt: String): Bool {
        lock.lock()
        try {
            if (!running) {
                return false
            }
        } finally {
            lock.unlock()
        }
        session.enqueue(correlationId, "steer", prompt).isOk()
    }

    public func followUp(correlationId: String, prompt: String): Bool {
        lock.lock()
        try {
            if (!running) {
                return false
            }
        } finally {
            lock.unlock()
        }
        session.enqueue(correlationId, "follow_up", prompt).isOk()
    }

    public func withdrawQueued(correlationId: String): TuiQueueWithdrawal {
        match (session.withdrawQueued(correlationId)) {
            case Result.Ok(QueuedWithdrawal.Withdrawn(queued)) => TuiQueueWithdrawal.Withdrawn(
                queued.kind,
                queued.input
            )
            case Result.Ok(QueuedWithdrawal.AlreadyDelivered) => TuiQueueWithdrawal.AlreadyDelivered
            case Result.Err(error) => TuiQueueWithdrawal.Failed(error.message)
        }
    }

    public func decide(
        operationId: String,
        decision: TuiApprovalDecision,
        events: TuiAgentEventSink
    ): TuiTurnResult {
        begin(events, expectedRunId: session.activeRunId())
        let domainDecision = match (decision) {
            case TuiApprovalDecision.AllowOnce => ApprovalDecision.Approve
            case TuiApprovalDecision.AllowSession => ApprovalDecision.ApproveSession
            case TuiApprovalDecision.Reject(reason) =>
                if (reason == "") {
                    ApprovalDecision.Reject
                } else {
                    ApprovalDecision.RejectWithReason(reason)
                }
        }
        if (operationId != "") {
            match (takePendingSubagentApproval(operationId: operationId)) {
                case Some(pending) => return decidePendingSubagentApproval(
                    pending,
                    domainDecision,
                    events
                )
                case None => ()
            }
        }
        match (session.approval()) {
            case Some(approval) =>
                if (operationId != "" && approval.operationId.value != operationId) {
                    finish()
                    return TuiTurnResult("", "approval changed; reopen the active approval")
                }
                var result = session.decide(
                    approval.operationId.value,
                    domainDecision
                )
                while (true) {
                    match (session.takeQueuedAtSafeBoundary(result)) {
                        case Some(next) => result = session.handle(next.input)
                        case None => break
                    }
                }
                let paidFailure113 = emitTuiTurnFailure113(result, events)
                emitApproval(result)
                finish()
                emitPendingSubagentApproval(events)
                // A pure invalid choice can retain the actual frozen review.
                // Read only Application's current owner, never replay an old card.
                emitCurrentMainApproval(events)
                if(result.isOk()){
                    match(session.takeTodoEditorCompletion()){
                        case Some(completed)=>return if(completed.saved){
                            TuiTurnResult("","todo saved",action:TuiTurnAction.TodoSaved(TuiTodoSaveResult(true,"Saved the selected native Todo document.")))
                        }else{
                            TuiTurnResult("","todo loaded",action:TuiTurnAction.TodoLoaded(TuiTodoLoadResult(true,completed.markdown,"todo loaded")))}
                        case None=>()}}
                tuiTurnData113(result, "", paidFailure113)
            case None => match (takePendingSubagentApproval(operationId: operationId)) {
                case Some(pending) => decidePendingSubagentApproval(
                    pending,
                    domainDecision,
                    events
                )
                case None =>
                    finish()
                    TuiTurnResult("", "no pending approval")
            }
        }
    }

    private func decidePendingSubagentApproval(
        pending: TuiPendingSubagentApproval,
        decision: ApprovalDecision,
        events: TuiAgentEventSink
    ): TuiTurnResult {
        let result = product.decideSubagentApproval(
            session.id(),
            pending.subagentId,
            decision
        )
        match (result) {
            case Result.Ok(_) =>
                clearPendingSubagentApproval(pending.approval.operationId.value)
                finish()
                emitNextSubagentApproval(events)
                emitCurrentMainApproval(events)
                TuiTurnResult(
                    "",
                    "subagent approval decision sent"
                )
            case Result.Err(error) =>
                finish()
                events(TuiAgentEvent.Error("subagent approval failed: " + error.describe()))
                TuiTurnResult(
                    "",
                    "subagent approval failed: " + error.message
                )
        }
    }

    public func reviewPlan(
        contentHash: String,
        decision: TuiPlanReviewDecision,
        feedback: String,
        events: TuiAgentEventSink
    ): TuiTurnResult {
        match (decision) {
            case TuiPlanReviewDecision.UpdatePlan => return match (session.updateLatestPlan(contentHash, feedback)) {
                case Result.Ok(updated) => TuiTurnResult(
                    "",
                    "plan updated",
                    action: TuiTurnAction.OpenPlanReview(updated),
                    planReviewDisposition: TuiPlanReviewDisposition.Retain
                )
                case Result.Err(error) => TuiTurnResult(
                    "",
                    "plan update failed: " + error.message,
                    planReviewDisposition: planReviewFailureDisposition(error)
                )
            }
            case _ => ()
        }
        let current = match (session.handle("/plan-review")) {
            case Result.Ok(value) => value.text
            case Result.Err(error) => return TuiTurnResult(
                "",
                "plan review failed: " + error.message,
                planReviewDisposition: planReviewFailureDisposition(error)
            )
        }
        if (planContentHash(current) != contentHash) {
            return TuiTurnResult(
                "",
                "plan changed since review opened; refreshed latest plan",
                action: TuiTurnAction.OpenPlanReview(current),
                planReviewDisposition: TuiPlanReviewDisposition.Retain
            )
        }
        begin(events)
        let note = feedback.trimAscii()
        var disposition = TuiPlanReviewDisposition.Retain
        var result: Result<ApplicationResponse> = match (decision) {
            case TuiPlanReviewDecision.ApproveAndExecute => match (session.approveLatestPlanForReview(
                expectedHash: contentHash,
                feedback: note,
                contextMode: "keep",
                onConsumed: {hash => events(TuiAgentEvent.PlanReviewConsumed(hash))}
            )) {
                case PlanApprovalOutcome.NotConsumed(error) =>
                    disposition = planReviewFailureDisposition(error)
                    Result.Err(error)
                case PlanApprovalOutcome.Consumed(value) =>
                    disposition = TuiPlanReviewDisposition.Consumed
                    value
            }
            case TuiPlanReviewDecision.ApproveFresh => match (session.approveLatestPlanForReview(
                expectedHash: contentHash,
                feedback: note,
                contextMode: "fresh",
                onConsumed: {hash => events(TuiAgentEvent.PlanReviewConsumed(hash))}
            )) {
                case PlanApprovalOutcome.NotConsumed(error) =>
                    disposition = planReviewFailureDisposition(error)
                    Result.Err(error)
                case PlanApprovalOutcome.Consumed(value) =>
                    disposition = TuiPlanReviewDisposition.Consumed
                    value
            }
            case TuiPlanReviewDecision.ApproveCompact => match (session.approveLatestPlanForReview(
                expectedHash: contentHash,
                feedback: note,
                contextMode: "compact",
                onConsumed: {hash => events(TuiAgentEvent.PlanReviewConsumed(hash))}
            )) {
                case PlanApprovalOutcome.NotConsumed(error) =>
                    disposition = planReviewFailureDisposition(error)
                    Result.Err(error)
                case PlanApprovalOutcome.Consumed(value) =>
                    disposition = TuiPlanReviewDisposition.Consumed
                    value
            }
            case TuiPlanReviewDecision.ApproveKeep => match (session.approveLatestPlanForReview(
                expectedHash: contentHash,
                feedback: note,
                contextMode: "keep",
                onConsumed: {hash => events(TuiAgentEvent.PlanReviewConsumed(hash))}
            )) {
                case PlanApprovalOutcome.NotConsumed(error) =>
                    disposition = planReviewFailureDisposition(error)
                    Result.Err(error)
                case PlanApprovalOutcome.Consumed(value) =>
                    disposition = TuiPlanReviewDisposition.Consumed
                    value
            }
            case TuiPlanReviewDecision.Refine => session.handle(
                "[plan-review refine hash=" + contentHash + "] Revise the structured plan without executing it." +
                    if (note == "") {
                        " Ask for refinement feedback before changing the plan."
                    } else {
                        "\n\n" + note
                    }
            )
            case TuiPlanReviewDecision.KeepPlanning => session.handle(
                "[plan-review continue hash=" + contentHash + "] Continue planning without executing." + if (note == "") {
                    ""
                } else {
                    " Feedback: " + note
                })
            case TuiPlanReviewDecision.Reject => session.handle(
                "[plan-review rejected hash=" + contentHash + "] The plan was rejected. Preserve its history and " +
                    "revise it before execution." + if (note == "") {
                    ""
                } else {
                    " Reason: " + note
                })
            case TuiPlanReviewDecision.UpdatePlan => Result.Err(
                AgentError(
                    AgentErrorKind.Internal,
                    "plan_review.update_unreachable",
                    "plan update should complete before starting an agent turn"
                )
            )
        }
        match (decision) {
            case TuiPlanReviewDecision.ApproveAndExecute | TuiPlanReviewDecision.ApproveFresh |
                TuiPlanReviewDecision.ApproveCompact | TuiPlanReviewDecision.ApproveKeep => ()
            case _ => disposition = if (result.isOk()) {
                TuiPlanReviewDisposition.Consumed
            } else {
                TuiPlanReviewDisposition.Retain
            }
        }
        if (result.isOk()) {
            while (true) {
                match (session.takeQueuedAtSafeBoundary(result)) {
                    case Some(next) => result = session.handle(next.input)
                    case None => break
                }
            }
        }
        let paidFailure113 = emitTuiTurnFailure113(result, events)
        emitApproval(result)
        finish()
        let tui = tuiTurnData113(result, "", paidFailure113)
        TuiTurnResult(
            tui.text,
            tui.status,
            action: tui.action,
            planReviewDisposition: disposition
        )
    }

    public func answerAsk(
        requestId: String,
        resolution: TuiAskResolution
    ): Bool {
        let productResolution = match (resolution) {
            case TuiAskResolution.Chat => ProductAskResolution.Chat
            case TuiAskResolution.Cancelled => ProductAskResolution.Cancelled
            case TuiAskResolution.Answers(answers) =>
                let values = ArrayList<ProductAskAnswer>()
                for (answer in answers) {
                    values.add(
                        ProductAskAnswer(
                            answer.id,
                            selectedOptions: answer.selectedOptions,
                            customInput: answer.customInput,
                            note: answer.note,
                            timedOut: answer.timedOut
                        )
                    )
                }
                ProductAskResolution.Answers(values.toArray())
        }
        session.answerAsk(requestId, productResolution).isOk()
    }

    public func pluginCommands(): Array<String> {
        let routes = ArrayList<String>()
        for (command in session.javascriptPluginCommands()) {
            routes.add(command.routeName)
        }
        routes.toArray()
    }

    public func runPluginCommand(
        routeName: String,
        arguments: String,
        events: TuiAgentEventSink
    ): TuiTurnResult {
        match (session.invokeJavaScriptPluginCommand(
            routeName, arguments, {kind, message =>
                events(TuiAgentEvent.PluginNotice(kind, message))
            }
        )) {
            case Result.Ok(_) => match (session.approval()) {
                case Some(approval) => events(tuiApprovalEvent(approval)); TuiTurnResult("", "plugin command awaiting approval")
                case None => TuiTurnResult("", "plugin command completed") }
            case Result.Err(error) =>
                events(TuiAgentEvent.Warning(
                    "Plugin command failed (" + error.code + ")", error.message
                ))
                TuiTurnResult("", "plugin command failed")
        }
    }

    public func cancel(): Unit {
        let focused = focusedSubagent()
        if (focused == "") {
            let result = session.cancel()
            let _ = result
        } else {
            let result = session.cancelSubagent(focused)
            let _ = result
        }
    }

    public func currentModel(): String {
        session.model()
    }

    public func currentSession(): String {
        let focused = focusedSubagent()
        if (focused == "") {
            session.id().value
        } else {
            focused
        }
    }

    public func currentThinking(): String {
        // Show the level that will actually be sent: plan mode forces High
        // (application effectiveThinking) even when the session default is
        // lower, so the status bar must not claim "medium" mid-plan.
        let effective = if (session.workMode() == "plan") {
            match (session.thinking()) {
                case ThinkingLevel.Off | ThinkingLevel.Minimal | ThinkingLevel.Low | ThinkingLevel.Medium => ThinkingLevel
                    .High
                case other => other
            }
        } else {
            session.thinking()
        }
        match (effective) {
            case ThinkingLevel.Off => "off"
            case ThinkingLevel.Minimal => "minimal"
            case ThinkingLevel.Low => "low"
            case ThinkingLevel.Medium => "medium"
            case ThinkingLevel.High => "high"
            case ThinkingLevel.XHigh => "xhigh"
            case ThinkingLevel.Max => "max"
        }
    }

    public func currentWorkMode(): String {
        session.workMode()
    }
    public func currentShellNetworkMode(): String {
        shellNetworkModeName(product.shellNetworkMode)
    }

    public func currentTheme(): String {
        session.currentTheme()
    }

    public func customThemes(): Array<TuiThemeDefinition> {
        let values = ArrayList<TuiThemeDefinition>()
        match (session.themes()) {
            case Result.Ok(themes) => for (theme in themes) {
                values.add(tuiThemeDefinition(theme))
            }
            case Result.Err(_) => ()
        }
        values.toArray()
    }

    public func selectTheme(name: String): Bool {
        session.handle("/theme " + name).isOk()
    }

    public func currentBranch(): String {
        branchLabel
    }

    public func workspace(): String {
        session.workspaceRoot()
    }

    public func models(): Array<String> {
        session.models()
    }

    public func sessions(includeArchived: Bool): Array<TuiSessionNode> {
        let values = ArrayList<TuiSessionNode>()
        match (product.sessions()) {
            case Result.Ok(sessions) => for (candidate in sessions) {
                match (product.sessionInfo(candidate)) {
                    case Result.Ok(info) => values.add(tuiSessionNode(info, candidate.value == session.id().value))
                    case Result.Err(_) => ()
                }
            }
            case Result.Err(_) => ()
        }
        if (values.isEmpty()) {
            values.add(TuiSessionNode(session.id().value, "", "Empty session", "", "", "", 0, true))
        }
        if (includeArchived) {
            for (archivedId in product.archivedSessions()) {
                match (product.archivedSessionInfo(SessionId(archivedId))) {
                    case Result.Ok(info) => values.add(tuiSessionNode(info, false))
                    case Result.Err(_) => ()
                }
            }
        }
        orderSessionNodes(values.toArray())
    }

    public func sessionTree(): Array<TuiSessionNode> {
        sessions(false)
    }

    public func renameSession(sessionId: String, name: String): Bool {
        product.setSessionName(SessionId(sessionId), name).isOk()
    }

    public func archiveSession(sessionId: String): Bool {
        sessionId != session.id().value && product.archiveSession(SessionId(sessionId)).isOk()
    }

    public func restoreSession(sessionId: String): Bool {
        product.restoreSession(SessionId(sessionId)).isOk()
    }

    public func subagents(): Array<TuiSubagentInfo> {
        let values = ArrayList<TuiSubagentInfo>()
        for (subagent in session.allSubagents()) {
            values.add(
                TuiSubagentInfo(
                    subagent.id,
                    subagent.agent,
                    subagent.status,
                    subagent.task
                )
            )
        }
        values.toArray()
    }

    public func subagentTranscript(id: String): String {
        match (session.handle("/agent " + id)) {
            case Result.Ok(response) => response.text
            case Result.Err(error) => "Unable to open subagent: " + error.message
        }
    }

    public func focusSubagent(id: String): TuiConversationView {
        var status = "unknown"
        var found = false
        for (item in session.allSubagents() where item.id == id) {
            status = item.status
            found = true
        }
        if (!found) {
            return TuiConversationView(
                id,
                "Subagent · " + id,
                "missing",
                false,
                [
                    TuiTranscriptItem(
                        "subagent-missing-" + id,
                        UiCardKind.Error,
                        "Subagent unavailable",
                        "Unable to find subagent " + id,
                        state: "failed"
                    )
                ]
            )
        }
        lock.lock()
        try {
            focusedSubagentId = id
        } finally {
            lock.unlock()
        }
        let items = match (session.subagentTranscript(subagentId: id)) {
            case Result.Ok(value) => tuiTranscriptItems(
                value.messages,
                "subagent-" + id
            )
            case Result.Err(error) => [
                TuiTranscriptItem(
                    "subagent-error-" + id,
                    UiCardKind.Error,
                    "Subagent transcript error",
                    error.message,
                    state: "failed"
                )
            ]
        }
        TuiConversationView(
            id,
            "Subagent · " + id,
            status,
            false,
            items
        )
    }

    public func focusMain(): TuiConversationView {
        lock.lock()
        try {
            focusedSubagentId = ""
        } finally {
            lock.unlock()
        }
        let canonicalPage = loadCanonicalThreadPage(0, 512)
        let items = match (canonicalPage) {
            case Result.Ok(page) => canonicalTuiTranscriptPage(page).items
            case Result.Err(error) => [
                TuiTranscriptItem(
                    "main-transcript-error",
                    UiCardKind.Error,
                    "Main transcript error",
                    error.message,
                    state: "failed"
                )
            ]
        }
        let cursor = match (canonicalPage) {
            case Result.Ok(page) => page.nextBeforeOrdinal
            case Result.Err(_) => 0
        }
        let hasMore = match (canonicalPage) {
            case Result.Ok(page) => page.hasMore
            case Result.Err(_) => false
        }
        let provisionalEvents: Array<TuiAgentEvent> = if (session.activeRunId() == "") {
            []
        } else {
            match (product.client.events(RunId(session.activeRunId()), 0)) {
                case Result.Ok(page) => activeAttemptTuiEvents(page)
                case Result.Err(_) => []
            }
        }
        TuiConversationView(
            session.id().value,
            "Main",
            "ready",
            true,
            items,
            nextBeforeOrdinal: cursor,
            hasMore: hasMore,
            provisionalEvents: provisionalEvents
        )
    }

    public func loadMainTranscriptPage(beforeOrdinal: Int64, limit: Int64): TuiTranscriptPage {
        if (beforeOrdinal <= 0) { return TuiTranscriptPage([], 0, false) }
        match (loadCanonicalThreadPage(beforeOrdinal, limit)) {
            case Result.Ok(page) => canonicalTuiTranscriptPage(page)
            case Result.Err(_) => TuiTranscriptPage([], 0, false)
        }
    }

    private func loadCanonicalThreadPage(
        beforeOrdinal: Int64,
        limit: Int64
    ): Result<ThreadItemsPage> {
        let commandSequence = nextAppCommandSequence()
        let threadId = ThreadId(session.id().value)
        match (product.appCommand(AppCommand(
            AppCommandMeta(
                AppCommandId("tui-items-page-" + commandSequence.toString()),
                commandSequence
            ),
            AppCommandPayload.LoadItemsPage(threadId, beforeOrdinal, limit)
        ))) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(event) =>
                if (appEvents.accept(event) != AppEventDisposition.Accepted) {
                    return Result.Err(AgentError(
                        AgentErrorKind.Conflict,
                        "tui.stale_items_page",
                        "stale Thread page was rejected by the App Protocol cursor"
                    ))
                }
                match (event.payload) {
                    case AppEventPayload.ItemsPage(page) => Result.Ok(page)
                    case _ => Result.Err(AgentError(
                        AgentErrorKind.Protocol,
                        "tui.unexpected_app_event",
                        "App Protocol returned a non-page event for LoadItemsPage"
                    ))
                }
        }
    }

    private func nextAppCommandSequence(): Int64 {
        lock.lock()
        try {
            appCommandSequence++
            appCommandSequence
        } finally { lock.unlock() }
    }

    public func draft(): String {
        match (session.draft()) {
            case Result.Ok(value) => value
            case Result.Err(_) => ""
        }
    }

    public func saveDraft(value: String): Bool {
        session.setDraft(value).isOk()
    }

    public func branchMessages(): Array<String> {
        let values = ArrayList<String>()
        match (session.branchMessages()) {
            case Result.Ok(messages) => for (message in messages) {
                values.add(message.entryId + " · " + message.text.replace("\n", " "))
            }
            case Result.Err(_) => ()
        }
        values.toArray()
    }

    public func selectModel(model: String): Bool {
        session.selectModel(model).isOk()
    }

    public func selectSession(sessionId: String): Bool {
        let separator = sessionId.indexOf(" · ")
        let value = match (separator) {
            case Some(index) => sessionId[..index]
            case None => sessionId
        }
        let switched = session.switchSession(SessionId(value)).isOk()
        if (switched) {
            appEvents.switchThread(ThreadId(value))
        }
        switched
    }

    public func selectBranch(entry: String): ?String {
        let separator = entry.indexOf(" · ")
        let entryId = match (separator) {
            case Some(index) => entry[..index]
            case None => entry
        }
        match (session.branchAt(entryId)) {
            case Result.Ok(value) => Some(value.text)
            case Result.Err(_) => None
        }
    }

    public func configureSetup(request: TuiSetupRequest): String {
        let result = try {
            product.configureProvider(
                ProviderProfile(
                    request.profileId,
                    request.provider,
                    request.protocol,
                    request.baseUrl,
                    request.apiKeyEnv,
                    dialect: configuredDialectForSetup(
                        request.provider,
                        request.protocol,
                        request.baseUrl
                    )
                ),
                request.model,
                credential: request.credential
            )
        } catch (error: Exception) {
            return "setup error: " + error.message
        }
        match (result) {
            case Result.Ok(_) => "configuration saved; restart axyndra to connect"
            case Result.Err(error) => "setup error: " + error.message
        }
    }

    public func archiveAndReset(): String {
        match (session.handle("/archive-reset tui")) {
            case Result.Ok(response) => response.text
            case Result.Err(error) => "archive/reset error: " + error.message
        }
    }

    public func frontendSlashDefinitions():Array<SlashCommandDefinition> { session.frontendSlashDefinitions() }

    public func todoMarkdown(): TuiTodoLoadResult {
        match (session.todoMarkdown()) {
            case Result.Ok(value) => TuiTodoLoadResult(true, value, "todo loaded")
            case Result.Err(error) => TuiTodoLoadResult(
                false,
                "",
                "todo load error: " + error.message
            )
        }
    }

    public func loadTodoEditor(): TuiTodoLoadResult {
        match(session.loadTodoEditor()){
            case Result.Ok(value)=>TuiTodoLoadResult(true,value,"todo loaded")
            case Result.Err(error)=>
                match(observerTarget()){case Some(events)=>emitCurrentMainApproval(events);case None=>()}
                TuiTodoLoadResult(false,"","todo load error: "+error.message)
        }
    }

    public func saveTodoMarkdown(markdown: String): TuiTodoSaveResult {
        match (session.replaceTodoMarkdown(markdown)) {
            case Result.Ok(message) =>
                let pending=session.approval().isSome()
                if(pending){match(observerTarget()){case Some(events)=>emitCurrentMainApproval(events);case None=>()}}
                TuiTodoSaveResult(!pending, message)
            case Result.Err(error) => TuiTodoSaveResult(
                false,
                "todo parse error: " + error.message
            )
        }
    }

    func copyTodoData180(): TuiTodoLoadResult {
        let phases = match (session.todoPhases()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return TuiTodoLoadResult(false, "", error.message) }
        if (phases.isEmpty()) { return TuiTodoLoadResult(true, "", "No todos to copy.") }
        match (session.todoMarkdown()) {
            case Result.Ok(value) => TuiTodoLoadResult(true, value, "todo loaded")
            case Result.Err(error) => TuiTodoLoadResult(false, "", error.message) }
    }
    public func copyTodoMarkdown(): String {
        let phases = match (session.todoPhases()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return "todo copy error: " + error.message
        }
        if (phases.isEmpty()) {
            return "No todos to copy."
        }
        let markdown = match (session.todoMarkdown()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return "todo copy error: " + error.message
        }
        let isHeadless = match (getVariable("AGENT_TUI_HEADLESS")) {
            case Some(value) => value == "1" || value.toAsciiLower() == "true"
            case None => false
        }
        match (product.copyTextToClipboard(
            markdown,
            nativeEnabled: !isHeadless
        )) {
            case Result.Ok(copied) =>
                if (isHeadless) {
                    return "Clipboard payload encoded for headless verification."
                }
                print("\u{001b}]52;c;" + copied.osc52Base64 + "\u{0007}")
                "Copied todos as Markdown to clipboard" + if (copied.nativeCopied) {
                    " (OSC52 + native)."
                } else {
                    " (OSC52)."
                }
            case Result.Err(error) => "todo copy error: " + error.message
        }
    }

    public func copyTextToClipboard(text: String): String {
        let isHeadless = match (getVariable("AGENT_TUI_HEADLESS")) {
            case Some(value) => value == "1" || value.toAsciiLower() == "true"
            case None => false
        }
        match (product.copyTextToClipboard(text, nativeEnabled: !isHeadless)) {
            case Result.Ok(copied) =>
                if (isHeadless) {
                    "Clipboard payload encoded for headless verification."
                } else {
                    print("\u{001b}]52;c;" + copied.osc52Base64 + "\u{0007}")
                    "Copied card content to clipboard" + if (copied.nativeCopied) {
                        " (OSC52 + native)."
                    } else {
                        " (OSC52)."
                    }
                }
            case Result.Err(error) => "card copy error: " + error.message
        }
    }

    private func begin(
        events: TuiAgentEventSink,
        expectedRunId!: String = ""
    ): Unit {
        lock.lock()
        try {
            if (copiedDisplayProducerClosing) { throw Exception("display.producer_references_closed") }
            sink = Some(events)
            running = true
            uiRunEvents.begin(expectedRunId: expectedRunId)
        } finally {
            lock.unlock()
        }
    }

    private func finish(): Unit {
        lock.lock()
        try {
            running = false
            sink = None
            uiRunEvents.finish()
        } finally {
            lock.unlock()
        }
    }

    private func forward(event: AgentEvent): Unit {
        if (!beginCopiedDisplayProducerBorrow()) { return }
        try { forwardFrame(event) } finally { endCopiedDisplayProducerBorrow() }
    }
    private func forwardFrame(event: AgentEvent): Unit {
        if (!acceptUiRunEvent(event)) { return }
        let target = currentSink()
        match (target) {
            case Some(value) => match (tuiEvent(event)) {
                case Some(mapped) => value(mapped)
                case None => ()
            }
            case None => ()
        }
    }

    private func acceptUiRunEvent(event: AgentEvent): Bool {
        uiRunEvents.accept(event)
    }

    private func forwardAsk(request: ProductAskRequest): Unit {
        if (!beginCopiedDisplayProducerBorrow()) { return }
        try { forwardAskFrame(request) } finally { endCopiedDisplayProducerBorrow() }
    }
    private func forwardAskFrame(request: ProductAskRequest): Unit {
        let target = observerTarget()
        match (target) {
            case Some(events) =>
                let questions = ArrayList<TuiAskQuestion>()
                for (question in request.questions) {
                    let options = ArrayList<TuiAskOption>()
                    for (option in question.options) {
                        options.add(
                            TuiAskOption(
                                option.label,
                                description: option.description,
                                preview: option.preview
                            )
                        )
                    }
                    questions.add(
                        TuiAskQuestion(
                            question.id,
                            question.question,
                            options.toArray(),
                            header: question.header,
                            multi: question.multi,
                            recommended: question.recommended
                        )
                    )
                }
                events(
                    TuiAgentEvent.Ask(
                        TuiAskRequest(
                            request.requestId,
                            questions.toArray(),
                            callId: request.callId,
                            runId: request.runId,
                            sessionId: request.sessionId.value,
                            operationId: request.operationId,
                            commandId: request.commandId,
                            epoch: request.epoch,
                            interactionKind: request.interactionKind
                        )
                    )
                )
            case None => ()
        }
    }

    private func forwardJob(event: ProductAsyncJobEvent): Unit {
        if (!beginCopiedDisplayProducerBorrow()) { return }
        try { forwardJobFrame(event) } finally { endCopiedDisplayProducerBorrow() }
    }
    private func forwardJobFrame(event: ProductAsyncJobEvent): Unit {
        let target = observerTarget()
        match (target) {
            case Some(events) =>
                let job = event.snapshot
                events(
                    TuiAgentEvent.JobStatus(
                        job.id,
                        job.jobType,
                        job.status,
                        job.label,
                        job.durationMillis,
                        job.error
                    )
                )
            case None => ()
        }
    }

    private func forwardSubagent(event: ProductSubagentEvent): Unit {
        if (!beginCopiedDisplayProducerBorrow()) { return }
        try { forwardSubagentFrame(event) } finally { endCopiedDisplayProducerBorrow() }
    }
    private func forwardSubagentFrame(event: ProductSubagentEvent): Unit {
        let surfacedApproval: ?ApprovalRequest
        match (event.approval) {
            case Some(approval) =>
                let pending = TuiPendingSubagentApproval(
                    event.snapshot.id,
                    approval
                )
                lock.lock()
                try {
                    if (pendingSubagentApproval.isNone()) {
                        pendingSubagentApproval = Some(pending)
                        surfacedApproval = Some(approval)
                    } else {
                        queuedSubagentApprovals.add(pending)
                        surfacedApproval = None
                    }
                } finally {
                    lock.unlock()
                }
            case None => surfacedApproval = None
        }
        let target = observerTarget()
        match (target) {
            case Some(events) =>
                let snapshot = event.snapshot
                if (event.kind != "event") {
                    events(
                        TuiAgentEvent.SubagentStatus(
                            TuiSubagentInfo(
                                snapshot.id,
                                snapshot.agent,
                                snapshot.status,
                                if (snapshot.task == "") {
                                    snapshot.description
                                } else {
                                    snapshot.task
                                }
                            ),
                            snapshot.durationMillis,
                            snapshot.error
                        )
                    )
                }
                match (event.event) {
                    case Some(value) => match (tuiSubagentStreamEvent(value)) {
                        case Some(mapped) => events(
                            TuiAgentEvent.SubagentStream(
                                snapshot.id,
                                mapped
                            )
                        )
                        case None => ()
                    }
                    case None => ()
                }
                match (surfacedApproval) {
                    case Some(approval) => events(
                        tuiApprovalEvent(
                            approval,
                            ownerId: event.snapshot.id
                        )
                    )
                    case None => ()
                }
            case None => ()
        }
    }

    private func takePendingSubagentApproval(operationId!: String = ""): ?TuiPendingSubagentApproval {
        lock.lock()
        try {
            match (pendingSubagentApproval) {
                case Some(value) =>
                    if (operationId == "" || value.approval.operationId.value == operationId) {
                        Some(value)
                    } else {
                        None
                    }
                case None => None
            }
        } finally {
            lock.unlock()
        }
    }

    private func clearPendingSubagentApproval(operationId: String): Unit {
        lock.lock()
        try {
            match (pendingSubagentApproval) {
                case Some(value) =>
                    if (value.approval.operationId.value == operationId) {
                        pendingSubagentApproval = None
                    }
                case None => ()
            }
        } finally {
            lock.unlock()
        }
    }

    private func emitPendingSubagentApproval(events: TuiAgentEventSink): Unit {
        let pending = match (takePendingSubagentApproval()) {
            case Some(value) => value
            case None => return
        }
        events(
            tuiApprovalEvent(
                pending.approval,
                ownerId: pending.subagentId
            )
        )
    }

    private func emitCurrentMainApproval(events: TuiAgentEventSink): Unit {
        match (session.approval()) {
            case Some(approval) => events(tuiApprovalEvent(approval))
            case None => ()
        }
    }

    private func emitNextSubagentApproval(events: TuiAgentEventSink): Unit {
        var next: ?TuiPendingSubagentApproval = None
        lock.lock()
        try {
            if (pendingSubagentApproval.isNone() && !queuedSubagentApprovals.isEmpty()) {
                next = Some(queuedSubagentApprovals.remove(at: 0))
                pendingSubagentApproval = next
            }
        } finally {
            lock.unlock()
        }
        match (next) {
            case Some(value) => events(
                tuiApprovalEvent(
                    value.approval,
                    ownerId: value.subagentId
                )
            )
            case None => ()
        }
    }

    private func currentSink(): ?TuiAgentEventSink {
        lock.lock()
        try {
            sink
        } finally {
            lock.unlock()
        }
    }

    private func observerTarget(): ?TuiAgentEventSink {
        lock.lock()
        try {
            observerSink
        } finally {
            lock.unlock()
        }
    }

    private func focusedSubagent(): String {
        lock.lock()
        try {
            focusedSubagentId
        } finally {
            lock.unlock()
        }
    }

    private func emitApproval(result: Result<ApplicationResponse>): Unit {
        match ((result, currentSink())) {
            case (Result.Ok(response), Some(events)) => match (response.approval) {
                case Some(approval) => events(tuiApprovalEvent(approval))
                case None => ()
            }
            case _ => ()
        }
    }
}

func tuiApprovalEvent(
    approval: ApprovalRequest,
    ownerId!: String = ""
): TuiAgentEvent {
    let details = approvalDetails(approval)
    let preview = tuiApprovalPreview(details)
    var inspect = tuiApprovalInspect(details)
    match (details.review) {
        case Some(review) => inspect += "\n\nAI Reviewer\n" + "Risk      " + review.riskLevel + "\n" + "Reviewer  " + review
            .reviewerModel + "\n" + "Reason    " + review.reason
        case None => ()
    }
    TuiAgentEvent.Approval(
        details.toolName,
        details.operationId.value,
        details.callId,
        details.metadata.capabilityLabel,
        match (details.metadata.writeSummary) {
            case Some(summary) => summary.path
            case None => details.capability.resource
        },
        match (details.review) {
            case Some(review) => review.riskLevel
            case None => approvalRiskName(details.risk)
        },
        if (details.metadata.assessment.reasons.isEmpty()) {
            "Existing policy requires explicit approval"
        } else {
            details.metadata.assessment.reasons[0]
        },
        preview,
        tuiApprovalGrantLabel(details.metadata.grantScope),
        "Approval details · " + details.toolName,
        inspect,
        approval.sessionApprovalAllowed,
        ownerId
    )
}

func tuiApprovalPreview(details: ApprovalDetails): String {
    match (details.metadata.writeSummary) {
        case None => approvalDisplayArguments(details)
        case Some(summary) =>
            var value = "Path    " + summary.path + "\n" + "Action  " + match (summary.action) {
                case "overwrite" => "Overwrite existing file"
                case "append" => "Append to file"
                case "truncate" => "Truncate file"
                case _ => "Create file"
            } + "\n" + "Size    " + tuiByteSize(summary.bytes) + " · " + summary.lines.toString() + " lines"
            if (summary.exists) {
                value += "\nBefore  " + tuiByteSize(summary.beforeBytes) + "\nAfter   " + tuiByteSize(summary.bytes)
            }
            if (summary.language != "") {
                value += "\nType    " + summary.language
            }
            if (summary.addedLines > 0 || summary.removedLines > 0) {
                value += "\nChanges +" + summary.addedLines.toString() + " −" + summary.removedLines.toString()
            }
            if (!summary.preview.isEmpty()) {
                value += "\n\nPreview"
                for (line in summary.preview) {
                    value += "\n" + line
                }
                if (summary.truncated) {
                    value += "\n… content truncated …"
                }
            }
            value
    }
}

func approvalDisplayArguments(details: ApprovalDetails): String {
    if (details.toolName == "bash" || details.toolName == "bash_readonly") {
        match (details.arguments.field("command")) {
            case Some(value) =>
                if (value.unifiedKind == ValueKind.Text) {
                    value.text
                } else {
                    ""
                }
            case None => ""
        }
    } else {
        encodeAgentValue(redactApprovalValue(details.arguments, ""))
    }
}

func tuiApprovalInspect(details: ApprovalDetails): String {
    match (details.metadata.writeSummary) {
        case None => approvalDisplayArguments(details)
        case Some(summary) =>
            let content = match (details.arguments.field("content")) {
                case Some(value) =>
                    if (value.unifiedKind == ValueKind.Text) {
                        redactApprovalText(value.text)
                    } else {
                        ""
                    }
                case None => ""
            }
            "Path  " + summary.path + "\nHash  " + summary.contentHash + "\n\n" + content
    }
}

func tuiApprovalGrantLabel(scope: ApprovalGrantScope): String {
    if (scope.pathPrefix != "") {
        "Allow writes under " + scope.pathPrefix + " for this session"
    } else if (scope.capability == "workspace.write") {
        "Allow writes inside the workspace for this session"
    } else if (scope.host != "") {
        "Allow " + scope.capability + " to " + scope.host + " for this session"
    } else {
        "Allow " + scope.capability + " for this session"
    }
}

func tuiByteSize(value: Int64): String {
    if (value < 1024) {
        return value.toString() + " B"
    }
    if (value < 1048576) {
        return (value / 1024).toString() + "." + ((value % 1024) * 10 / 1024).toString() + " KiB"
    }
    (value / 1048576).toString() + "." + ((value % 1048576) * 10 / 1048576).toString() + " MiB"
}

func planReviewFailureDisposition(error: AgentError): TuiPlanReviewDisposition {
    if (error.code == "application.plan_mode_inactive") {
        TuiPlanReviewDisposition.Consumed
    } else {
        TuiPlanReviewDisposition.Retain
    }
}

func emitTurnError(
    result: Result<ApplicationResponse>,
    events: TuiAgentEventSink
): Unit {
    match (result) {
        case Result.Err(error) => events(TuiAgentEvent.Error(error.describe()))
        case _ => ()
    }
}

func tuiResult(
    result: Result<ApplicationResponse>,
    prompt: String
): TuiTurnResult {
    match (result) {
        case Result.Err(error) => TuiTurnResult("", "error: " + error.message)
        case Result.Ok(response) => match (response.approval) {
            case Some(approval) => TuiTurnResult(
                "",
                "approval required · " + approval.toolName + " · " + approval.operationId.value
            )
            case None =>
                let planReview = response.planReview
                let documentTitle = localDocumentTitle(prompt)
                TuiTurnResult(
                    if (documentTitle.isSome()) {
                        ""
                    } else if (response.agentInvoked && response.snapshot.isSome()) {
                        ""
                    } else {
                        response.text
                    },
                    match (response.snapshot) {
                        case Some(snapshot) => runStatusName(snapshot.status)
                        case None => "ready"
                    },
                    action: match (planReview) {
                        case Some(body) => TuiTurnAction.OpenPlanReview(body)
                        case None => match (documentTitle) {
                            case Some(title) => TuiTurnAction.OpenDocument(title, response.text)
                            case None => applicationTuiAction(response)
                        }
                    }
                )
        }
    }
}

func localDocumentTitle(prompt: String): ?String {
    let value = prompt.trimAscii()
    if (value == "/help") {
        return Some("Commands")
    }
    if (value == "/extensions" || value == "/plugins" || value == "/plugins list") {
        return Some("Plugins")
    }
    if (value == "/tree") {
        return Some("Session tree")
    }
    if (value == "/debug") {
        return Some("Diagnostics")
    }
    if (value == "/context") {
        return Some("Context")
    }
    if (value == "/hotkeys") {
        return Some("Keyboard shortcuts")
    }
    if (value == "/changelog" || value == "/changelog full") {
        return Some("Changelog")
    }
    if (value == "/tools") {
        return Some("Tools")
    }
    if (value == "/usage" || value == "/stats") {
        return Some("Usage")
    }
    if (value == "/agents") {
        return Some("Agents")
    }
    if (value == "/jobs") {
        return Some("Jobs")
    }
    if (value == "/queue") {
        return Some("Input queue")
    }
    None
}

func tuiSessionNode(info: ProductSessionInfo, current: Bool): TuiSessionNode {
    TuiSessionNode(
        info.id,
        info.name,
        info.summary,
        info.parentId,
        info.model,
        info.workMode,
        info.updatedAt,
        current,
        archived: info.archived
    )
}

func orderSessionNodes(nodes: Array<TuiSessionNode>): Array<TuiSessionNode> {
    let ordered = ArrayList<TuiSessionNode>()
    let used = ArrayList<String>()
    appendOrderedSessionChildren(nodes, "", ordered, used, 0)
    // Broken/missing parent links degrade to a root instead of hiding data.
    while (used.size < nodes.size) {
        match (newestUnusedSession(nodes, used, parentId: None)) {
            case Some(node) => appendOrderedSessionNode(nodes, node, ordered, used, 0)
            case None => break
        }
    }
    ordered.toArray()
}

func appendOrderedSessionChildren(
    nodes: Array<TuiSessionNode>,
    parentId: String,
    ordered: ArrayList<TuiSessionNode>,
    used: ArrayList<String>,
    depth: Int64
): Unit {
    if (depth > nodes.size) {
        return
    }
    while (true) {
        match (newestUnusedSession(nodes, used, parentId: Some(parentId))) {
            case Some(node) => appendOrderedSessionNode(nodes, node, ordered, used, depth)
            case None => break
        }
    }
}

func appendOrderedSessionNode(
    nodes: Array<TuiSessionNode>,
    node: TuiSessionNode,
    ordered: ArrayList<TuiSessionNode>,
    used: ArrayList<String>,
    depth: Int64
): Unit {
    ordered.add(node)
    used.add(node.id)
    appendOrderedSessionChildren(nodes, node.id, ordered, used, depth + 1)
}

func newestUnusedSession(
    nodes: Array<TuiSessionNode>,
    used: ArrayList<String>,
    parentId!: ?String = None
): ?TuiSessionNode {
    var selected: ?TuiSessionNode = None
    for (node in nodes) {
        if (sessionIdUsed(used, node.id)) {
            continue
        }
        match (parentId) {
            case Some(parent) =>
                if (node.parentId != parent) {
                    continue
                }
            case None => ()
        }
        match (selected) {
            case Some(value) =>
                if (node.updatedAt > value.updatedAt) {
                    selected = Some(node)
                }
            case None => selected = Some(node)
        }
    }
    selected
}

func sessionIdUsed(values: ArrayList<String>, value: String): Bool {
    for (candidate in values where candidate == value) {
        return true
    }
    false
}

func tuiThemeDefinition(theme: ProductThemeDefinition): TuiThemeDefinition {
    TuiThemeDefinition(
        theme.name,
        theme.raised,
        theme.userMessageBg,
        theme.text,
        theme.muted,
        theme.accent,
        theme.secondary,
        theme.success,
        theme.warning,
        theme.danger,
        theme.userMessageText,
        theme.reasoning,
        theme.tool
    )
}

func applicationTuiAction(response: ApplicationResponse): TuiTurnAction {
    if (response.exitRequested) {
        return TuiTurnAction.Exit
    }
    match (response.action) {
        case ApplicationAction.NoAction => TuiTurnAction.NoAction
        case ApplicationAction.OpenProviderSetup => TuiTurnAction.OpenProviderSetup
        case ApplicationAction.OpenModelSelector => TuiTurnAction.OpenModelSelector
        case ApplicationAction.OpenBranchSelector => TuiTurnAction.OpenBranchSelector
    }
}

func tuiEvent(event: AgentEvent): ?TuiAgentEvent {
    match (event.payload) {
        case AgentEventPayload.TextDelta(text) => match (tuiAttemptScope(event)) {
            case Some(scope) => Some(TuiAgentEvent.AttemptTextDelta(scope, text))
            case None => Some(TuiAgentEvent.TextDelta(text))
        }
        case AgentEventPayload.ReasoningDelta(text) => match (tuiAttemptScope(event)) {
            case Some(scope) => Some(TuiAgentEvent.AttemptReasoningDelta(scope, text))
            case None => Some(TuiAgentEvent.ReasoningDelta(text))
        }
        case AgentEventPayload.ModelUsageUpdated(usage) => Some(
            TuiAgentEvent.Usage(usage.inputTokens, usage.outputTokens)
        )
        case AgentEventPayload.ToolStarted(callId, name, _) => Some(
            TuiAgentEvent.ToolStartedWithId(name, callId.value, "")
        )
        case AgentEventPayload.ToolOutput(callId, channel, delta) => Some(
            TuiAgentEvent.ToolOutput(
                callId.value,
                boundedTerminalPreview(delta).text,
                channel == ToolOutputChannel.Stderr
            )
        )
        case AgentEventPayload.ToolCompleted(callId, succeeded, _) => Some(
            TuiAgentEvent.ToolCompletedWithId(
                "tool",
                callId.value,
                !succeeded,
                TuiToolCompletionPayload()
            )
        )
        case AgentEventPayload.ContextCompacted(before, after) => Some(
            TuiAgentEvent.Compaction(before, after, "context budget")
        )
        case AgentEventPayload.Diagnostic(error) => Some(
            TuiAgentEvent.Warning(error.code, error.message)
        )
        case AgentEventPayload.Extension(_, _) => tuiExtensionEvent(event)
        case _ => None
    }
}

// Only independently versioned extension events use a string code. Core
// lifecycle/model/tool events stay typed all the way to the TUI boundary.
func tuiExtensionEvent(event: AgentEvent): ?TuiAgentEvent {
    let code = match (event.payload) {
        case AgentEventPayload.Extension(_, detail) => extensionCode(detail)
        case _ => return None
    }
    match (code) {
        case "model.attempt_policy_applied" =>
            let requested = eventPolicyText(event, "thinking_requested")
            let effective = eventPolicyText(event, "thinking_effective")
            if (requested != "" && effective != "" && requested != effective) {
                Some(TuiAgentEvent.Warning("Thinking", requested + " → " + effective))
            } else {
                None
            }
        case "model.attempt_started" => match (tuiAttemptScope(event)) {
            case Some(scope) => Some(TuiAgentEvent.AttemptStarted(scope))
            case None => None
        }
        case "model.attempt_failed" => match (tuiAttemptScope(event)) {
            case Some(scope) => Some(TuiAgentEvent.AttemptFailed(scope, eventText(event, "error_code")))
            case None => None
        }
        case "model.attempt_cancelled" => match (tuiAttemptScope(event)) {
            case Some(scope) => Some(TuiAgentEvent.AttemptCancelled(scope))
            case None => None
        }
        case "model.attempt_aborted" => match (tuiAttemptScope(event)) {
            case Some(scope) => Some(TuiAgentEvent.AttemptAborted(scope))
            case None => None
        }
        case "model.attempt_retry_scheduled" => match (tuiAttemptScope(event)) {
            case Some(scope) => Some(TuiAgentEvent.AttemptRetryScheduled(scope))
            case None => None
        }
        case "model.decision_committed" => match (tuiAttemptScope(event)) {
            case Some(scope) => Some(TuiAgentEvent.DecisionCommitted(
                scope, eventText(event, "decision_id")
            ))
            case None => None
        }
        case "model.tool_started" => match (tuiAttemptScope(event)) {
            case Some(scope) => Some(TuiAgentEvent.AttemptToolStarted(
                scope, eventText(event, "call_id"), eventText(event, "name")
            ))
            case None => None
        }
        case "model.tool_arguments" => match (tuiAttemptScope(event)) {
            case Some(scope) => Some(TuiAgentEvent.AttemptToolArguments(
                scope, eventText(event, "call_id"), eventText(event, "text")
            ))
            case None => None
        }
        case "model.text_delta" => Some(TuiAgentEvent.TextDelta(eventText(event, "text")))
        case "model.reasoning_delta" => Some(TuiAgentEvent.ReasoningDelta(eventText(event, "text")))
        case "tool.execution_started" => Some(if (eventText(event, "call_id") == "") {
            TuiAgentEvent.ToolStarted(
                eventText(event, "name"),
                encodeEventField(event, "arguments")
            )
        } else {
            TuiAgentEvent.ToolStartedWithId(
                eventText(event, "name"),
                eventText(event, "call_id"),
                encodeEventField(event, "arguments")
            )
        })
        case "tool.execution_completed" => Some(if (eventText(event, "call_id") == "") {
            TuiAgentEvent.ToolCompleted(
                eventText(event, "name"),
                eventBoolean(event, "is_error"),
                tuiToolCompletion(event)
            )
        } else {
            TuiAgentEvent.ToolCompletedWithId(
                eventText(event, "name"),
                eventText(event, "call_id"),
                eventBoolean(event, "is_error"),
                tuiToolCompletion(event)
            )
        })
        case "tool.output_delta" | "tool.output" | "tool.execution_output" => Some(
            TuiAgentEvent.ToolOutput(
                eventText(event, "call_id"),
                tuiToolOutputChunk(event),
                eventBoolean(event, "is_stderr")
            )
        )
        case "interaction.injected" => Some(
            TuiAgentEvent.InputInjected(
                eventText(event, "correlation_id"),
                eventText(event, "kind"),
                eventText(event, "text")
            )
        )
        case "model.usage" => Some(
            TuiAgentEvent.Usage(
                eventInteger(event, "input_tokens"),
                eventInteger(event, "output_tokens")
            )
        )
        case "plan.updated" | "plan" => Some(
            TuiAgentEvent.Plan(
                eventText(event, "id"),
                eventText(event, "body") + if (eventText(event, "body") == "") {
                    eventText(event, "text")
                } else {
                    ""
                }
            )
        )
        case "approval.reviewing" | "approval.ai_approved" | "approval.ai_denied" | "approval.needs_user" => Some(
            TuiAgentEvent.ApprovalReview(
                eventText(event, "request_id"),
                eventText(event, "tool"),
                match (code) {
                    case "approval.reviewing" => "reviewing"
                    case "approval.ai_approved" => "approved"
                    case "approval.ai_denied" => "denied"
                    case _ => "needs_user"
                },
                if (eventText(event, "reviewer_risk_level") == "") {
                    eventText(event, "risk_level")
                } else {
                    eventText(event, "reviewer_risk_level")
                },
                eventText(event, "reviewer_model"),
                eventText(event, "risk_reason"),
                eventText(event, "reason"),
                eventInteger(event, "latency_ms"),
                eventText(event, "failure_type")
            )
        )
        case "diagnostic.warning" | "system.warning" => Some(
            TuiAgentEvent.Warning(
                eventText(event, "title"),
                eventText(event, "message")
            )
        )
        case "context.compacted" | "context.compaction" => Some(
            TuiAgentEvent.Compaction(
                eventInteger(event, "before"),
                eventInteger(event, "after"),
                eventText(event, "reason")
            )
        )
        case "run.summary" | "task.summary" => Some(TuiAgentEvent.Summary(eventText(event, "text")))
        case _ => None
    }
}

func tuiAttemptScope(event: AgentEvent): ?TuiAttemptScope {
    match ((event.meta.semanticRequestId, event.meta.attemptId)) {
        case (Some(semanticRequestId), Some(attemptId)) => Some(TuiAttemptScope(
            event.runId.value, semanticRequestId.value, attemptId.value, event.sequence
        ))
        case _ => None
    }
}

func activeAttemptTuiEvents(page: EventPage): Array<TuiAgentEvent> {
    let active = ArrayList<String>()
    for (event in page.events) {
        let attemptId = match (event.meta.attemptId) {
            case Some(value) => value.value
            case None => continue
        }
        let code = match (event.payload) {
            case AgentEventPayload.Extension(_, detail) => extensionCode(detail)
            case _ => ""
        }
        if (code == "model.attempt_started") {
            if (!active.contains(attemptId)) { active.add(attemptId) }
        } else if (code == "model.attempt_failed" || code == "model.attempt_cancelled" ||
            code == "model.attempt_aborted" || code == "model.decision_committed") {
            var index: Int64 = 0
            while (index < active.size) {
                if (active[index] == attemptId) { active.remove(at: index) } else { index++ }
            }
        }
    }
    let result = ArrayList<TuiAgentEvent>()
    for (event in page.events) {
        match (event.meta.attemptId) {
            case Some(value) => if (active.contains(value.value)) {
                match (tuiEvent(event)) {
                    case Some(mapped) => result.add(mapped)
                    case None => ()
                }
            }
            case None => ()
        }
    }
    result.toArray()
}

func tuiSubagentStreamEvent(event: AgentEvent): ?TuiSubagentStreamEvent {
    match (event.payload) {
        case AgentEventPayload.TextDelta(text) => match (tuiAttemptScope(event)) {
            case Some(scope) => Some(TuiSubagentStreamEvent.AttemptTextDelta(scope, text))
            case None => Some(TuiSubagentStreamEvent.TextDelta(text))
        }
        case AgentEventPayload.ReasoningDelta(text) => match (tuiAttemptScope(event)) {
            case Some(scope) => Some(TuiSubagentStreamEvent.AttemptReasoningDelta(scope, text))
            case None => Some(TuiSubagentStreamEvent.ReasoningDelta(text))
        }
        case AgentEventPayload.ModelUsageUpdated(usage) => Some(
            TuiSubagentStreamEvent.Usage(usage.inputTokens, usage.outputTokens)
        )
        case AgentEventPayload.ToolStarted(callId, name, _) => Some(
            TuiSubagentStreamEvent.ToolStartedWithId(name, callId.value, "")
        )
        case AgentEventPayload.ToolOutput(callId, channel, delta) => Some(
            TuiSubagentStreamEvent.ToolOutput(
                callId.value,
                boundedTerminalPreview(delta).text,
                channel == ToolOutputChannel.Stderr
            )
        )
        case AgentEventPayload.ToolCompleted(callId, succeeded, _) => Some(
            TuiSubagentStreamEvent.ToolCompletedWithId(
                "tool",
                callId.value,
                !succeeded,
                TuiToolCompletionPayload()
            )
        )
        case AgentEventPayload.Extension(_, _) => tuiSubagentExtensionEvent(event)
        case _ => None
    }
}

func tuiSubagentExtensionEvent(event: AgentEvent): ?TuiSubagentStreamEvent {
    let code = match (event.payload) {
        case AgentEventPayload.Extension(_, detail) => extensionCode(detail)
        case _ => return None
    }
    match (code) {
        case "model.attempt_started" => match (tuiAttemptScope(event)) {
            case Some(scope) => Some(TuiSubagentStreamEvent.AttemptStarted(scope))
            case None => None
        }
        case "model.attempt_failed" => match (tuiAttemptScope(event)) {
            case Some(scope) => Some(TuiSubagentStreamEvent.AttemptFailed(scope))
            case None => None
        }
        case "model.attempt_cancelled" => match (tuiAttemptScope(event)) {
            case Some(scope) => Some(TuiSubagentStreamEvent.AttemptCancelled(scope))
            case None => None
        }
        case "model.attempt_aborted" | "model.attempt_retry_scheduled" => match (tuiAttemptScope(event)) {
            case Some(scope) => Some(TuiSubagentStreamEvent.AttemptAborted(scope))
            case None => None
        }
        case "model.decision_committed" => match (tuiAttemptScope(event)) {
            case Some(scope) => Some(TuiSubagentStreamEvent.DecisionCommitted(scope))
            case None => None
        }
        case "model.tool_started" => match (tuiAttemptScope(event)) {
            case Some(scope) => Some(TuiSubagentStreamEvent.AttemptToolStarted(
                scope, eventText(event, "call_id"), eventText(event, "name")
            ))
            case None => None
        }
        case "model.tool_arguments" => match (tuiAttemptScope(event)) {
            case Some(scope) => Some(TuiSubagentStreamEvent.AttemptToolArguments(
                scope, eventText(event, "call_id"), eventText(event, "text")
            ))
            case None => None
        }
        case "model.text_delta" => Some(TuiSubagentStreamEvent.TextDelta(eventText(event, "text")))
        case "model.reasoning_delta" => Some(TuiSubagentStreamEvent.ReasoningDelta(eventText(event, "text")))
        case "tool.execution_started" => Some(if (eventText(event, "call_id") == "") {
            TuiSubagentStreamEvent.ToolStarted(
                eventText(event, "name"),
                encodeEventField(event, "arguments")
            )
        } else {
            TuiSubagentStreamEvent.ToolStartedWithId(
                eventText(event, "name"),
                eventText(event, "call_id"),
                encodeEventField(event, "arguments")
            )
        })
        case "tool.execution_completed" => Some(if (eventText(event, "call_id") == "") {
            TuiSubagentStreamEvent.ToolCompleted(
                eventText(event, "name"),
                eventBoolean(event, "is_error"),
                tuiToolCompletion(event)
            )
        } else {
            TuiSubagentStreamEvent.ToolCompletedWithId(
                eventText(event, "name"),
                eventText(event, "call_id"),
                eventBoolean(event, "is_error"),
                tuiToolCompletion(event)
            )
        })
        case "tool.output_delta" | "tool.output" | "tool.execution_output" => Some(
            TuiSubagentStreamEvent.ToolOutput(
                eventText(event, "call_id"),
                tuiToolOutputChunk(event),
                eventBoolean(event, "is_stderr")
            )
        )
        case "interaction.injected" => Some(
            TuiSubagentStreamEvent.InputInjected(
                eventText(event, "correlation_id"),
                eventText(event, "kind"),
                eventText(event, "text")
            )
        )
        case "model.usage" => Some(
            TuiSubagentStreamEvent.Usage(
                eventInteger(event, "input_tokens"),
                eventInteger(event, "output_tokens")
            )
        )
        case _ => None
    }
}

func tuiToolOutputChunk(event: AgentEvent): String {
    let text = eventText(event, "text")
    if (text != "") {
        return boundedTerminalPreview(text).text
    }
    let chunk = eventText(event, "chunk")
    if (chunk != "") {
        return boundedTerminalPreview(chunk).text
    }
    boundedTerminalPreview(eventText(event, "output")).text
}

func tuiToolCompletion(event: AgentEvent): TuiToolCompletionPayload {
    match (event.detail.field("output")) {
        case Some(value) => projectTuiToolCompletion(value, eventText(event, "name"))
        case None => TuiToolCompletionPayload()
    }
}

func tuiTranscriptItems(
    messages: Array<ModelMessage>,
    prefix: String
): Array<TuiTranscriptItem> {
    let items = ArrayList<TuiTranscriptItem>()
    let toolItemIndexes = HashMap<String, Int64>()
    for (messageIndex in 0..messages.size) {
        let message = messages[messageIndex]
        for (blockIndex in 0..message.blocks.size) {
            let block = message.blocks[blockIndex]
            let id = prefix + "-" + messageIndex.toString() + "-" + blockIndex.toString()
            match (block.kind) {
                case ModelBlockKind.Text | ModelBlockKind.Unknown =>
                    if (block.text != "") {
                        items.add(
                            TuiTranscriptItem(
                                id,
                                if (message.role == ModelRole.User) {
                                    UiCardKind.User
                                } else {
                                    UiCardKind.Assistant
                                },
                                if (message.role == ModelRole.User) {
                                    "You"
                                } else {
                                    "Assistant"
                                },
                                block.text
                            )
                        )
                    }
                case ModelBlockKind.Image =>
                    let imageSummary = match (block.image) {
                        case Some(image) => match (image.sourceKind) {
                            case ModelImageSourceKind.Url => "Image input (URL)"
                            case ModelImageSourceKind.Base64 => if (image.mediaType == "") {
                                "Image input (embedded)"
                            } else {
                                "Image input (" + image.mediaType + ")"
                            }
                        }
                        case None => "Image input"
                    }
                    items.add(
                        TuiTranscriptItem(
                            id,
                            if (message.role == ModelRole.User) {
                                UiCardKind.User
                            } else {
                                UiCardKind.Assistant
                            },
                            if (message.role == ModelRole.User) {
                                "You"
                            } else {
                                "Assistant"
                            },
                            imageSummary
                        )
                    )
                case ModelBlockKind.Reasoning =>
                    if (block.text != "") {
                        items.add(
                            TuiTranscriptItem(
                                id,
                                UiCardKind.Reasoning,
                                "Thinking",
                                block.text,
                                collapsed: true
                            )
                        )
                    }
                case ModelBlockKind.ToolCall =>
                    let toolName = if (block.name == "") { "tool" } else { block.name }
                    let arguments = encodeAgentValue(block.arguments)
                    let toolId = restoredToolCardId(prefix, id, block.callId)
                    items.add(
                        TuiTranscriptItem(
                            toolId,
                            UiCardKind.Tool,
                            summarizeToolCall(toolName, arguments),
                            "pending",
                            state: "pending",
                            collapsed: true,
                            toolName: toolName,
                            toolArguments: arguments,
                            toolCallId: block.callId
                        )
                    )
                    if (block.callId != "") {
                        toolItemIndexes[block.callId] = items.size - 1
                    }
                case ModelBlockKind.ToolResult =>
                    let priorIndex = match (toolItemIndexes.get(block.callId)) {
                        case Some(value) => value
                        case None => -1
                    }
                    let prior: ?TuiTranscriptItem = if (priorIndex >= 0) {
                        Some(items[priorIndex])
                    } else {
                        None
                    }
                    let toolName = match (prior) {
                        case Some(value) => value.toolName
                        case None => if (block.name == "") { "tool" } else { block.name }
                    }
                    let arguments = match (prior) {
                        case Some(value) => value.toolArguments
                        case None => ""
                    }
                    let toolId = match (prior) {
                        case Some(value) => value.id
                        case None => restoredToolCardId(prefix, id, block.callId)
                    }
                    let completion = projectRestoredTuiToolCompletion(block.text, toolName)
                    let restored = TuiTranscriptItem(
                        toolId,
                        UiCardKind.Tool,
                        toolTitleWithStats(toolName, arguments, completion.detailPreview),
                        if (block.isError) { "failed" } else { "completed" },
                        state: if (block.isError) { "failed" } else { "completed" },
                        collapsed: !block.isError && completion.detailPreview != "",
                        toolName: toolName,
                        toolArguments: arguments,
                        toolCallId: block.callId,
                        toolOutput: completion.detailPreview
                    )
                    if (priorIndex >= 0) {
                        items[priorIndex] = restored
                    } else {
                        items.add(restored)
                        if (block.callId != "") {
                            toolItemIndexes[block.callId] = items.size - 1
                        }
                    }
                case ModelBlockKind.Refusal => items.add(
                    TuiTranscriptItem(
                        id,
                        UiCardKind.Error,
                        "Refusal",
                        block.text,
                        state: "failed"
                    )
                )
                case ModelBlockKind.Error => items.add(
                    TuiTranscriptItem(
                        id,
                        UiCardKind.Error,
                        "Error",
                        block.text,
                        state: "failed"
                    )
                )
            }
        }
    }
    items.toArray()
}

func canonicalTuiTranscriptPage(page: ThreadItemsPage): TuiTranscriptPage {
    TuiTranscriptPage(
        tuiTranscriptItems(
            modelMessagesFromCanonicalItems(page.items),
            "main-canonical-" + page.nextBeforeOrdinal.toString()
        ),
        page.nextBeforeOrdinal,
        page.hasMore
    )
}

func restoredToolCardId(prefix: String, positionalId: String, callId: String): String {
    if (callId == "") {
        return positionalId
    }
    prefix + "-tool-" + callId
}

func eventText(event: AgentEvent, name: String): String {
    match (event.detail.field(name)) {
        case Some(value) => value.text
        case None => ""
    }
}

func eventPolicyText(event: AgentEvent, name: String): String {
    match (event.detail.field("policy")) {
        case Some(policy) => match (policy.field(name)) {
            case Some(value) => value.text
            case None => ""
        }
        case None => ""
    }
}

func eventInteger(event: AgentEvent, name: String): Int64 {
    match (event.detail.field(name)) {
        case Some(value) => try {
            Int64.parse(value.asNumberText())
        } catch (_: Exception) {
            0
        }
        case None => 0
    }
}

func eventBoolean(event: AgentEvent, name: String): Bool {
    match (event.detail.field(name)) {
        case Some(value) => value.unifiedKind == ValueKind.Boolean && value.asBool()
        case None => false
    }
}

func encodeEventField(event: AgentEvent, name: String): String {
    match (event.detail.field(name)) {
        case Some(value) => encodeAgentValue(value)
        case None => ""
    }
}

func extensionCode(detail: AgentValue): String {
    match (detail.field("code")) {
        case Some(value) => value.text
        case None => ""
    }
}

// Same-bank aliases are independent consumers, not a grant to dispatch or retry.
private let CLI_FAILURE_PREPAY_REFUSED113 = IllegalStateException("CLI failure control payment refused")
private enum CliFailureAlias113 {
    Publication(OwnedFailureRunPublication113) | Data(OwnedFailureDataConsumer113)
    func prepay(bytes: Int64): Bool {
        try {
            match (this) {
                case Publication(value) => value.withError({ _, fund => fund(bytes) }).isOk()
                case Data(value) => value.withError({ _, fund =>
                    if (fund(bytes).isError()) { throw CLI_FAILURE_PREPAY_REFUSED113 }
                }).isOk()
            }
        } catch (_: Exception) { false }
    }
    func retain(): ?CliFailureAlias113 {
        match (this) {
            case Publication(value) => match (value.retainConsumer()) {
                case Result.Ok(child) => Some(CliFailureAlias113.Publication(child)); case Result.Err(_) => None<CliFailureAlias113> }
            case Data(value) => match (value.retainConsumer()) {
                case Result.Ok(child) => Some(CliFailureAlias113.Data(child)); case Result.Err(_) => None<CliFailureAlias113> }
        }
    }
    func write(output: RpcOutput, json: Bool): OwnedFailureDataOutcome113<Unit> {
        match (this) {
            case Publication(value) => output.writeFailureFrame113(value, { error, fund => renderCliFailure113(error, fund, json) })
            case Data(value) => output.writeFailureFrame113(value, { error, fund => renderCliFailure113(error, fund, json) })
        }
    }
    func acknowledged(): Bool {
        match (this) { case Publication(value) => value.isAcknowledged(); case Data(value) => value.isAcknowledged() }
    }
    func acknowledge(): Bool {
        match (this) { case Publication(value) => value.acknowledgeAfterConsumption().isOk()
            case Data(value) => value.acknowledgeAfterConsumption().isOk() }
    }
}

private func renderCliFailure113(error: AgentError, fund: (Int64) -> Result<Unit>, json: Bool): Result<String> {
    let size = error.code.size
    if (size > Int64.Max - error.message.size || size + error.message.size > (Int64.Max - 16384) / 8) {
        throw IllegalStateException("CLI failure prefix extent overflow") }
    match (fund(16384 + (size + error.message.size) * 8)) {
        case Result.Err(failure) => return Result<String>.Err(failure); case Result.Ok(_) => () }
    let encoded = if (json) {
        encodeOwnedFailureError113(error, [ValueField("type", textValue("error")),
            ValueField("code", textValue(error.code)), ValueField("message", textValue(error.message))], "error_data", fund)
    } else { encodeOwnedFailureError113(error, fund) }
    match (encoded) {
        case Result.Err(failure) => Result<String>.Err(failure)
        case Result.Ok(actual) =>
            if (json) { return Result<String>.Ok(actual) }
            if (actual.size > (Int64.Max - 16384) / 4) { throw IllegalStateException("CLI failure output extent overflow") }
            match (fund(16384 + actual.size * 4)) {
                case Result.Err(failure) => Result<String>.Err(failure)
                case Result.Ok(_) => Result<String>.Ok("error[" + error.code + "]: " + error.message + "\n" + actual) }
    }
}

private class CliFailureDelivery113 {
    private var source: ?CliFailureAlias113
    private var stdout: ?CliFailureAlias113
    private var control: ?CliFailureAlias113
    private var secondary: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    private var offered = false
    private var returned = false
    private var succeeded = false
    init(source: CliFailureAlias113, stdout: CliFailureAlias113, control: CliFailureAlias113) {
        this.source = Some(source); this.stdout = Some(stdout); this.control = Some(control)
    }
    func offer(output: RpcOutput, json: Bool): Unit {
        if (offered) { return }
        // Set before entering the writer. Failure or a partial prefix is never replayed.
        offered = true
        try {
            match (stdout.getOrThrow().write(output, json)) {
                case OwnedFailureDataOutcome113.Failure(actual) => secondary = Some(actual)
                case OwnedFailureDataOutcome113.Value(_) => succeeded = stdout.getOrThrow().acknowledged() }
            returned = true
        } catch (failure: OwnedCanonicalPaidFailure113) { secondary = Some(failure.takeConsumer()) }
          catch (_: Exception) { () }
    }
    func sourceReady(): Bool {
        returned && succeeded && secondary.isNone() && stdout.getOrThrow().acknowledged()
    }
    func sourceData(): ?CliFailureAlias113 { source }
    func clearTransferredSource(): Unit { source = None<CliFailureAlias113> }
    func controlData(): CliFailureAlias113 { control.getOrThrow() }
    func clearAfterSourceAcknowledgement(): Unit {
        source = None<CliFailureAlias113>; stdout = None<CliFailureAlias113>
        control = None<CliFailureAlias113>
    }
}

// Main reserves this fixed controller before its Mutex/slots/output exist.
// The actual Native reservation remains held for the Root process lifetime:
// subscribeOwned has no unsubscribe, so mode return cannot prove those callback
// aliases and their fixed metadata have retired. It is never a payload ACK.
class CliFailureOutput113 <: OwnedFailureEventSink113 & OwnedFailureEventAdmission113 {
    private let rootMetadata: LogicalJsonOwnerReservation
    private let lock = Mutex()
    private let output: RpcOutput
    private let json: Bool
    private var session: ?ApplicationSession = None<ApplicationSession>
    private var rejectedMarker: ?AgentError = None<AgentError>
    private var pending: ?CliFailureDelivery113 = None<CliFailureDelivery113>
    private var stagingStdout: ?CliFailureAlias113 = None<CliFailureAlias113>
    private var stagingControl: ?CliFailureAlias113 = None<CliFailureAlias113>
    private var retiringSource: ?CliFailureAlias113 = None<CliFailureAlias113>
    private var retiringControl: ?CliFailureAlias113 = None<CliFailureAlias113>
    init(metadata: LogicalJsonOwnerReservation, json: Bool, io!: CliIo180 = consoleCliIo180) {
        this.rootMetadata = metadata; this.json = json; this.output = RpcOutput(io: io)
    }
    func bindSession(actual: ApplicationSession): Unit {
        lock.lock(); try { session = Some(actual) } finally { lock.unlock() }
    }
    // Explicit diagnostic ignore consumes only this event share. Its loan frame
    // has returned before ACK; the actual caller is a separate stdout delivery.
    public func emitOwnedFailure113(value: OwnedFailureRunPublication113): Result<Unit> {
        match (value.withError({ _, _ => Result<Unit>.Ok(()) })) {
            case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(_) => () }
        value.acknowledgeAfterConsumption()
    }
    public func admitOwnedFailure113(value: OwnedFailureRunPublication113): OwnedFailureEventAdmissionOutcome113 {
        if (emitOwnedFailure113(value).isOk() && value.isAcknowledged()) {
            OwnedFailureEventAdmissionOutcome113.Accepted
        } else { OwnedFailureEventAdmissionOutcome113.Held }
    }
    public func emitOwnedFailureOutcome113(value: OwnedFailureRunPublication113): OwnedFailureDataOutcome113<Unit> {
        match (emitOwnedFailure113(value)) {
            case Result.Ok(_) => OwnedFailureDataOutcome113<Unit>.Value(())
            case Result.Err(error) => value.captureFailure113<Unit>(error) }
    }
    private func register(value: OwnedAgentRunResult113): Bool {
        lock.lock()
        try {
            if (pending.isSome() || stagingStdout.isSome() || stagingControl.isSome() ||
                retiringSource.isSome() || retiringControl.isSome()) { return false }
            // The installed Root already pays these fixed alias/slot wrappers.
            // Retain the real control share in that reachable slot FIRST. Its
            // own constructor prepays every copied metadata field. A concurrent
            // source loan may refuse reentry, but does not forbid deriving this
            // independent immutable DATA share or authorize the source's ACK.
            let actual = match (value) {
                case OwnedAgentRunResult113.Failed(publication) => CliFailureAlias113.Publication(publication)
                case OwnedAgentRunResult113.Pending(consumer) => CliFailureAlias113.Data(consumer)
                case _ => return false }
            stagingControl = actual.retain()
            if (stagingControl.isNone()) { return false }
            // The independent control loan funds the delivery envelope BEFORE
            // allocation. Refusal keeps both original source and staged control
            // reachable; it neither discards debt nor offers stdout twice.
            if (!stagingControl.getOrThrow().prepay(8192)) { return false }
            stagingStdout = actual.retain()
            if (stagingStdout.isNone()) { return false }
            pending = Some(CliFailureDelivery113(actual, stagingStdout.getOrThrow(), stagingControl.getOrThrow()))
            stagingStdout = None<CliFailureAlias113>; stagingControl = None<CliFailureAlias113>
            true
        } finally { lock.unlock() }
    }
    private func stageSourceRetirement(): Unit {
        lock.lock()
        try {
            if (retiringSource.isSome()) { return }
            let node = match (pending) { case Some(actual) => actual; case None => return }
            node.offer(output, json)
            if (!node.sourceReady()) { return }
            match (node.sourceData()) {
                case None => ()
                case Some(actual) =>
                    retiringSource = Some(actual)
                    // Root installed the exact alias before the node clears it.
                    node.clearTransferredSource() }
        } finally { lock.unlock() }
    }
    private func acknowledgeRetiringSource(): Unit {
        lock.lock()
        try {
            match (retiringSource) {
                case Some(actual) => if (actual.acknowledge()) { retiringSource = None<CliFailureAlias113> }
                case None => () }
        } finally { lock.unlock() }
    }
    private func stageControlRetirement(): Unit {
        lock.lock()
        try {
            if (retiringSource.isSome() || retiringControl.isSome()) { return }
            let node = match (pending) { case Some(actual) => actual; case None => return }
            if (!node.sourceReady() || node.sourceData().isSome()) { return }
            retiringControl = Some(node.controlData())
            node.clearAfterSourceAcknowledgement()
            pending = None<CliFailureDelivery113>
            // The control ACK runs only after this complete node helper frame
            // returns; rendering/stdout/source and all node fields are clear.
        } finally { lock.unlock() }
    }
    private func acknowledgeRetiringControl(): Unit {
        lock.lock()
        try {
            match (retiringControl) {
                case Some(actual) => if (actual.acknowledge()) { retiringControl = None<CliFailureAlias113> }
                case None => () }
        } finally { lock.unlock() }
    }
    private func progress(): Unit {
        // These are separate returned frames. A failed ACK leaves its original
        // exact alias installed; only ACKs may be polled, never stdout offers.
        stageSourceRetirement()
        acknowledgeRetiringSource()
        stageControlRetirement()
        acknowledgeRetiringControl()
    }
    func hasPending(): Bool {
        lock.lock(); try {
            rejectedMarker.isSome() || pending.isSome() || stagingStdout.isSome() || stagingControl.isSome() ||
                retiringSource.isSome() || retiringControl.isSome()
        } finally { lock.unlock() }
    }
    func consumeCaller(actualSession: ApplicationSession, marker: AgentError): Bool {
        if (!actualSession.hasOwnedCheckpointFailure113(marker)) { return false }
        lock.lock(); try { session = Some(actualSession); rejectedMarker = Some(marker) } finally { lock.unlock() }
        let accepted = try { actualSession.admitOwnedCheckpointFailure113(marker, { actual => register(actual) }) }
            catch (_: Exception) { false }
        if (accepted) {
            // Application's handoff/finally frame has really returned before
            // source ACK is possible. No callback-return inference is used.
            lock.lock(); try { rejectedMarker = None<AgentError> } finally { lock.unlock() }
            try { progress() } catch (_: Exception) { () }
        }
        actualSession.collectOwnedCheckpointFailure113()
        if (hasPending()) { eprintln("cli.failure_output_pending") }
        true
    }
    func finishMode(originalStatus: Int64): Int64 {
        try { progress() } catch (_: Exception) { () }
        match (session) { case Some(actual) => actual.collectOwnedCheckpointFailure113(); case None => () }
        if (hasPending()) {
            eprintln("cli.failure_output_pending")
            if (originalStatus == 0) { return 1 }
        }
        // Keep original status and actual Root custody. No product.close,
        // physical exit, callback return or reservation close stands for ACK.
        originalStatus
    }
}

func printError(error: AgentError, io!: CliIo180 = consoleCliIo180): Unit {
    io.println("error[" + error.code + "]: " + error.message)
}

func joinArguments(arguments: Array<String>, from: Int64): String {
    var result = ""
    for (index in from..arguments.size) {
        if (result != "") {
            result += " "
        }
        result += arguments[index]
    }
    result
}

func runStatusName(status: RunState): String {
    match (status) {
        case RunState.Created => "queued"
        case RunState.Running => "running"
        case RunState.WaitingApproval => "awaiting_approval"
        case RunState.WaitingExternal => "waiting_external"
        case RunState.Cancelling => "cancelling"
        case RunState.Cancelled => "cancelled"
        case RunState.Completed => "completed"
        case RunState.Failed => "failed"
        case RunState.RecoveryRequired => "recovery_required"
    }
}

// Interactive confirmation is read only after displaying the actual frozen
// review. No plugin response or CLI DTO manufactures a user approval.
func runSelectedWorkspaceCli(session: ApplicationSession, contribution: String, args: AgentValue, interactive: Bool, io!: CliIo180 = consoleCliIo180): Int64 {
    let invocation=match(session.invokeWorkspaceTool(contribution,args)){
        case Result.Err(error)=>printError(error, io: io);return 1;case Result.Ok(value)=>value}
    try{
        var reviews:Int64=0
        while(invocation.approval().isSome()){
            let approval=invocation.approval().getOrThrow()
            io.println(encodeAgentValue(approval.preview))
            if(!interactive){io.println("Approval required; repeat with --interactive to review this actual Root.");return 1}
            if(reviews>=2){io.println("error: too many independent native Root reviews");return 1};reviews++
            io.println("Type approve "+approval.operationId.value+" to approve this exact Root; any other response rejects it.")
            let choice=match(io.readln()){case Some(value)=>value;case None=>""}
            let decision=if(choice=="approve "+approval.operationId.value){ApprovalDecision.Approve}else{ApprovalDecision.Reject}
            match(invocation.decide(approval.operationId.value,decision)){case Result.Err(error)=>printError(error, io: io);return 1;case Result.Ok(_)=>()}
        }
        let output=match(invocation.output()){case Result.Err(error)=>printError(error, io: io);return 1;case Result.Ok(value)=>value}
        let hasResource=output.field("resource_request").isSome() || output.field("application_plan").isSome()
        if(hasResource && interactive){
            io.println(encodeAgentValue(output))
            io.println("Type execute-resource to submit a separate canonical Root for this exact frozen resource or file plan; any other response leaves it unapplied.")
            let choice=match(io.readln()){case Some(value)=>value;case None=>""}
            if(choice!="execute-resource"){return 0}
            let resource=match(invocation.beginResource()){case Result.Err(error)=>printError(error, io: io);return 1;case Result.Ok(value)=>value}
            try{
                var resourceReviews:Int64=0
                while(resource.approval().isSome()){
                    if(resourceReviews>=2){io.println("error: too many independent resource Root reviews");return 1};resourceReviews++
                    let approval=resource.approval().getOrThrow()
                    io.println(encodeAgentValue(approval.preview))
                    io.println("Type approve "+approval.operationId.value+" to approve this separate exact resource Root; any other response rejects it.")
                    let answer=match(io.readln()){case Some(value)=>value;case None=>""}
                    let decision=if(answer=="approve "+approval.operationId.value){ApprovalDecision.Approve}else{ApprovalDecision.Reject}
                    match(resource.decide(approval.operationId.value,decision)){case Result.Err(error)=>printError(error, io: io);return 1;case Result.Ok(_)=>()}
                }
                let result=match(resource.output()){case Result.Err(error)=>printError(error, io: io);return 1;case Result.Ok(value)=>value}
                printWorkspaceCliOutput(result, io: io)
            }finally{let _=resource.close()}
        }else{printWorkspaceCliOutput(output, io: io)}
        0
    }finally{let _=invocation.close()}
}
func printWorkspaceCliOutput(output: AgentValue, io!: CliIo180 = consoleCliIo180): Unit {
    let content=output.field("content") ?? output.field("entries") ?? output.field("matches") ?? output.field("paths") ?? textValue(encodeAgentValue(output))
    let text=if(content.unifiedKind==ValueKind.Text){content.text}else{encodeAgentValue(output)}
    io.print(text);if(!text.endsWith("\n")){io.println()}
}


// Additive test entry only. The caller reserves the SAME Native root before
// this facade/controller exists. No writer, flush, Source or ACK is injected.
// Original CLI methods and the command-line flow are untouched.
class ActualCliFailureFacade95 <: OwnedFailureEventSink113 & OwnedFailureEventAdmission113 {
    private let original: CliFailureOutput113
    init(metadata: LogicalJsonOwnerReservation, json: Bool) {
        metadata.ensureRetainedPeak(65536)
        original = CliFailureOutput113(metadata, json)
    }
    func bindSession(actual: ApplicationSession): Unit { original.bindSession(actual) }
    func consumeCaller(actual: ApplicationSession, marker: AgentError): Bool {
        original.consumeCaller(actual, marker)
    }
    func finishMode(status: Int64): Int64 { original.finishMode(status) }
    func hasPending(): Bool { original.hasPending() }
    public func emitOwnedFailure113(value: OwnedFailureRunPublication113): Result<Unit> {
        original.emitOwnedFailure113(value)
    }
    public func emitOwnedFailureOutcome113(value: OwnedFailureRunPublication113): OwnedFailureDataOutcome113<Unit> {
        original.emitOwnedFailureOutcome113(value)
    }
    public func admitOwnedFailure113(value: OwnedFailureRunPublication113): OwnedFailureEventAdmissionOutcome113 {
        original.admitOwnedFailure113(value)
    }
}

// DATA receipts are minted only in the actual synchronous stdout consumer.
private class RetiredActualRegistryCliReferences161 <: OwnedRegistryResponseRetirement161 {
    init() {}
    public func copiedReferencesRetired(): Bool { true }
}
private class HeldActualRegistryCliNode161 {
    private let response: OwnedApplicationRegistryResponse161
    private let previous: ?HeldActualRegistryCliNode161
    init(response: OwnedApplicationRegistryResponse161, previous: ?HeldActualRegistryCliNode161) {
        this.response = response; this.previous = previous
    }
}
private class HeldActualRegistryCli161 {
    private let lock = Mutex()
    private var head: ?HeldActualRegistryCliNode161 = None
    func hold(response: OwnedApplicationRegistryResponse161): Unit {
        lock.lock()
        try { head = Some(HeldActualRegistryCliNode161(response, head)) }
        finally { lock.unlock() }
    }
}
private let heldActualRegistryCli161 = HeldActualRegistryCli161()

private func prepayActualRegistryCli161(owned: OwnedApplicationRegistryResponse161, json: Bool): Unit {
    owned.prepayConsumerCopies161(owned.copiedResponseCopyInvoice161(json))
}
private func appConsumeOwnedRegistryPlain161(owned: OwnedApplicationRegistryResponse161,
    session: ApplicationSession, stream: StreamState, failures: CliFailureOutput113, io!: CliIo180 = consoleCliIo180): Int64 {
    try {
        prepayActualRegistryCli161(owned, false)
        let actual = owned.borrowForCli161({ result =>
            actualRegistryPlainStdoutFrame161(result, session, stream, failures, io: io)
        })
        if (!actual[0]) { heldActualRegistryCli161.hold(owned); return actual[1] }
        // Formatter, stdout and callback frames all returned before this token.
        if (!owned.closeAfterActualCopiedResponse161(RetiredActualRegistryCliReferences161())) {
            heldActualRegistryCli161.hold(owned)
        }
        actual[1]
    } catch (_: Exception) { heldActualRegistryCli161.hold(owned); 1 }
}
private func actualRegistryPlainStdoutFrame161(result: Result<ApplicationResponse>,
    session: ApplicationSession, stream: StreamState, failures: CliFailureOutput113, io!: CliIo180 = consoleCliIo180): (Bool, Int64) {
    try {
        let status = originalRegistryPlainProjectionFrame161(result, session, stream, failures, io: io)
        io.flush()
        (true, status)
    } catch (_: Exception) { (false, 1) }
}
private func appConsumeOwnedRegistryJson161(owned: OwnedApplicationRegistryResponse161,
    session: ApplicationSession, stream: ApplicationJsonEventStream, failures: CliFailureOutput113, io!: CliIo180 = consoleCliIo180): Int64 {
    try {
        prepayActualRegistryCli161(owned, true)
        let actual = owned.borrowForCli161({ result =>
            actualRegistryJsonStdoutFrame161(result, session, stream, failures, io: io)
        })
        if (!actual[0]) { heldActualRegistryCli161.hold(owned); return actual[1] }
        if (!owned.closeAfterActualCopiedResponse161(RetiredActualRegistryCliReferences161())) {
            heldActualRegistryCli161.hold(owned)
        }
        actual[1]
    } catch (_: Exception) { heldActualRegistryCli161.hold(owned); 1 }
}
private func actualRegistryJsonStdoutFrame161(result: Result<ApplicationResponse>,
    session: ApplicationSession, stream: ApplicationJsonEventStream, failures: CliFailureOutput113, io!: CliIo180 = consoleCliIo180): (Bool, Int64) {
    try {
        let status = originalRegistryJsonProjectionFrame161(result, session, stream, failures, io: io)
        io.flush()
        (true, status)
    } catch (_: Exception) { (false, 1) }
}

// The same synchronous Main formatters can be reused by a long-lived Session
// without creating another Session or subscription for every command. The
// caller supplies an actual original-Registry DATA lease before construction.
class RegistrySessionCliConsumer161 {
    private let lock = Mutex()
    private var metadata: ?LogicalJsonOwnerReservation
    private var session: ?ApplicationSession
    private var failures: ?CliFailureOutput113
    private var plain: ?StreamState
    private var jsonStream: ?ApplicationJsonEventStream
    private let json: Bool
    private let io: CliIo180
    private var closed = false
    init(session: ApplicationSession, metadata: LogicalJsonOwnerReservation, json: Bool, io!: CliIo180 = consoleCliIo180) {
        this.metadata = Some(metadata); this.session = Some(session); this.json = json; this.io = io
        let actual = CliFailureOutput113(metadata, json, io: io)
        actual.bindSession(session)
        this.failures = Some(actual)
        this.plain = Some(StreamState())
        this.jsonStream = Some(ApplicationJsonEventStream({ event =>
            appWriteRegistryLineChecked181(encodeAgentValue(applicationJsonEventValue(event)), io: io)
        }, io: io))
    }
    func print(input: String): Int64 {
        lock.lock()
        try {
            if (closed) { throw IllegalStateException("registry CLI consumer is closed") }
            match (session.getOrThrow().ownedRegistryCommand161(input)) {
                case Some(owned) =>
                    if (json) {
                        appConsumeOwnedRegistryJson161(owned, session.getOrThrow(), jsonStream.getOrThrow(), failures.getOrThrow(), io: io)
                    } else {
                        appConsumeOwnedRegistryPlain161(owned, session.getOrThrow(), plain.getOrThrow(), failures.getOrThrow(), io: io)
                    }
                case None => throw IllegalStateException("input is not a Registry maintenance command")
            }
        } finally { lock.unlock() }
    }
    private func clearReturnedConsumerFields161(): Unit {
        // Only paid DATA/control envelopes remain in this helper. No formatter,
        // stdout callback or response reference is active when print returned.
        session = None; failures = None; plain = None; jsonStream = None
    }
    func closeAfterConsumersReturned161(): Bool {
        lock.lock()
        try {
            if (closed) { return true }
            if (failures.getOrThrow().hasPending()) { return false }
            clearReturnedConsumerFields161()
            match (metadata) { case Some(value) => metadata = None; value.close(); case None => () }
            closed = true; true
        } finally { lock.unlock() }
    }
}

private func originalRegistryPlainProjectionFrame161(result: Result<ApplicationResponse>, session: ApplicationSession, stream: StreamState, failures: CliFailureOutput113, io!: CliIo180 = consoleCliIo180): Int64 {
    match (result) {
        case Result.Err(error) =>
            if (stream.wroteText) {
                appWriteRegistryLineChecked181("", io: io)
            }
            if (!failures.consumeCaller(session, error)) { appWriteRegistryLineChecked181("error[" + error.code + "]: " + error.message, io: io) }
            1
        case Result.Ok(response) =>
            if (stream.wroteText) {
                appWriteRegistryLineChecked181("", io: io)
            } else if (response.text != "") {
                appWriteRegistryLineChecked181(response.text, io: io)
            }
            match (response.approval) {
                case Some(approval) =>
                    appWriteRegistryLineChecked181("approval required: " + approval.operationId.value, io: io)
                    3
                case None => 0
            }
    }

}

private func originalRegistryJsonProjectionFrame161(result: Result<ApplicationResponse>, session: ApplicationSession, stream: ApplicationJsonEventStream, failures: CliFailureOutput113, io!: CliIo180 = consoleCliIo180): Int64 {
    match (result) {
        case Result.Err(error) =>
            stream.finish()
            if (!failures.consumeCaller(session, error)) {
            appWriteRegistryLineChecked181(
                encodeAgentValue(
                    redactJsonAgentValue(objectValue(
                        [
                            ValueField("type", textValue("error")),
                            ValueField("code", textValue(error.code)),
                            ValueField("message", textValue(error.message))
                        ]
                    ))
                )
            , io: io)
            }
            1
        case Result.Ok(response) =>
            stream.finish()
            let fields = ArrayList<ValueField>()
            fields.add(ValueField("type", textValue("result")))
            fields.add(
                ValueField(
                    "agent_invoked",
                    boolValue(response.agentInvoked)
                )
            )
            match (response.snapshot) {
                case Some(snapshot) =>
                    fields.add(
                        ValueField(
                            "run_id",
                            textValue(snapshot.runId.value)
                        )
                    )
                    fields.add(
                        ValueField(
                            "session_id",
                            textValue(snapshot.sessionId.value)
                        )
                    )
                    fields.add(
                        ValueField(
                            "status",
                            textValue(runStatusName(snapshot.status))
                        )
                    )
                case None => ()
            }
            match (response.approval) {
                case Some(approval) =>
                    let details = approvalDetails(approval)
                    fields.add(
                        ValueField(
                            "approval",
                            objectValue(
                                [
                                    ValueField(
                                        "operation_id",
                                        textValue(details.operationId.value)
                                    ),
                                    ValueField(
                                        "tool",
                                        textValue(details.toolName)
                                    ),
                                    ValueField(
                                        "call_id",
                                        textValue(details.callId)
                                    ),
                                    ValueField(
                                        "capability",
                                        textValue(capabilityDisplayName(details.capability.kind))
                                    ),
                                    ValueField(
                                        "resource",
                                        textValue(details.capability.resource)
                                    ),
                                    ValueField(
                                        "risk",
                                        textValue(approvalRiskName(details.risk))
                                    ),
                                    ValueField(
                                        "preview",
                                        redactJsonAgentValue(details.arguments)
                                    )
                                ]
                            )
                        )
                    )
                case None => ()
            }
            appWriteRegistryLineChecked181(encodeAgentValue(redactJsonAgentValue(
                objectValue(fields.toArray())
            )), io: io)
            if (response.approval.isSome()) {
                3
            } else {
                0
            }
    }
}

// A successful formatter return also requires the actual fd write to finish.
// On a partial write or EPIPE the caller retains its same paid response.
func appWriteRegistryLineChecked181(text: String, io!: CliIo180 = consoleCliIo180): Unit {
    io.flush()
    io.println(text)
}

// The constructor consumes only the actual opaque Screen receipt. No empty
// Screen, counter, ordinary callback or headless render can mint this proof.
private class RetiredActualRegistryTuiReferences167 <: OwnedRegistryResponseRetirement161 {
    private let actual: RetiredOwnedTuiScreenReferences
    private let producer: Object
    init(actual: RetiredOwnedTuiScreenReferences, producer: Object) {
        this.actual = actual; this.producer = producer }
    public func copiedReferencesRetired(): Bool { actual.acknowledgesRegistryProducer167(producer) }
}
