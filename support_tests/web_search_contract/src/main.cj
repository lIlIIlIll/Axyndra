package web_search_contract

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_ports.*
import agent_product.*
import agent_runtime.*
import agent_testkit.*
import std.collection.*
import std.env.*
import std.fs.*
import tool_runtime.*

main(): Int64 {
    if (!exists(Path("target"))) {
        Directory.create("target", recursive: true)
    }
    let root = Directory.createTemp("target").toString()
    try {
        verifySchema(root)
        verifyProviders(root)
        verifyLocalProcessContracts(root)
        println("web search contract passed")
        0
    } finally {
        removeVariable("BRAVE_API_KEY")
        removeVariable("TAVILY_API_KEY")
        removeVariable("SEARXNG_URL")
        let _ = removeIfExists(root, recursive: true)
    }
}

func verifySchema(root: String): Unit {
    let product = openProduct(config: ProductConfig(
        settingsRoot: root + "/settings",
        stateRoot: root + "/state",
        workspaceRoot: root,
        fixture: true,
        approvalMode: ApprovalMode.Yolo,
        asyncEnabled: false
    )).value().getOrThrow()
    let definition = toolDefinition(product, "web_search")
    expect(
        sameStringSet(propertyNames(definition.inputSchema), [
            "query", "provider", "recency", "limit", "max_tokens", "temperature",
            "num_search_results"
        ]) &&
        sameStringSet(requiredNames(definition.inputSchema), ["query"]) &&
        sameStringSet(enumNames(
            definition.inputSchema.field("properties").getOrThrow()
                .field("recency").getOrThrow()
        ), ["day", "week", "month", "year"]),
        "web_search exposes the reviewed schema"
    )
}

func verifyProviders(root: String): Unit {
    removeVariable("BRAVE_API_KEY")
    removeVariable("TAVILY_API_KEY")
    removeVariable("SEARXNG_URL")
    let transport = FakeSearchTransport()
    let processTransport = RecordingSearchProcessPort()
    expect(
        CurlWebSearchTransport(
            processTransport,
            executable: "/usr/bin/curl"
        ).execute(
            ["--header", "Authorization: Bearer curl-secret"],
            OperationId("search-curl-profile"),
            webSearchContractNetworkPolicy(""),
            ["curl-secret"]
        ).isOk() && processTransport.requests.size == 1 &&
            processTransport.requests[0].sandboxMode ==
                ProcessSandboxMode.WorkspaceReadOnly &&
            networkPolicyModeIsMediated(
                processTransport.requests[0].networkPolicy.mode
            ) &&
            containsArgument(
                processTransport.requests[0].redactedValues,
                "curl-secret"
            ),
        "curl transport grants read-only workspace plus network and binds authored secrets to output redaction"
    )
    let runtime = ProductWebSearchRuntime(transport, root + "/settings")
    let missingBravePolicy = match (runtime.networkPolicy(objectValue([
        ValueField("provider", textValue("brave"))
    ]))) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(error.message)
    }
    expect(
        networkPolicyModeIsDenied(missingBravePolicy.mode),
        "unconfigured web search providers do not acquire network access"
    )
    let context = ToolInvocationContext(
        RunId("search-run"),
        SessionId("search-session"),
        CapabilitySet(values: [
            Capability(CapabilityKind.NetworkAccess)
        ])
    )
    let unconfigured = invoke(
        runtime,
        context,
        searchCall("none", "Cangjie")
    )
    expect(
        unconfigured.output.field("content").getOrThrow().text ==
            "Error: No web search provider configured." &&
        unconfigured.output.field("provider").getOrThrow().text == "none",
        "an absent provider reports the pinned explicit error"
    )
    let forcedMissing = invokeSelected(
        runtime,
        context,
        searchCall("forced-missing", "Cangjie"),
        "brave",
        "forced-missing"
    )
    expect(
        forcedMissing.output.field("content").getOrThrow().text ==
            "Error: Brave is not configured.",
        "an explicitly selected provider must be configured"
    )
    let unsupported = invokeSelected(
        runtime,
        context,
        searchCall("unsupported", "Cangjie"),
        "perplexity",
        "unsupported"
    )
    expect(
        unsupported.output.field("content").getOrThrow().text
            .contains("is not available in this axyndra build"),
        "a known but unavailable provider fails explicitly"
    )

    setVariable("BRAVE_API_KEY", "brave-secret")
    let bravePolicy = match (runtime.networkPolicy(objectValue([
        ValueField("provider", textValue("brave"))
    ]))) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(error.message)
    }
    expect(
        networkPolicyModeIsMediated(bravePolicy.mode) &&
            bravePolicy.egress.size == 1 &&
            bravePolicy.egress[0].host == "api.search.brave.com" &&
            bravePolicy.egress[0].port == 443u16,
        "Brave policy is mediated and limited to its API endpoint"
    )
    transport.response = """
        {"web":{"results":[
          {"title":"Cangjie docs","url":"https://example.test/docs",
           "description":"Language documentation","publishedDate":"2026-07-30"},
          {"title":"SDK","url":"https://example.test/sdk",
           "description":"SDK release"}
        ]}}
        """
    let brave = invoke(
        runtime,
        context,
        ToolCall(
            "brave",
            "web_search",
            objectValue([
                ValueField("query", textValue("Cangjie language")),
                ValueField("recency", textValue("week")),
                ValueField("limit", integerValue(1))
            ])
        )
    )
    expect(
        transport.arguments[0] == "-q" && brave.output.field("provider").getOrThrow().text == "brave" &&
        brave.output.field("count").getOrThrow().asNumberText() == "1" &&
        brave.output.field("content").getOrThrow().text
            .contains("[1] Cangjie docs (2026-07-30)") &&
        containsArgument(transport.arguments, "q=Cangjie language") &&
        containsArgument(transport.arguments, "count=1") &&
        containsArgument(transport.arguments, "freshness=pw") &&
        containsArgument(
            transport.arguments,
            "X-Subscription-Token: brave-secret"
        ) && containsArgument(transport.secretValues, "brave-secret"),
        "Brave executes an authenticated bounded request and parses sources"
    )

    removeVariable("BRAVE_API_KEY")
    setVariable("TAVILY_API_KEY", "tavily-secret")
    transport.response = """
        {"answer":"Cangjie is a programming language.",
         "results":[{"title":"Overview","url":"https://example.test/overview",
         "content":"Current overview","published_date":"2026-07-31"}]}
        """
    let tavily = invoke(
        runtime,
        context,
        ToolCall(
            "tavily",
            "web_search",
            objectValue([
                ValueField("query", textValue("What is Cangjie?")),
                ValueField("recency", textValue("month")),
                ValueField("num_search_results", integerValue(3)),
                ValueField("max_tokens", integerValue(800))
            ])
        )
    )
    let tavilyPayload = transport.arguments[
        transport.arguments.size - 1
    ]
    expect(
        transport.arguments[0] == "-q" && tavily.output.field("provider").getOrThrow().text == "tavily" &&
        tavily.output.field("content").getOrThrow().text
            .startsWith("Cangjie is a programming language.") &&
        tavily.output.field("content").getOrThrow().text
            .contains("## Sources") &&
        tavilyPayload.contains("\"api_key\":\"tavily-secret\"") &&
        tavilyPayload.contains("\"max_results\":3") &&
        tavilyPayload.contains("\"time_range\":\"month\"") &&
        tavilyPayload.contains("\"max_tokens\":800") &&
        containsArgument(transport.secretValues, "tavily-secret"),
        "Tavily sends a structured request and preserves answer plus sources"
    )

    removeVariable("TAVILY_API_KEY")
    setVariable("SEARXNG_URL", "https://search.example.test/")
    let searxPolicy = match (runtime.networkPolicy(objectValue([
        ValueField("provider", textValue("searxng"))
    ]))) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(error.message)
    }
    expect(
        networkPolicyModeIsMediated(searxPolicy.mode) &&
            searxPolicy.egress.size == 1 &&
            searxPolicy.egress[0].host == "search.example.test" &&
            searxPolicy.egress[0].port == 443u16,
        "SearXNG policy is mediated and follows the configured endpoint"
    )
    setVariable("SEARXNG_URL", "http://localhost:8080/")
    let loopbackSearxPolicy = match (runtime.networkPolicy(objectValue([
        ValueField("provider", textValue("searxng"))
    ]))) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(error.message)
    }
    var hasLoopbackV4 = false
    var hasLoopbackV6 = false
    for (address in loopbackSearxPolicy.egress[0].privateAddresses) {
        if (address == "127.0.0.1") { hasLoopbackV4 = true }
        if (address == "::1") { hasLoopbackV6 = true }
    }
    expect(
        networkPolicyModeIsMediated(loopbackSearxPolicy.mode) &&
            loopbackSearxPolicy.egress.size == 1 &&
            loopbackSearxPolicy.egress[0].host == "localhost" &&
            loopbackSearxPolicy.egress[0].port == 8080u16 &&
            loopbackSearxPolicy.egress[0].privateAddresses.size == 2 &&
            hasLoopbackV4 && hasLoopbackV6,
        "SearXNG localhost policy permits both loopback address families"
    )
    setVariable("SEARXNG_URL", "https://search.example.test/")
    transport.response = """
        {"results":[{"title":"Result","url":"https://example.test/result",
        "content":"SearXNG snippet"}]}
        """
    let searxng = invoke(
        runtime,
        context,
        searchCall("searxng", "local metasearch")
    )
    expect(
        transport.arguments[0] == "-q" && searxng.output.field("provider").getOrThrow().text == "searxng" &&
        searxng.output.field("content").getOrThrow().text
            .contains("SearXNG snippet") &&
        containsArgument(
            transport.arguments,
            "https://search.example.test/search"
        ) && containsArgument(
            transport.secretValues,
            "https://search.example.test/"
        ),
        "SearXNG executes against the configured endpoint"
    )

    transport.exitCode = 22
    transport.error = "HTTP 401"
    let failed = invoke(
        runtime,
        context,
        searchCall("failure", "unauthorized")
    )
    expect(
        failed.output.field("content").getOrThrow().text ==
            "Error: HTTP 401" &&
        failed.output.field("error").getOrThrow().text == "HTTP 401",
        "provider HTTP failures are returned as explicit search errors"
    )
    transport.exitCode = 0
    transport.error = ""
    transport.response = "{not json"
    let malformed = invoke(
        runtime,
        context,
        searchCall("malformed", "bad response")
    )
    expect(
        malformed.output.field("content").getOrThrow().text
            .startsWith("Error: invalid provider response:"),
        "malformed provider JSON cannot masquerade as empty success"
    )
    expect(
        invocationFailed(
            runtime,
            context,
            ToolCall(
                "empty",
                "web_search",
                objectValue([
                    ValueField("query", textValue(""))
                ])
            )
        ),
        "empty queries fail schema-level execution validation"
    )
}

class RecordingSearchProcessPort <: ProcessPort {
    public let requests = ArrayList<ProcessRequest>()

    public func execute(request: ProcessRequest): Result<ProcessResult> {
        requests.add(request)
        Result.Ok(ProcessResult(0, stdout: "{}"))
    }

    public func cancel(operationId: OperationId): Result<Unit> {
        let _ = operationId
        Result.Ok(())
    }
}

class FakeSearchTransport <: WebSearchTransport {
    public var response: String = "{}"
    public var exitCode: Int64 = 0
    public var error: String = ""
    public var arguments: Array<String> = []
    public var secretValues: Array<String> = []
    public func execute(
        arguments: Array<String>,
        operationId: OperationId,
        networkPolicy: NetworkPolicy,
        secretValues: Array<String>
    ): Result<ProcessResult> {
        let _ = networkPolicy
        let _ = operationId
        this.arguments = arguments
        this.secretValues = secretValues
        Result.Ok(ProcessResult(
            exitCode,
            stdout: response,
            stderr: error
        ))
    }
}

func invoke(
    runtime: ProductWebSearchRuntime,
    context: ToolInvocationContext,
    call: ToolCall
): ToolResult {
    invokeSelected(runtime, context, call, "", call.callId)
}

func invokeSelected(
    runtime: ProductWebSearchRuntime,
    context: ToolInvocationContext,
    call: ToolCall,
    providerOverride: String,
    operationName: String
): ToolResult {
    match (invokeSelectedResult(
        runtime,
        context,
        call,
        providerOverride,
        operationName
    )) {
        case Result.Ok(result) => result
        case Result.Err(error) => recoverableToolResult(call, error)
    }
}

func invocationFailed(
    runtime: ProductWebSearchRuntime,
    context: ToolInvocationContext,
    call: ToolCall
): Bool {
    invocationFailedSelected(runtime, context, call, "", call.callId)
}

func invocationFailedSelected(
    runtime: ProductWebSearchRuntime,
    context: ToolInvocationContext,
    call: ToolCall,
    providerOverride: String,
    operationName: String
): Bool {
    match (invokeSelectedResult(
        runtime,
        context,
        call,
        providerOverride,
        operationName
    )) {
        case Result.Err(_) => true
        case Result.Ok(result) => result.isError
    }
}

func invokeSelectedResult(
    runtime: ProductWebSearchRuntime,
    context: ToolInvocationContext,
    call: ToolCall,
    providerOverride: String,
    operationName: String
): Result<ToolResult> {
    let catalog = ToolCatalog()
    let registration = catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "web_search",
                "Web Search contract fixture.",
                webSearchContractSchema()
            ),
            Capability(CapabilityKind.NetworkAccess),
            sideEffecting: true,
            networkPolicyResolver: Some({_value =>
                Result.Ok(webSearchContractExecutionNetworkPolicy(operationName))
            })
        ),
        WebSearchContractExecutor(runtime, providerOverride)
    )
    match (registration) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(_) => ()
    }
    let pipeline = ToolPipeline(
        catalog,
        InMemoryOperationRuntimePort(),
        WebSearchContractAudit(),
        WebSearchContractIds(operationName),
        policy: DefaultCapabilityPolicy(mode: ApprovalMode.Yolo)
    )
    match (executePipelineCall(pipeline, context, call)) {
        case Result.Err(error) => Result.Err(error)
        case Result.Ok(ToolInvocationResult.Completed(result)) =>
            Result.Ok(result)
        case Result.Ok(ToolInvocationResult.NeedsApproval(_)) =>
            Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "web_search.contract_approval_required",
                "web search contract fixture unexpectedly requires approval"
            ))
        case Result.Ok(ToolInvocationResult.Denied(_)) =>
            Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "web_search.contract_denied",
                "web search contract fixture unexpectedly denied the operation"
            ))
    }
}

class WebSearchContractExecutor <: ToolExecutor {
    private let runtime: ProductWebSearchRuntime
    private let providerOverride: String

    init(runtime: ProductWebSearchRuntime, providerOverride: String) {
        this.runtime = runtime
        this.providerOverride = providerOverride
    }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        runtime.executeSelected(context, prepared, providerOverride)
    }
}

class WebSearchContractAudit <: AuditPort {
    public func append(event: AgentEvent): Result<Unit> {
        let _ = event
        Result.Ok(())
    }
}

class WebSearchContractIds <: IdGenerator {
    private let operationName: String

    init(operationName: String) {
        this.operationName = operationName
    }

    public func nextRunId(): RunId { RunId("web-search-contract-run") }
    public func nextSessionId(): SessionId { SessionId("web-search-contract-session") }
    public func nextOperationId(): OperationId {
        OperationId("web-search-" + operationName)
    }
}

func webSearchContractSchema(): AgentValue {
    objectValue([
        ValueField("type", textValue("object")),
        ValueField("required", listValue([textValue("query")]))
    ])
}

func webSearchContractExecutionNetworkPolicy(operation: String): NetworkPolicy {
    if (operation.startsWith("local-")) {
        return NetworkPolicy(NetworkPolicyMode.HostNetwork)
    }
    webSearchContractNetworkPolicy(operation)
}

func webSearchContractNetworkPolicy(operation: String): NetworkPolicy {
    let _ = operation
    NetworkPolicy(
        NetworkPolicyMode.Mediated,
        egress: [
            NetworkEgressRule("api.search.brave.com", 443u16),
            NetworkEgressRule("api.tavily.com", 443u16),
            NetworkEgressRule("search.example.test", 443u16)
        ]
    )
}

func searchCall(id: String, query: String): ToolCall {
    ToolCall(
        id,
        "web_search",
        objectValue([
            ValueField("query", textValue(query))
        ])
    )
}

func containsArgument(values: Array<String>, expected: String): Bool {
    for (value in values where value == expected) { return true }
    false
}

func toolDefinition(
    product: ProductRuntime,
    name: String
): ModelToolDefinition {
    for (definition in product.tools() where definition.name == name) {
        return definition
    }
    throw IllegalStateException("missing product tool: " + name)
}

func propertyNames(schema: AgentValue): Array<String> {
    let names = ArrayList<String>()
    for (field in schema.field("properties").getOrThrow().fields) {
        names.add(field.name)
    }
    names.toArray()
}

func requiredNames(schema: AgentValue): Array<String> {
    let names = ArrayList<String>()
    for (value in schema.field("required").getOrThrow().items) {
        names.add(value.text)
    }
    names.toArray()
}

func enumNames(schema: AgentValue): Array<String> {
    let names = ArrayList<String>()
    for (value in schema.field("enum").getOrThrow().items) {
        names.add(value.text)
    }
    names.toArray()
}

func sameStringSet(left: Array<String>, right: Array<String>): Bool {
    if (left.size != right.size) { return false }
    for (candidate in left) {
        var found = false
        for (expected in right) {
            if (candidate == expected) { found = true; break }
        }
        if (!found) { return false }
    }
    true
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
