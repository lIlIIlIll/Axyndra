package agent_minimal

import agent_plugin_registry.*
import agent_extension_runtime.*
import agent_history.*
import agent_domain.*
import tool_runtime.*
import agent_store.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.convert.*
import std.env.*

func minimalError(code: String, message: String): Int64 {
    println(stringifyUnifiedJson(objectValue([
        ValueField("ok", boolValue(false)), ValueField("code", textValue(code)),
        ValueField("message", textValue(message))])))
    2
}

func minimalScope(value: String): PluginInstallScope {
    match (value) {
        case "user" => PluginInstallScope.User
        case "workspace" => PluginInstallScope.Workspace
        case _ => throw IllegalArgumentException("scope must be user or workspace")
    }
}

func minimalPlugins(settings: String, workspace: String, args: Array<String>): Int64 {
    if (settings == "" || workspace == "") {
        return minimalError("minimal.paths_required", "plugin management requires explicit --settings-root and --workspace-root")
    }
    let registry = PluginRegistry(settings, workspace)
    try {
    if (args.size == 1 && args[0] == "list") {
        return minimalRegistryRecords86(registry.list())
    }
    if (args.size == 1 && args[0] == "doctor") {
        return minimalRegistryDiagnostics86(registry.doctor())
    }
    if (args.size == 1 && args[0] == "gc") {
        match (registry.garbageCollect()) {
            case PluginRegistryResult.Err(error) => return minimalRegistryError86(error)
            case PluginRegistryResult.Ok(paths) => return minimalRegistryDeleted86(paths)
        }
    }
    if (args.size == 2 && args[0] == "inspect") {
        match (registry.inspect(args[1])) {
            case PluginRegistryResult.Err(error) => return minimalRegistryError86(error)
            case PluginRegistryResult.Ok(value) => return minimalRegistryDescriptor86(value)
        }
    }
    if (args.size == 3 && args[0] == "install") {
        return minimalRegistryRecordResult86(registry.importLocal(args[1], minimalScope(args[2])))
    }
    if (args.size == 4 && args[0] == "update") {
        return minimalRegistryRecordResult86(registry.updateLocal(args[1], args[2], minimalScope(args[3])))
    }
    if (args.size == 3 && args[0] == "rollback") {
        return minimalRegistryRecordResult86(registry.rollback(args[1], minimalScope(args[2])))
    }
    if (args.size == 3 && (args[0] == "enable" || args[0] == "disable")) {
        return minimalRegistryRecordResult86(registry.setEnabled(args[1], args[0] == "enable", minimalScope(args[2])))
    }
    if (args.size == 3 && args[0] == "uninstall") {
        match (registry.uninstall(args[1], minimalScope(args[2]))) {
            case PluginRegistryResult.Err(error) => return minimalRegistryError86(error)
            case PluginRegistryResult.Ok(_) => println("{\"ok\":true}"); return 0
        }
    }
    minimalError("minimal.command_invalid", "unsupported plugin command or wrong argument count; see --help")
    } finally { registry.close() }
}

func minimalHistory(args: Array<String>): Int64 {
    if (args.size < 3 || args.size > 6 || (args[0] != "latest" && args[0] != "inspect")) {
        return minimalError("minimal.command_invalid", "history latest <database> <thread>; history inspect <database> <thread> <run> [before] [limit]")
    }
    if ((args[0] == "latest" && args.size != 3) || (args[0] == "inspect" && args.size < 4)) {
        return minimalError("minimal.command_invalid", "history command has wrong argument count")
    }
    let database = SqliteDatabase(args[1], readOnly: true)
    try {
        let projection = RunInspectionProjection(database)
        if (args[0] == "latest") {
            match (projection.latestRunId(ThreadId(args[2]))) {
                case Result.Err(error) => return minimalError(error.code, error.message)
                case Result.Ok(run) => println(stringifyUnifiedJson(objectValue([
                    ValueField("ok", boolValue(true)), ValueField("run_id", textValue(run.value))]))); return 0
            }
        }
        let before = if (args.size >= 5) { Int64.parse(args[4]) } else { 0 }
        let limit = if (args.size >= 6) { Int64.parse(args[5]) } else { 25 }
        match (projection.inspect(ThreadId(args[2]), RunId(args[3]), before, limit)) {
            case Result.Err(error) => minimalError(error.code, error.message)
            case Result.Ok(value) => println(stringifyUnifiedJson(objectValue([
                ValueField("ok", boolValue(true)), ValueField("inspection", runInspectionValue(value))]))); 0
        }
    } finally { database.close() }
}

func minimalHelp(): Unit {
    println("axyndra-minimal: shared plugin host, canonical tool runtime and durable history")
    println("  --settings-root <path> --workspace-root <path> plugin list|doctor|gc")
    println("  --settings-root <path> --workspace-root <path> plugin inspect <package>")
    println("  --settings-root <path> --workspace-root <path> plugin install <package> user|workspace")
    println("  --settings-root <path> --workspace-root <path> plugin update <id> <package> user|workspace")
    println("  --settings-root <path> --workspace-root <path> plugin enable|disable|rollback|uninstall <id> user|workspace")
    println("  --settings-root <path> --workspace-root <path> --state-root <path> tools <thread>")
    println("  --settings-root <path> --workspace-root <path> --state-root <path> invoke <thread> <tool> <arguments-json>")
    println("  --settings-root <path> --workspace-root <path> --state-root <path> infer <thread> <namespace> <contribution> <mapped-model> <prompt>")
    println("  --settings-root <path> --workspace-root <path> --state-root <path> service <thread> <namespace> <service-id> <route> approve|deny <actions-json>")
    println("  --settings-root <path> --workspace-root <path> --state-root <path> serve <operator-grant-id> [service-starts-json]")
    println("  Service actions: tools/invoke use an explicit Thread; refresh requires approve|deny; status/stop use the retained service.")
    println("  Serve uses operator plugins/ingress.json; optional bounded client starts require explicit operator decisions.")
    println("  Runtime options: --grant <capability[:resource]> (repeatable), --approval-mode always-ask|write|yolo")
    println("                   --timeout-ms <1..120000>, --max-tool-calls <1..32>, --ca-bundle <operator-file>; tools execute serially")
    println("  history latest <database> <thread>")
    println("  history inspect <database> <thread> <run> [before-cursor] [limit:1..100]")
    println("Install records packages disabled; enable records operator intent without executing package code.")
}

main(): Int64 {
    let args = getCommandLine()
    try {
        if (args.size == 1 || (args.size == 2 && (args[1] == "--help" || args[1] == "-h"))) { minimalHelp(); return 0 }
        if (args.size == 2 && args[1] == "--version") { println("axyndra-minimal 1.0.0"); return 0 }
        var settings = ""; var workspace = ""; var state = ""; var caBundle = ""; var caBundleSet = false; var offset: Int64 = 1
        let grants = ArrayList<Capability>()
        var approval = ApprovalMode.AlwaysAsk; var approvalSet = false
        var timeout: Int64 = 60000; var timeoutSet = false
        var maxCalls: Int64 = 32; var maxCallsSet = false
        while (offset < args.size && args[offset].startsWith("--")) {
            if (offset + 1 >= args.size) { return minimalError("minimal.option_invalid", "option needs a value") }
            match (args[offset]) {
                case "--settings-root" => if (settings != "") { return minimalError("minimal.option_invalid", "duplicate settings root") }; settings = args[offset + 1]
                case "--workspace-root" => if (workspace != "") { return minimalError("minimal.option_invalid", "duplicate workspace root") }; workspace = args[offset + 1]
                case "--state-root" => if (state != "") { return minimalError("minimal.option_invalid", "duplicate state root") }; state = args[offset + 1]
                case "--ca-bundle" => if (caBundleSet) { return minimalError("minimal.option_invalid", "duplicate CA bundle") }; caBundle = args[offset + 1]; caBundleSet = true
                case "--grant" => grants.add(minimalOperatorCapability(args[offset + 1]))
                case "--approval-mode" => if (approvalSet) { return minimalError("minimal.option_invalid", "duplicate approval mode") }; approval = minimalApprovalMode(args[offset + 1]); approvalSet = true
                case "--timeout-ms" => if (timeoutSet) { return minimalError("minimal.option_invalid", "duplicate timeout") }; timeout = Int64.parse(args[offset + 1]); timeoutSet = true
                case "--max-tool-calls" => if (maxCallsSet) { return minimalError("minimal.option_invalid", "duplicate tool-call limit") }; maxCalls = Int64.parse(args[offset + 1]); maxCallsSet = true
                case _ => return minimalError("minimal.option_invalid", "unsupported option")
            }
            offset += 2
        }
        if (offset >= args.size) { return minimalError("minimal.command_invalid", "command required") }
        let tail = args[offset + 1..]
        match (args[offset]) {
            case "plugin" => minimalPlugins(settings, workspace, tail)
            case "history" => minimalHistory(tail)
            case "tools" | "invoke" | "infer" | "service" | "serve" =>
                match (validateMinimalRuntimeCommandArguments(args[offset], tail)) {
                    case Result.Err(error) => return minimalError(error.code, error.message)
                    case Result.Ok(_) => () }
                if (state == "") { return minimalError("minimal.paths_required", "runtime requires explicit --state-root") }
                minimalRuntimeCommand(settings, workspace, MinimalRuntimeOptions(state,
                    CapabilitySet(values: grants.toArray()), approval, timeout, maxCalls, caBundle: caBundle), args[offset], tail)
            case _ => minimalError("minimal.command_invalid", "unsupported command; see --help")
        }
    } catch (error: Exception) { minimalError("minimal.invalid_or_unavailable", error.message) }
}
