package agent_product

import agent_host_runtime

import agent_host_runtime.*

import agent_domain.*
import agent_extension_runtime.*
import agent_sdk.PluginContributionKind
import yjson.*
import yjson_support.*
import tool_runtime.*
import process4cj as process
import std.collection.*
import std.fs.Path
import sandbox4cj.*
import std.sync.*
import std.time.*
// Product-owned lifecycle wrapper for the process-backed JavaScript host. The
// extension runtime owns the wire protocol; this layer owns activation,
// cancellation bridging, tool registration, and product error semantics.
public type ProductJavaScriptPluginInvocationResult = agent_host_runtime.HostJavaScriptPluginInvocationResult

public type ProductJavaScriptPluginCommand = agent_host_runtime.HostJavaScriptPluginCommand

public type ProductJavaScriptPluginHook = agent_host_runtime.HostJavaScriptPluginHook

public class ProductJavaScriptPluginHost <: agent_host_runtime.HostJavaScriptPluginHost {
    public init(settingsRoot!: String = "", readViewStateRoot!: String = "",
        readTargetInspectors!: HostReadTargetInspectorFactory = { root => LocalWorkspace(root) },
        documentBackends!: (HostPluginDocumentConfiguration)->Result<Unit> = {_=>Result.Ok(())}) {
        super(readTargetInspectors, settingsRoot: settingsRoot, readViewStateRoot: readViewStateRoot,documentBackends:documentBackends)
    }
}

type ProductSandboxedJavaScriptHostLauncher = agent_host_runtime.HostSandboxedJavaScriptHostLauncher

func productJavaScriptHostResourceLimits(maxOutputBytes: Int64): SandboxResourceLimits {
    agent_host_runtime.hostJavaScriptHostResourceLimits(maxOutputBytes)
}

func javascriptPluginLimitsFitHost(requested: ExecutionResourceLimits): Bool {
    agent_host_runtime.hostJavascriptPluginLimitsFitHost(requested)
}

func javascriptPluginLimitFitsHost(requested: Int64, host: Int64): Bool {
    agent_host_runtime.hostJavascriptPluginLimitFitsHost(requested, host)
}

type ProductJavaScriptPluginThreadHost = agent_host_runtime.HostJavaScriptPluginThreadHost

type ProductDocumentDataWorker = agent_host_runtime.HostDocumentDataWorker

type ProductJavaScriptPluginGeneration = agent_host_runtime.HostJavaScriptPluginGeneration

public type ProductJavaScriptPluginToolExecutor = agent_host_runtime.HostJavaScriptPluginToolExecutor

func pluginInvocationAuthorityScope(context: ToolInvocationContext): String {
    agent_host_runtime.hostPluginInvocationAuthorityScope(context)
}

func productOrdinaryToolPayloadSelection(settingsRoot: String, descriptor: PluginPackageDescriptor,
    availableTools: Array<String>, kind: String, tool: String, limits: ?OrdinaryToolPayloadLimits, document!: Bool = false): Result<String> {
    agent_host_runtime.hostOrdinaryToolPayloadSelection(settingsRoot, descriptor, availableTools, kind, tool, limits, document: document)
}

func startProductJavaScriptHost(
    descriptor: PluginPackageDescriptor,
    generation: UInt64,
    launcher: JavaScriptHostProcessLauncher,
    timeoutMillis!: Int64 = 30000,
    cancellation!: ?process.CancellationToken = None, serviceLimits!: ?ServiceProtocolLimits = None, payloadLimits!: ?ServicePayloadLimits = None,
    ordinaryToolPayload!: Bool = false, providerSequence!: Bool = false
): JavaScriptHostResult<JavaScriptExtensionHost> {
    agent_host_runtime.hostStartJavaScriptHost(descriptor, generation, launcher, timeoutMillis: timeoutMillis, cancellation: cancellation, serviceLimits: serviceLimits, payloadLimits: payloadLimits, ordinaryToolPayload: ordinaryToolPayload, providerSequence: providerSequence)
}

func javascriptPluginAgentError(error: JavaScriptHostError): AgentError {
    agent_host_runtime.hostJavascriptPluginAgentError(error)
}

func javascriptPluginDecodeValue(
    source: String,
    maxBytes!: Int64 = 1048576
): Result<AgentValue> {
    agent_host_runtime.hostJavascriptPluginDecodeValue(source, maxBytes: maxBytes)
}

func javascriptPluginError<T>(code: String, message: String): Result<T> {
    agent_host_runtime.hostJavascriptPluginError<T>(code, message)
}

func newPluginInstanceIdentity(): Result<String> {
    agent_host_runtime.hostNewPluginInstanceIdentity()
}

func productOrdinaryToolPayloadSelection(settingsRoot: String, descriptor: OwnedPluginPackageDescriptor,
    availableTools: Array<String>, kind: String, tool: String, limits: ?OrdinaryToolPayloadLimits, document!: Bool = false): Result<String> {
    agent_host_runtime.hostOrdinaryToolPayloadSelection(settingsRoot, descriptor, availableTools, kind, tool, limits, document: document)
}

func startProductJavaScriptHost(
    descriptor: OwnedPluginPackageDescriptor,
    generation: UInt64,
    launcher: JavaScriptHostProcessLauncher,
    timeoutMillis!: Int64 = 30000,
    cancellation!: ?process.CancellationToken = None, serviceLimits!: ?ServiceProtocolLimits = None, payloadLimits!: ?ServicePayloadLimits = None,
    ordinaryToolPayload!: Bool = false, providerSequence!: Bool = false
): JavaScriptHostResult<JavaScriptExtensionHost> {
    agent_host_runtime.hostStartJavaScriptHost(descriptor, generation, launcher, timeoutMillis: timeoutMillis, cancellation: cancellation, serviceLimits: serviceLimits, payloadLimits: payloadLimits, ordinaryToolPayload: ordinaryToolPayload, providerSequence: providerSequence)
}
