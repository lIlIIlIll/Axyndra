package agent_app

import agent_domain.*
import agent_product.*
import std.convert.*
import std.env.*

func runShellCli(
    product: ProductRuntime,
    arguments: Array<String>
): Int64 {
    if (hasArgument(arguments, "--help") || hasArgument(arguments, "-h")) {
        println(
            "axyndra shell [--timeout <milliseconds>] [--snapshot] " +
                "[--command <shell-command>]\n" +
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
    let sessionId = product.ids.nextSessionId()
    let command = argumentValue(arguments, "--command")
    if (command != "") {
        let code = executeShellLine(product, sessionId, command, timeout)
        if (hasArgument(arguments, "--snapshot")) {
            let _ = executeShellLine(
                product,
                sessionId,
                "printf 'cwd=%s\\n' \"$PWD\"; env | sort",
                timeout
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
                    println(".help  show commands\n.exit  close the persistent shell")
                    continue
                }
                let _ = executeShellLine(
                    product,
                    sessionId,
                    authored,
                    timeout
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
        if (argument == "--timeout" || argument == "--command") {
            expects = argument
        } else if (argument.startsWith("--timeout=") ||
            argument.startsWith("--command=")) {
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
    timeout: Int64
): Int64 {
    match (product.executePersistentShell(
        sessionId,
        command,
        timeoutMillis: timeout
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
