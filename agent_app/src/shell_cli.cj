package agent_app
import yjson_support.*

import yjson.*


import agent_domain.*
import std.collection.*
import agent_product.*
import std.convert.*
import std.env.*
import std.fs.*

func runShellCli(product: ProductRuntime, arguments: Array<String>, io!: CliIo180 = consoleCliIo180, session180!: ?ApplicationSession = None<ApplicationSession>): Int64 {
    if(hasArgument(arguments,"--help") || hasArgument(arguments,"-h")){
        io.println("axyndra shell [--timeout <milliseconds>] [--network <denied|host|proxy>] " +
            "[--network-policy <json-file>] [--snapshot] [--command <shell-command>]\n" +
            "Select an installed native Shell in settings/plugins/shell-tools.json.\n" +
            "Interactive commands: .plugins <arguments>, .approve <operation-id>, .reject <operation-id>, .cancel, .help, .exit\n" +
            "Start the selected service separately with .plugins service start <namespace> <service-id> <route> --approve.\n" +
            "A service startup decision never approves a command. Network options only match the operator's frozen service policy.")
        return 0
    }
    match(shellArgumentError(arguments)){case Some(message)=>io.println("shell.invalid_arguments: "+message);return 2;case None=>()}
    let timeout=match(shellTimeout(argumentValue(arguments,"--timeout"))){
        case Result.Err(error)=>printError(error, io: io);return 2;case Result.Ok(value)=>value}
    let network=match(shellNetworkPolicy(arguments)){
        case Result.Err(error)=>printError(error, io: io);return 2;case Result.Ok(value)=>value}
    let session=session180 ?? product.applicationSession()
    var code: Int64=0
    try{
        let command=argumentValue(arguments,"--command")
        if(command!=""){
            code=executeShellLine(session,command,timeout,network, io: io)
            // Never run a second command while the first has retained approval.
            if(hasArgument(arguments,"--snapshot") && session.approval().isNone()){
                let _=executeShellLine(session,"printf 'cwd=%s\\n' \"$PWD\"; env | sort",timeout,network, io: io)}
        }else{
            var active=true
            while(active){
                match(io.readln()){
                    case None=>active=false
                    case Some(line)=>
                        let authored=line.trimAscii()
                        if(authored==""){continue}
                        if(authored==".exit"){active=false;continue}
                        if(authored==".help"){
                            io.println(".plugins <arguments>  manage the installed service with independent startup approval\n" +
                                ".approve <operation-id>  decide the actual retained command\n" +
                                ".reject <operation-id>  reject that actual command\n.cancel  cancel the retained command\n.exit  close")
                            continue}
                        if(authored==".cancel"){
                            match(session.abortBash()){case Result.Err(error)=>printError(error, io: io);case Result.Ok(_)=>()}
                            continue}
                        if(authored.startsWith(".plugins ") || authored.startsWith(".approve ") || authored.startsWith(".reject ")){
                            let actual=match(session.handle("/"+authored[1..])){
                                case Result.Err(error)=>printError(error, io: io);continue;case Result.Ok(value)=>value}
                            if(actual.text!=""){io.println(actual.text)}
                            match(actual.approval){case Some(value)=>printShellApproval(value, io: io);case None=>()}
                            continue}
                        let _=executeShellLine(session,authored,timeout,network, io: io)
                }
            }
        }
    }finally{
        // Product retains this exact acquired invocation until its fixed ACK.
        // A failed close never abandons charged output or authorizes a retry.
        match(session.abortBash()){case Result.Err(error)=>printError(error, io: io);code=1;case Result.Ok(_)=>()}
    }
    code
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

func printShellApproval(actual: ApprovalRequest, io!: CliIo180 = consoleCliIo180): Unit {
    io.println("shell.approval_required: "+actual.operationId.value+" "+actual.toolName)
}

func executeShellLine(session: ApplicationSession, command: String,
    timeout: Int64, networkPolicy: ?NetworkPolicy, io!: CliIo180 = consoleCliIo180): Int64 {
    match(session.executeBash(command,timeoutMillis:timeout,networkPolicy:networkPolicy)){
        case Result.Ok(result)=>
            if(result.stdout!=""){io.print(result.stdout)}
            if(result.stderr!=""){io.eprintln(result.stderr.trimAscii())}
            if(result.timedOut){io.println("shell.timeout: command exceeded "+timeout.toString()+"ms");return 124}
            result.exitCode
        case Result.Err(error)=>
            match(session.approval()){case Some(value)=>printShellApproval(value, io: io);case None=>printError(error, io: io)}
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
    if (value <= 0 || value > 600000) {
        Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "shell.invalid_timeout",
            "--timeout must be 1..600000ms within the selected operator service ceilings"
        ))
    } else {
        Result.Ok(value)
    }
}
