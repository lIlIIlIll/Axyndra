package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

func hostCheckedManagedRefreshDirectory(value: AgentValue, limits!: ServiceProtocolLimits = ServiceProtocolLimits()): AgentValue {
    let frozen = parseUnifiedJson(stringifyUnifiedJson(value), maxBytes: limits.maxDirectoryBytes)
    hostLifecycleExact(frozen, ["tools"])
    let tools = frozen.field("tools").getOrThrow()
    hostLifecycleRequire(tools.unifiedKind == ValueKind.List && tools.items.size <= limits.maxTools)
    let names = HashSet<String>()
    for (item in tools.items) {
        hostLifecycleExact(item, ["name", "description", "input_schema"])
        let name = hostLifecycleText(item, "name")
        hostLifecycleRequire(hostLifecycleIdentifier(name, 128) && !name.contains(":") && !name.contains(".") && !names.contains(name))
        names.add(name)
        hostLifecycleRequire(hostLifecycleText(item, "description").size <= 4096 &&
            item.field("input_schema").getOrThrow().unifiedKind == ValueKind.Object)
    }
    frozen
}

class HostManagedRefreshObserver <: JavaScriptHostObserver {
    private let window: HostLifecycleRefreshWindow
    private let gate = HostManagedChannelGate()
    init(window: HostLifecycleRefreshWindow) { this.window = window }
    func close(): Unit { gate.close() }
    public func onProgress(_: String, _: String): JavaScriptHostResult<Unit> {
        hostPluginServiceError("channel.refresh_progress_denied", "directory refresh has no UI or progress effects")
    }
    public func onServiceRequest(invocationId: String, requestId: String, name: String,
        argumentsJson: String): JavaScriptHostResult<String> {
        if (!gate.accept(invocationId, requestId) || window.closedOrCancelled()) {
            return hostPluginServiceError("channel.refresh_closed", "directory refresh window is closed")
        }
        let arguments = match (hostJavascriptPluginDecodeValue(argumentsJson, maxBytes: 65536)) {
            case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(value) => value
        }
        if (name == "process.channel.refresh.write") {
            if (!httpIntentExactFields(arguments, ["bytes_hex"])) {
                return hostPluginServiceError("channel.refresh_arguments_invalid", "refresh writes contain only bounded bytes")
            }
            let bytes = match (channelServiceWriteBytes(objectValue([ValueField("id", textValue("refresh")),
                ValueField("bytes_hex", arguments.field("bytes_hex").getOrThrow())]))) {
                case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(value) => value
            }
            match (window.write(bytes)) {
                case Result.Err(error) => hostPluginServiceAgentError(error)
                case Result.Ok(_) => JavaScriptHostResult.Ok(stringifyUnifiedJson(objectValue([ValueField("written_bytes", integerValue(bytes.size))])))
            }
        } else if (name == "process.channel.read") {
            let request = match (hostManagedChannelReadArguments(arguments)) {
                case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(value) => value
            }
            let (stream, maxBytes, waitMillis, encoding) = request
            match (window.read(stream, maxBytes, waitMillis)) {
                case Result.Err(error) => hostPluginServiceAgentError(error); case Result.Ok(value) => hostManagedChannelReadResult(value, encoding: encoding)
            }
        } else { hostPluginServiceError("channel.refresh_service_denied", "refresh permits only its finite approved discovery channel") }
    }
}
