package agent_app

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_core.*
import agent_app_protocol.*
import agent_cli.*
import agent_product.*
import agent_rpc.*
import agent_embed.*
import agent_tui.*
import model_adapters.*
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
        return runProductProcessBrokerWorker(rawArguments)
    }
    if (isProductProcessBrokerClient(rawArguments)) {
        return runProductProcessBrokerClient(rawArguments)
    }
    tuiStartupStage("runtime_initialization_completed")
    let cliCommandIndex = directCliCommandIndex(rawArguments)
    let cliCommand = directCliCommand(rawArguments)
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
                fixture: productConfig.fixture,
                unsafeDirectLaunchForTests: productConfig.unsafeDirectLaunchForTests,
                approvalMode: productConfig.approvalMode,
                approvalRoutingModeOverride: productConfig.approvalRoutingModeOverride,
                modelOverride: productConfig.modelOverride,
                asyncEnabled: productConfig.asyncEnabled,
                wallTimeoutMillis: productConfig.wallTimeoutMillis,
                compactionOverride: productConfig.compactionOverride,
                startupMode: ProductStartupMode.LocalMaintenance
            )
        )
    }
    if (cliCommand == "gallery") {
        return runGalleryCli(cliCommandTail(rawArguments, cliCommandIndex))
    }
    let product = match (openProduct(config: productConfig)) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            printError(error)
            return 1
    }
    tuiStartupStage("configuration_loading_completed")
    if ((rawArguments.size > 1 && rawArguments[1] == "models") || cliCommand == "models") {
        return runModelsCli(
            product.applicationSession(),
            cliCommandTail(rawArguments, cliCommandIndex)
        )
    }
    if (cliCommand == "reviewer-dry-run") {
        return runReviewerDryRun(product)
    }
    if ((rawArguments.size > 1 && rawArguments[1] == "__complete") || cliCommand == "__complete") {
        return runDynamicCompletionCli(
            product,
            cliCommandTail(rawArguments, cliCommandIndex)
        )
    }
    if ((rawArguments.size > 1 && rawArguments[1] == "token") || cliCommand == "token") {
        return runTokenCli(
            product,
            cliCommandTail(rawArguments, cliCommandIndex)
        )
    }
    if (cliCommand == "shell") {
        return runShellCli(
            product,
            cliCommandTail(rawArguments, cliCommandIndex)
        )
    }
    if (cliCommand == "mcp-server") {
        return runMcpServerCli(
            product,
            cliCommandTail(rawArguments, cliCommandIndex)
        )
    }
    if ((rawArguments.size > 1 && rawArguments[1] == "launch") || cliCommand == "launch") {
        arguments = stripCliCommand(arguments)
    } else if ((rawArguments.size > 1 && rawArguments[1] == "acp") || cliCommand == "acp") {
        arguments = stripCliCommand(arguments)
    } else if (cliCommand != "") {
        printError(
            unavailableCliCommand(
                cliCommand,
                cliCommandTail(rawArguments, cliCommandIndex)
            )
        )
        return 1
    }
    if (mode == "rpc" || mode == "rpc-ui") {
        return serveRpc(product, false)
    }
    if (mode == "acp") {
        return serveAcp(product, productConfig)
    }
    if (mode == "json") {
        var prompt = joinArguments(arguments, 1)
        if (prompt == "") {
            prompt = readStdinPrompt()
        }
        return runJsonStream(product, prompt)
    }
    if (hasArgument(rawArguments, "--print") || hasArgument(rawArguments, "-p") || mode == "text") {
        var prompt = joinArguments(arguments, 1)
        if (prompt == "") {
            prompt = readStdinPrompt()
        }
        if (prompt == "") {
            return 0
        }
        return runPrint(product, prompt)
    }
    runAgentTui(
        ProductTuiBackend(product),
        title: "axyndra",
        initialPrompt: joinArguments(arguments, 1)
    )
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
    for (value in [
        "read", "config", "grep", "agents", "worktree", "search",
        "gc", "usage", "stats", "grievances", "ssh"
    ] where value == candidate) {
        return candidate
    }
    ""
}

func runLocalMaintenanceCommand(
    command: String,
    arguments: Array<String>,
    config: ProductConfig
): Int64 {
    let product = match (openProduct(config: config)) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            printError(error)
            return 1
    }
    tuiStartupStage("configuration_loading_completed")
    let session = product.applicationSession()
    let status = match (command) {
        case "read" => runReadCli(session, arguments)
        case "config" => runConfigCli(session, arguments)
        case "grep" => runGrepCli(session, arguments)
        case "agents" => runAgentsCli(session, arguments)
        case "worktree" => runWorktreeCli(session, arguments)
        case "search" => runSearchCli(session, arguments)
        case "gc" => runGcCli(session, arguments)
        case "usage" => runUsageCli(session, arguments)
        case "stats" => runStatsCli(session, arguments)
        case "grievances" => runGrievancesCli(session, arguments)
        case "ssh" => runSshCli(session, arguments)
        case _ => 2
    }
    match (product.close()) {
        case Result.Ok(_) => status
        case Result.Err(error) =>
            printError(error)
            1
    }
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
    for (argument in arguments where argument == expected) {
        return true
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
            candidate == "--max-time") {
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
): Int64 {
    if (hasArgument(arguments, "--help") || hasArgument(arguments, "-h")) {
        println("axyndra models [ls|find <substring>|refresh|<provider>] " + "[--json]")
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
        println("`axyndra models find` requires a search substring, " + "e.g. `axyndra models find deepseek`")
        return 1
    }
    if (action == "refresh") {
        println("Error: model catalog refresh requires the OMP-compatible " + "catalog service, which is not installed.")
        return 1
    }
    let models = filteredModels(session, pattern, action == "find")
    if (json) {
        let values = ArrayList<AgentValue>()
        for (model in models) {
            values.add(cliModelValue(session, model))
        }
        println(encodeAgentValue(objectValue([ValueField("models", listValue(values.toArray()))])))
        return 0
    }
    if (session.models().isEmpty()) {
        println("No models available. Set API keys in environment variables.")
        return 0
    }
    if (models.isEmpty()) {
        println("No models matching \"" + pattern + "\"")
        return 0
    }
    var activeProvider = ""
    var providerCount: Int64 = 0
    for (model in models) {
        let provider = session.modelProvider(model)
        if (provider != activeProvider) {
            if (activeProvider != "") {
                println()
            }
            activeProvider = provider
            providerCount = countProviderModels(session, models, provider)
            println(provider + " (" + providerCount.toString() + ")")
            println("model")
        }
        println(session.rawModelId(model))
    }
    0
}

func runReadCli(
    session: ApplicationSession,
    arguments: Array<String>
): Int64 {
    if (hasArgument(arguments, "--help") || hasArgument(arguments, "-h")) {
        println("axyndra read <path>")
        return 0
    }
    let positional = cliPositionals(arguments, [])
    if (positional.size != 1) {
        println("error: path is required")
        return 1
    }
    match (session.invokeLocalTool(
        "read",
        objectValue([ValueField("path", textValue(positional[0]))])
    )) {
        case Result.Err(error) =>
            printError(error)
            1
        case Result.Ok(result) =>
            let output = match (result.output.field("content")) {
                case Some(value) => value.text
                case None => match (result.output.field("entries")) {
                    case Some(value) => value.text
                    case None => encodeAgentValue(result.output)
                }
            }
            print(output)
            if (!output.endsWith("\n")) {
                println()
            }
            0
    }
}

func runConfigCli(
    session: ApplicationSession,
    arguments: Array<String>
): Int64 {
    if (hasArgument(arguments, "--help") || hasArgument(arguments, "-h")) {
        println("axyndra config [list|get|set|reset|path] [key] [value] " + "[--json]")
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
        println(session.configRoot() + "/config.yml")
        return 0
    }
    let settings = match (loadProductSettings(session.configRoot())) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            printError(error)
            return 1
    }
    if (action == "list") {
        if (json) {
            println(
                encodeAgentValue(
                    objectValue(
                        [
                            ValueField(
                                "default_model",
                                textValue(settings.model)
                            ),
                            ValueField(
                                "async.enabled",
                                boolValue(settings.asyncEnabled)
                            )
                        ]
                    )
                )
            )
        } else {
            println("Settings:")
            println("  default_model = " + if (settings.model == "") {
                "(not set)"
            } else {
                settings.model
            })
            println("  async.enabled = " + settings.asyncEnabled.toString())
        }
        return 0
    }
    if (action == "get") {
        if (positional.size < 2) {
            println("Usage: axyndra config get <key>")
            return 1
        }
        return printConfigValue(
            settings,
            positional[1],
            json
        )
    }
    if (action == "set") {
        if (positional.size < 3) {
            println("Usage: axyndra config set <key> <value>")
            return 1
        }
        let value = joinArguments(positional, 2)
        let edits = ArrayList<ProductConfigEdit>()
        match (positional[1]) {
            case "default_model" =>
                if (value.trimAscii() == "") {
                    println("default_model must not be empty")
                    return 1
                }
                edits.add(ProductConfigEdit(
                    "default_model",
                    ProductConfigScalar.Text(value.trimAscii())
                ))
            case "async.enabled" =>
                let parsed = parseCliBool(value)
                if (parsed.isNone()) {
                    println("Invalid boolean value: " + value + ". Use true/false, yes/no, on/off, or 1/0")
                    return 1
                }
                edits.add(ProductConfigEdit(
                    "async.enabled",
                    ProductConfigScalar.Boolean(parsed.getOrThrow())
                ))
            case key =>
                println("Unknown setting: " + key)
                return 1
        }
        return saveCliSettings(
            session.configRoot(),
            edits.toArray(),
            json,
            positional[1]
        )
    }
    if (action == "reset") {
        let key = if (positional.size > 1) {
            positional[1]
        } else {
            ""
        }
        if (key != "" && key != "default_model" && key != "async.enabled") {
            println("Unknown setting: " + key)
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
        return saveCliSettings(
            session.configRoot(),
            edits.toArray(),
            json,
            key
        )
    }
    println("Unknown config command: " + action + "\nValid commands: list, get, set, reset, path")
    1
}

func printConfigValue(
    settings: ProductSettings,
    key: String,
    json: Bool
): Int64 {
    let value: AgentValue
    match (key) {
        case "default_model" => value = textValue(settings.model)
        case "async.enabled" => value = boolValue(settings.asyncEnabled)
        case _ =>
            println("Unknown setting: " + key)
            return 1
    }
    if (json) {
        println(
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
            case ValueKind.Text => println(value.text)
            case ValueKind.Boolean => println(value.boolean.toString())
            case _ => println(encodeAgentValue(value))
        }
    }
    0
}

func saveCliSettings(
    root: String,
    edits: Array<ProductConfigEdit>,
    json: Bool,
    key: String
): Int64 {
    let path = root + "/config.yml"
    match (updateProductConfig(root, edits)) {
        case Result.Ok(_) => ()
        case Result.Err(error) =>
            printError(error)
            return 1
    }
    if (json) {
        println(
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
        println("Updated " + path)
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

func runGrepCli(
    session: ApplicationSession,
    arguments: Array<String>
): Int64 {
    if (hasArgument(arguments, "--help") || hasArgument(arguments, "-h")) {
        println(
            "axyndra grep <pattern> [path] " + "[-g|--glob <pattern>] [-l|--limit <n>] " +
                "[-C|--context <n>] [-f|--files] [-c|--count] " + "[--no-gitignore]")
        return 0
    }
    var glob = ""
    var limit: Int64 = 20
    var contextLines: Int64 = 2
    var mode = "content"
    var gitignore = true
    let positional = ArrayList<String>()
    var index: Int64 = 0
    while (index < arguments.size) {
        let argument = arguments[index]
        if (argument == "--glob" || argument == "-g" || argument == "--limit" || argument == "-l" || argument ==
            "--context" || argument == "-C" || argument == "--approval-mode" || argument == "--mode" || argument ==
            "--model" || argument == "--cwd" || argument == "--max-time") {
            if (index + 1 >= arguments.size) {
                println("Error: missing value for flag: " + argument)
                return 1
            }
            let value = arguments[index + 1]
            if (argument == "--glob" || argument == "-g") {
                glob = value
            } else if (argument == "--limit" || argument == "-l") {
                limit = parseCliInteger(value, -1)
            } else if (argument == "--context" || argument == "-C") {
                contextLines = parseCliInteger(value, -1)
            }
            index += 2
            continue
        }
        if (argument == "--files" || argument == "-f") {
            mode = "files"
        } else if (argument == "--count" || argument == "-c") {
            mode = "count"
        } else if (argument == "--no-gitignore") {
            gitignore = false
        } else if (argument == "--fixture" ||
            argument.startsWith("--approval-mode=") || argument.startsWith("--mode=") || argument.startsWith("--model=") ||
            argument.startsWith("--cwd=")) {
            ()
        } else if (argument.startsWith("-")) {
            println("Error: unknown grep flag: " + argument)
            return 1
        } else {
            positional.add(argument)
        }
        index += 1
    }
    if (positional.isEmpty() || positional[0] == "") {
        println("Error: Pattern is required")
        return 1
    }
    if (limit < 1) {
        println("Error: limit must be a positive integer")
        return 1
    }
    if (contextLines < 0) {
        println("Error: context must not be negative")
        return 1
    }
    let path = if (positional.size > 1) {
        positional[1]
    } else {
        "."
    }
    let resolved = match (LocalWorkspace(session.workspaceRoot()).resolve(path, allowDirectory: true)) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            printError(error)
            return 1
    }
    let common = ArrayList<String>()
    common.add("--color")
    common.add("never")
    common.add("--sort")
    common.add("path")
    common.add("--hidden")
    common.add("--glob")
    common.add("!.git/**")
    if (!gitignore) {
        common.add("--no-ignore")
    }
    if (glob != "") {
        common.add("--glob")
        common.add(glob)
    }
    let countArguments = ArrayList<String>(common)
    countArguments.add("--count-matches")
    countArguments.add("--no-heading")
    countArguments.add("--with-filename")
    countArguments.add("--")
    countArguments.add(positional[0])
    countArguments.add(resolved)
    let countResult = executeWithOutput(
        "rg",
        countArguments.toArray(),
        workingDirectory: Path(session.workspaceRoot())
    )
    if (countResult[0] != 0 && countResult[0] != 1) {
        println("Error: " + String.fromUtf8(countResult[2]).trimAscii())
        return 1
    }
    let counts = grepCounts(String.fromUtf8(countResult[1]))
    let filesSearched = grepFilesSearched(
        resolved,
        glob,
        gitignore,
        session.workspaceRoot()
    )
    let outputArguments = ArrayList<String>(common)
    match (mode) {
        case "files" => outputArguments.add("--files-with-matches")
        case "count" =>
            outputArguments.add("--count-matches")
            outputArguments.add("--with-filename")
        case _ =>
            outputArguments.add("--line-number")
            outputArguments.add("--no-heading")
            outputArguments.add("--with-filename")
            if (contextLines > 0) {
                outputArguments.add("--context")
                outputArguments.add(contextLines.toString())
            }
    }
    outputArguments.add("--")
    outputArguments.add(positional[0])
    outputArguments.add(resolved)
    let outputResult = executeWithOutput(
        "rg",
        outputArguments.toArray(),
        workingDirectory: Path(session.workspaceRoot())
    )
    if (outputResult[0] != 0 && outputResult[0] != 1) {
        println("Error: " + String.fromUtf8(outputResult[2]).trimAscii())
        return 1
    }
    println("Searching in: " + resolved)
    println("Pattern: " + positional[0])
    println(
        "Mode: " + mode + ", Limit: " + limit.toString() + ", Context: " + contextLines.toString() + ", Gitignore: " +
            gitignore.toString())
    println()
    println("Total matches: " + counts[0].toString())
    println("Files with matches: " + counts[1].toString())
    println("Files searched: " + filesSearched.toString())
    let renderedOutput = if (mode == "count") {
        formatGrepCountOutput(String.fromUtf8(outputResult[1]))
    } else {
        String.fromUtf8(outputResult[1])
    }
    let output = limitGrepOutput(
        renderedOutput,
        limit
    )
    if (output[1]) {
        println("Limit reached: true")
    }
    println()
    if (output[0] != "") {
        println(output[0])
    }
    0
}

func parseCliInteger(value: String, fallback: Int64): Int64 {
    try {
        Int64.parse(value)
    } catch (_: Exception) {
        fallback
    }
}

func grepCounts(source: String): (Int64, Int64) {
    var matches: Int64 = 0
    var files: Int64 = 0
    for (line in source.split("\n") where line != "") {
        let separator = line.lastIndexOf(":")
        match (separator) {
            case Some(value) =>
                let count = parseCliInteger(line[value + 1..], 0)
                matches += count
                files += 1
            case None => ()
        }
    }
    (matches, files)
}

func grepFilesSearched(
    resolved: String,
    glob: String,
    gitignore: Bool,
    workspaceRoot: String
): Int64 {
    if (!FileInfo(resolved).isDirectory()) {
        return 1
    }
    let arguments = ArrayList<String>()
    arguments.add("--files")
    arguments.add("--hidden")
    arguments.add("--sort")
    arguments.add("path")
    arguments.add("--glob")
    arguments.add("!.git/**")
    if (!gitignore) {
        arguments.add("--no-ignore")
    }
    if (glob != "") {
        arguments.add("--glob")
        arguments.add(glob)
    }
    arguments.add(resolved)
    let (code, output, _) = executeWithOutput(
        "rg",
        arguments.toArray(),
        workingDirectory: Path(workspaceRoot)
    )
    if (code != 0 && code != 1) {
        return 0
    }
    var count: Int64 = 0
    for (line in String.fromUtf8(output).split("\n") where line != "") {
        count += 1
    }
    count
}

func limitGrepOutput(
    source: String,
    limit: Int64
): (String, Bool) {
    let lines = source.split("\n")
    let selected = ArrayList<String>()
    var available: Int64 = 0
    for (line in lines where line != "" && line != "--") {
        available += 1
        if (selected.size < limit) {
            selected.add(line)
        }
    }
    (joinCliLines(selected.toArray()), available > limit)
}

func formatGrepCountOutput(source: String): String {
    let lines = ArrayList<String>()
    for (line in source.split("\n") where line != "") {
        let separator = line.lastIndexOf(":")
        match (separator) {
            case Some(value) => lines.add(line[..value] + ": " + line[value + 1..] + " matches")
            case None => lines.add(line)
        }
    }
    joinCliLines(lines.toArray())
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
): Int64 {
    if (arguments.isEmpty() || hasArgument(arguments, "--help") || hasArgument(arguments, "-h")) {
        println("axyndra agents unpack [--force] [--json] " + "[--dir <path>|--user|--project]")
        return 0
    }
    if (arguments[0] != "unpack") {
        println("Unknown agents action: " + arguments[0])
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
                println("Error: --dir requires a path")
                return 1
            }
            authoredDirectory = arguments[index + 1]
            index += 1
        } else if (argument == "--fixture") {
            ()
        } else {
            println("Error: unknown agents flag: " + argument)
            return 1
        }
        index += 1
    }
    if (user && project) {
        println("Choose either --user or --project, not both.")
        return 1
    }
    if (authoredDirectory != "" && (user || project)) {
        println("--dir cannot be combined with --user or --project.")
        return 1
    }
    let target = if (authoredDirectory != "") {
        match (LocalWorkspace(session.workspaceRoot()).resolve(
            authoredDirectory,
            allowDirectory: true
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                printError(error)
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
            println("error: agent target is not a directory: " + target)
            return 1
        }
    } catch (error: Exception) {
        println("error: cannot create agent directory: " + error.message)
        return 1
    }
    let written = ArrayList<String>()
    let skipped = ArrayList<String>()
    for (agent in session.bundledAgents()) {
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
            println("error: cannot write agent " + agent.name + ": " + error.message)
            return 1
        }
    }
    if (json) {
        println(
            encodeAgentValue(
                objectValue(
                    [
                        ValueField("targetDir", textValue(target)),
                        ValueField(
                            "total",
                            integerValue(session.bundledAgents().size)
                        ),
                        ValueField("written", cliStringList(written.toArray())),
                        ValueField("skipped", cliStringList(skipped.toArray()))
                    ]
                )
            )
        )
    } else {
        println("Bundled agents: " + session.bundledAgents().size.toString())
        println("Target directory: " + target)
        println("Written: " + written.size.toString())
        if (!skipped.isEmpty()) {
            println("Skipped existing: " + skipped.size.toString() + " (use --force to overwrite)")
        }
        for (path in written) {
            println("  + " + path)
        }
        for (path in skipped) {
            println("  = " + path)
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
    for (argument in arguments) {
        if (skipNext) {
            skipNext = false
            continue
        }
        if (argument == "--approval-mode" || argument == "--mode" || argument == "--model" || argument == "--cwd" ||
            argument == "--max-time") {
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
    let content = "default_model: " + yamlQuote(configuredModel) + "\n"
    let target = root + "/config.yml"
    let temporary = target + ".tmp"
    try {
        File.writeTo(temporary, content.toArray())
        rename(temporary, to: target, overwrite: true)
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
        let _ = removeIfExists(temporary)
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
    for (argument in arguments where argument == expected) {
        return true
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
        "--model-stream-fault-profile"
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
            if (index + 1 >= arguments.size) {
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
    if (fault != "" && fault != "incomplete-text-attempt-1-v1") {
        return Some("invalid --model-stream-fault-profile: " + fault)
    }
    None
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
            argument == "--model-stream-fault-profile") {
            skipNext = true
            continue
        }
        if (argument == "--fixture" || argument == "--print" ||
            argument == "-p" || argument == "--help" || argument == "-h" || argument == "--version" || argument == "-v" ||
            argument.startsWith("--approval-mode=") || argument.startsWith("--mode=") || argument.startsWith("--model=") ||
            argument.startsWith("--cwd=") || argument.startsWith("--max-time=") ||
            argument.startsWith("--model-attempt-recovery=") ||
            argument.startsWith("--model-stream-idle-timeout-ms=") ||
            argument.startsWith("--model-stream-fault-profile=")) {
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
        case _ => throw IllegalArgumentException("invalid model stream fault profile")
    }
}

func argumentValue(arguments: Array<String>, name: String): String {
    var expectValue = false
    for (argument in arguments) {
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

func serveRpc(product: ProductRuntime, once: Bool): Int64 {
    let output = RpcOutput()
    let session = product.applicationSession()
    let server = ProductJsonlRpcServer(
        session,
        {frame => output.write(frame)}
    )
    match (session.resumeStartup()) {
        case Result.Ok(_) => ()
        case Result.Err(error) =>
            printError(error)
            return 1
    }
    output.write(server.ready())
    while (true) {
        let line = match (getStdIn().readln()) {
            case Some(value) => value
            case None => return 0
        }
        let response = server.handle(line)
        if (response != "") {
            output.write(response)
        }
        if (once) {
            return 0
        }
    }
    0
}

func serveAcp(
    product: ProductRuntime,
    config: ProductConfig
): Int64 {
    let output = RpcOutput()
    let server = ProductAcpServer(
        product,
        {
            cwd => openProduct(
                config: acpSessionProductConfig(config, cwd)
            )
        },
        {frame => output.write(frame)}
    )
    atExit({ =>
        let _ = server.close()
    })
    var status: Int64 = 0
    try {
        while (true) {
            let line = match (getStdIn().readln()) {
                case Some(value) => value
                case None => break
            }
            let response = server.handle(line)
            if (response != "") {
                output.write(response)
            }
            server.flushDeferred()
        }
    } catch (error: Exception) {
        eprintln("acp.server_failed: " + error.message)
        status = 1
    }
    match (server.close()) {
        case Result.Ok(_) => status
        case Result.Err(error) =>
            printError(error)
            1
    }
}

func acpSessionProductConfig(
    config: ProductConfig,
    workspaceRoot: String
): ProductConfig {
    ProductConfig(
        settingsRoot: config.settingsRoot,
        stateRoot: config.stateRoot,
        workspaceRoot: workspaceRoot,
        fixture: config.fixture,
        approvalMode: config.approvalMode,
        approvalRoutingModeOverride: config.approvalRoutingModeOverride,
        modelOverride: config.modelOverride,
        asyncEnabled: config.asyncEnabled,
        wallTimeoutMillis: config.wallTimeoutMillis,
        startupMode: config.startupMode
    )
}

class RpcOutput {
    private let lock = Mutex()

    func write(frame: String): Unit {
        lock.lock()
        try {
            println(frame)
            getStdOut().flush()
        } finally {
            lock.unlock()
        }
    }
}

func runPrint(product: ProductRuntime, prompt: String): Int64 {
    let session = product.applicationSession()
    let stream = StreamState()
    session.subscribe({
        event => match (event.payload) {
            case AgentEventPayload.TextDelta(text) => if (text != "") {
                    print(text)
                    stream.wroteText = true
                }
            case AgentEventPayload.Extension(_, detail) =>
                if (extensionCode(detail) == "model.text_delta") {
                    let text = eventText(event, "text")
                    if (text != "") {
                        print(text)
                        stream.wroteText = true
                    }
                }
            case _ => ()
        }
    })
    match (session.resumeStartup()) {
        case Result.Err(error) =>
            if (stream.wroteText) { println() }
            printError(error)
            return 1
        case Result.Ok(Some(response)) => match (response.approval) {
            case Some(approval) =>
                if (stream.wroteText) { println() }
                println("approval required: " + approval.operationId.value)
                return 3
            case None => ()
        }
        case Result.Ok(None) => ()
    }
    match (session.handle(prompt)) {
        case Result.Err(error) =>
            if (stream.wroteText) {
                println()
            }
            printError(error)
            1
        case Result.Ok(response) =>
            if (stream.wroteText) {
                println()
            } else if (response.text != "") {
                println(response.text)
            }
            match (response.approval) {
                case Some(approval) =>
                    println("approval required: " + approval.operationId.value)
                    3
                case None => 0
            }
    }
}

func runJsonStream(product: ProductRuntime, prompt: String): Int64 {
    let session = product.applicationSession()
    println(
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
        println(encodeAgentValue(applicationJsonEventValue(event)))
    })
    session.subscribe({ event => stream.accept(event) })
    match (session.resumeStartup()) {
        case Result.Err(error) =>
            stream.finish()
            printError(error)
            return 1
        case Result.Ok(Some(_)) => if (prompt == "") {
            stream.finish()
            return 0
        }
        case Result.Ok(None) => ()
    }
    if (prompt == "") { return 0 }
    match (session.handle(prompt)) {
        case Result.Err(error) =>
            stream.finish()
            println(
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
            println(encodeAgentValue(redactJsonAgentValue(
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
    private let text = ApplicationJsonDeltaStream()
    private let reasoning = ApplicationJsonDeltaStream()
    private let tools = ArrayList<ApplicationJsonToolStream>()

    init(output: AgentEventSink) {
        this.output = output
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

class ProductTuiBackend <: AgentTuiBackend {
    private let session: ApplicationSession
    private let product: ProductRuntime
    private let branchLabel: String
    private let lock = Mutex()
    private var running = false
    private let uiRunEvents = TuiRunEventCursor()
    private let appEvents: AppEventCursor
    private var appCommandSequence: Int64 = 0
    private var sink: ?TuiAgentEventSink = None
    private var observerSink: ?TuiAgentEventSink = None
    private var focusedSubagentId = ""
    private var pendingSubagentApproval: ?TuiPendingSubagentApproval = None
    private let queuedSubagentApprovals = ArrayList<TuiPendingSubagentApproval>()

    init(product: ProductRuntime, applicationSession!: ?ApplicationSession = None) {
        this.product = product
        this.session = match (applicationSession) {
            case Some(value) => value
            case None => product.applicationSession()
        }
        this.appEvents = AppEventCursor(ThreadId(this.session.id().value))
        this.branchLabel = workspaceBranch(session.workspaceRoot())
        session.subscribe({event => forward(event)})
        session.subscribeAsyncJobs({event => forwardJob(event)})
        session.subscribeSubagents({event => forwardSubagent(event)})
        session.setAskInteractive(true)
        session.subscribeAsks({request => forwardAsk(request)})
        let _ = session.resumeStartup()
    }

    public func observe(events: TuiAgentEventSink): Unit {
        lock.lock()
        try {
            observerSink = Some(events)
        } finally {
            lock.unlock()
        }
    }

    public func welcome(): Array<TuiAgentEvent> {
        if (session.model() == "unconfigured") {
            [TuiAgentEvent.Setup(
                "Run `axyndra setup`, or create " + defaultProductHome() + "/config.yml, models.yml, and providers.yml; " +
                    "then restart axyndra. Fixture mode is never selected " + "implicitly.")]
        } else {
            []
        }
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
        var result = session.handle(prompt)
        while (true) {
            match (session.takeQueuedAtSafeBoundary(result)) {
                case Some(next) => result = session.handle(next.input)
                case None => break
            }
        }
        emitTurnError(result, events)
        emitApproval(result)
        finish()
        tuiResult(result, prompt)
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
                emitTurnError(result, events)
                emitApproval(result)
                finish()
                emitPendingSubagentApproval(events)
                // A failed decision is terminal for that approval attempt.
                // ApplicationSession clears it; do not defensively replay a
                // stale request from a failed run back into the TUI.
                match (result) {
                    case Result.Ok(_) => emitCurrentMainApproval(events)
                    case Result.Err(_) => ()
                }
                tuiResult(result, "")
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
        emitTurnError(result, events)
        emitApproval(result)
        finish()
        let tui = tuiResult(result, "")
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

    public func cancel(): Unit {
        let focused = focusedSubagent()
        if (focused == "") {
            let _ = session.cancel()
        } else {
            let _ = session.cancelSubagent(focused)
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

    public func extensions(): Array<TuiExtensionInfo> {
        let values = ArrayList<TuiExtensionInfo>()
        for (extension in session.extensions()) {
            values.add(
                TuiExtensionInfo(
                    extension.id,
                    extension.source,
                    extension.enabled,
                    extension.tools
                )
            )
        }
        values.toArray()
    }

    public func setExtensionEnabled(
        id: String,
        enabled: Bool
    ): Bool {
        session.setExtensionEnabled(id, enabled).isOk()
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

    public func saveTodoMarkdown(markdown: String): TuiTodoSaveResult {
        match (session.replaceTodoMarkdown(markdown)) {
            case Result.Ok(message) => TuiTodoSaveResult(true, message)
            case Result.Err(error) => TuiTodoSaveResult(
                false,
                "todo parse error: " + error.message
            )
        }
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
        let target = currentSink()
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
                            callId: request.callId
                        )
                    )
                )
            case None => ()
        }
    }

    private func forwardJob(event: ProductAsyncJobEvent): Unit {
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
    if (value == "/extensions") {
        return Some("Extensions")
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
            Int64.parse(value.number)
        } catch (_: Exception) {
            0
        }
        case None => 0
    }
}

func eventBoolean(event: AgentEvent, name: String): Bool {
    match (event.detail.field(name)) {
        case Some(value) => value.unifiedKind == ValueKind.Boolean && value.boolean
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

func printError(error: AgentError): Unit {
    println("error[" + error.code + "]: " + error.message)
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
