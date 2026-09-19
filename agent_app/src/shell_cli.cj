package agent_app
import yjson_support.*

import yjson.*


import agent_domain.*
import std.collection.*
import agent_product.*
import model_adapters.*
import std.convert.*
import std.env.*
import std.fs.*

func runShellCli(
    product: ProductRuntime,
    arguments: Array<String>
): Int64 {
    if (hasArgument(arguments, "--help") || hasArgument(arguments, "-h")) {
        println(
            "axyndra shell [--timeout <milliseconds>] [--network <denied|host|proxy>] " +
                "[--network-policy <json-file>] [--snapshot] [--command <shell-command>]\n" +
                "Interactive commands: .help, .exit"
        )
        return 0
    }
    match (shellArgumentError(arguments)) {
        case Some(message) => println("shell.invalid_arguments: " + message); return 2
        case None => ()
    }
    let timeout = match (shellTimeout(argumentValue(arguments, "--timeout"))) {
        case Result.Ok(value) => value
        case Result.Err(error) => printError(error); return 2
    }
    let networkPolicy = match (shellNetworkPolicy(arguments)) {
        case Result.Ok(value) => value
        case Result.Err(error) => printError(error); return 2
    }
    let sessionId = product.ids.nextSessionId()
    let command = argumentValue(arguments, "--command")
    if (command != "") {
        let code = executeShellLine(product, sessionId, command, timeout, networkPolicy)
        if (hasArgument(arguments, "--snapshot")) {
            let _ = executeShellLine(
                product,
                sessionId,
                "printf 'cwd=%s\\n' \"$PWD\"; env | sort",
                timeout,
                networkPolicy
            )
        }
        return code
    }
    while (true) {
        match (getStdIn().readln()) {
            case None => return 0
            case Some(line) =>
                let authored = line.trimAscii()
                if (authored == "") { continue }
                if (authored == ".exit") { return 0 }
                if (authored == ".help") {
                    println(
                        ".help  show commands\n" +
                        ".exit  close the persistent shell"
                    )
                    continue
                }
                let _ = executeShellLine(
                    product,
                    sessionId,
                    authored,
                    timeout,
                    networkPolicy
                )
        }
    }
    0
}
func shellArgumentError(arguments: Array<String>): ?String {
    var expects = ""
    for (argument in arguments) {
        if (expects != "") {
            if (argument.startsWith("-")) { return Some(expects + " requires a value") }
            expects = ""
            continue
        }
        if (argument == "--timeout" || argument == "--command" ||
            argument == "--network" || argument == "--network-policy") {
            expects = argument
        } else if (argument.startsWith("--timeout=") ||
            argument.startsWith("--command=") ||
            argument.startsWith("--network=") ||
            argument.startsWith("--network-policy=")) {
            ()
        } else if (argument == "--snapshot" || argument == "--help" ||
            argument == "-h") {
            ()
        } else {
            return Some("unexpected argument: " + argument)
        }
    }
    if (expects != "") { Some(expects + " requires a value") } else { None }
}

func executeShellLine(
    product: ProductRuntime,
    sessionId: SessionId,
    command: String,
    timeout: Int64,
    networkPolicy: ?NetworkPolicy
): Int64 {
    match (product.executePersistentShell(
        sessionId,
        command,
        timeoutMillis: timeout,
        networkPolicy: networkPolicy
    )) {
        case Result.Ok(result) =>
            if (result.stdout != "") { print(result.stdout) }
            if (result.stderr != "") { eprintln(result.stderr.trimAscii()) }
            if (result.timedOut) {
                println("shell.timeout: command exceeded " + timeout.toString() + "ms")
                return 124
            }
            result.exitCode
        case Result.Err(error) =>
            printError(error)
            1
    }
}

func shellNetworkPolicy(arguments: Array<String>): Result<?NetworkPolicy> {
    let modeText = argumentValue(arguments, "--network").trimAscii().toAsciiLower()
    let policyPath = argumentValue(arguments, "--network-policy").trimAscii()
    if (policyPath != "") {
        if (modeText != "" && modeText != "proxy") {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "shell.network_policy_invalid",
                "--network-policy requires --network proxy"
            ))
        }
        let source = try {
            String.fromUtf8(File.readFrom(policyPath))
        } catch (error: Exception) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "shell.network_policy_invalid",
                "cannot read --network-policy: " + error.message
            ))
        }
        let decoded = match (decodeAgentValue(source, maxBytes: 1048576)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "shell.network_policy_invalid",
                error.message
            ))
        }
        if (decoded.unifiedKind != ValueKind.Object) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "shell.network_policy_invalid",
                "--network-policy must contain a JSON object"
            ))
        }
        let policyValue = if (decoded.field("mode").isSome()) {
            decoded
        } else {
            let fields = ArrayList<ValueField>()
            fields.add(ValueField("mode", textValue("proxy")))
            for (field in decoded.fields) { fields.add(field) }
            objectValue(fields.toArray())
        }
        let policy = match (parseNetworkPolicy(policyValue)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (!networkPolicyModeIsMediated(policy.mode) || !policy.publish.isEmpty()) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "shell.network_policy_invalid",
                "shell network policy must be proxy mode without publish rules"
            ))
        }
        return Result.Ok(Some(policy))
    }
    if (modeText == "") { return Result.Ok(None) }
    let mode = match (networkPolicyMode(modeText)) {
        case Result.Ok(value) => value
        case Result.Err(_) => return Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "shell.network_invalid",
            "--network must be denied, host, or proxy"
        ))
    }
    Result.Ok(Some(NetworkPolicy(mode)))
}

func shellTimeout(authored: String): Result<Int64> {
    if (authored == "") { return Result.Ok(30000) }
    let value = try {
        Int64.parse(authored)
    } catch (_: Exception) {
        return Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "shell.invalid_timeout",
            "--timeout must be an integer"
        ))
    }
    if (value <= 0) {
        Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "shell.invalid_timeout",
            "--timeout must be positive"
        ))
    } else {
        Result.Ok(value)
    }
}
