package agent_product

import agent_host_runtime

import agent_host_runtime.*

import yjson.*
import yjson_support.*
import agent_domain.*
import agent_runtime.*
import agent_store.SqliteDatabase
import tool_runtime.*
import agent_extension_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
let PRODUCT_JAVASCRIPT_SERVICE_MAX_CALLS: Int64 = agent_host_runtime.HOST_JAVASCRIPT_SERVICE_MAX_CALLS

type ProductPluginReadOnlyExecRoute = HostPublishedReadonlyExecRoute159

class ProductJavaScriptPluginServiceRuntime <: agent_host_runtime.HostJavaScriptPluginServiceRuntime {
    private let canonicalDatabase173: ?SqliteDatabase
    private let canonicalSummaryTimeout173: Int64
    init(catalog: ToolCatalog, pipeline: ToolPipeline, operations: OperationRuntimePort, askRuntime: AskRuntime,
        canonicalDatabase173!: ?SqliteDatabase = None<SqliteDatabase>, canonicalSummaryTimeout173!: Int64 = 5000) {
        super(catalog, pipeline, operations, askRuntime, readonlyExecRoute: Some(ProductPluginReadOnlyExecRoute()))
        this.canonicalDatabase173 = canonicalDatabase173; this.canonicalSummaryTimeout173 = canonicalSummaryTimeout173
    }
    public func canonicalProjectionRoute173(host: HostJavaScriptPluginHost,
        selection: HostCanonicalProjectionSelection173): Result<HostCanonicalProjectionRoute173> {
        match (canonicalDatabase173) {
            case None => super.canonicalProjectionRoute173(host, selection)
            case Some(actual) =>
                let productHost = match (host as ProductJavaScriptPluginHost) {
                    case Some(value) => value
                    case None => return super.canonicalProjectionRoute173(host, selection) }
                Result<HostCanonicalProjectionRoute173>.Ok(
                ProductCanonicalProjectionRoute173(actual, productHost, canonicalSummaryTimeout173)) }
    }
    public func canonicalProjectionRouteOwned186(host: HostJavaScriptPluginHost,
        selection: HostOwnedCanonicalProjectionSelection186): Result<HostOwnedCanonicalProjectionRoute186> {
        match (canonicalDatabase173) {
            case None => super.canonicalProjectionRouteOwned186(host, selection)
            case Some(actual) =>
                let productHost = match (host as ProductJavaScriptPluginHost) {
                    case Some(value) => value
                    case None => return super.canonicalProjectionRouteOwned186(host, selection) }
                Result<HostOwnedCanonicalProjectionRoute186>.Ok(
                ProductOwnedCanonicalProjectionRoute186(actual, productHost, canonicalSummaryTimeout173)) }
    }
}

type ProductJavaScriptPluginInvocationObserver = agent_host_runtime.HostJavaScriptPluginInvocationObserver

public type ProductJavaScriptPluginNoticeSink = agent_host_runtime.HostJavaScriptPluginNoticeSink

type ProductJavaScriptPluginCommandObserver = agent_host_runtime.HostJavaScriptPluginCommandObserver

type ProductJavaScriptPluginServiceBroker = agent_host_runtime.HostJavaScriptPluginServiceBroker

func makeJavaScriptPluginChildContext(
    rootPrepared: PreparedToolInvocation,
    rootContext: ToolInvocationContext
): ToolInvocationContext {
    agent_host_runtime.hostMakeJavaScriptPluginChildContext(rootPrepared, rootContext)
}

func pluginPlanRequires(
    plan: NormalizedOperationPlan,
    kind: CapabilityKind
): Bool {
    agent_host_runtime.hostPluginPlanRequires(plan, kind)
}

func validPluginServiceIdentifier(value: String): Bool {
    agent_host_runtime.hostValidPluginServiceIdentifier(value)
}

func pluginServiceResultError(result: ToolResult): AgentError {
    agent_host_runtime.hostPluginServiceResultError(result)
}

func pluginReceiptText(value: AgentValue, name: String): String {
    agent_host_runtime.hostPluginReceiptText(value, name)
}

func pluginServiceResult(
    requestId: String,
    service: String,
    callId: String,
    receiptId: String,
    output: AgentValue,
    isError: Bool
): JavaScriptHostResult<String> {
    agent_host_runtime.hostPluginServiceResult(requestId, service, callId, receiptId, output, isError)
}

func pluginServiceError<T>(code: String, message: String): JavaScriptHostResult<T> {
    agent_host_runtime.hostPluginServiceError<T>(code, message)
}

func pluginServiceAgentResult<T>(error: AgentError): Result<T> {
    agent_host_runtime.hostPluginServiceAgentResult<T>(error)
}

func pluginServiceAgentError<T>(error: AgentError): JavaScriptHostResult<T> {
    agent_host_runtime.hostPluginServiceAgentError<T>(error)
}

func makeManagedChannelChildContext(
    rootPrepared: PreparedToolInvocation,
    rootContext: ToolInvocationContext
): ToolInvocationContext {
    agent_host_runtime.hostMakeManagedChannelChildContext(rootPrepared, rootContext)
}
