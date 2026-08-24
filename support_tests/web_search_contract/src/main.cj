package web_search_contract

import agent_domain.*
import agent_ports.*
import agent_product.*
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
        propertyNames(definition.inputSchema) == [
            "query", "recency", "limit", "max_tokens", "temperature",
            "num_search_results"
        ] &&
        requiredNames(definition.inputSchema) == ["query"] &&
        enumNames(
            definition.inputSchema.field("properties").getOrThrow()
                .field("recency").getOrThrow()
        ) == ["day", "week", "month", "year"],
        "web_search exposes the exact pinned schema"
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
            ["curl-secret"]
        ).isOk() && processTransport.requests.size == 1 &&
            processTransport.requests[0].sandboxMode ==
                ProcessSandboxMode.WorkspaceReadOnly &&
            processTransport.requests[0].networkAccess &&
            containsArgument(
                processTransport.requests[0].redactedValues,
                "curl-secret"
            ),
        "curl transport grants read-only workspace plus network and binds authored secrets to output redaction"
    )
    let runtime = ProductWebSearchRuntime(transport, root + "/settings")
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
    let forcedMissing = runtime.executeSelected(
        context,
        searchCall("forced-missing", "Cangjie"),
        "brave"
    ).value().getOrThrow()
    expect(
        forcedMissing.output.field("content").getOrThrow().text ==
            "Error: Brave is not configured.",
        "an explicitly selected provider must be configured"
    )
    let unsupported = runtime.executeSelected(
        context,
        searchCall("unsupported", "Cangjie"),
        "perplexity"
    ).value().getOrThrow()
    expect(
        unsupported.output.field("content").getOrThrow().text
            .contains("is not available in this axyndra build"),
        "a known but unavailable provider fails explicitly"
    )

    setVariable("BRAVE_API_KEY", "brave-secret")
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
        brave.output.field("provider").getOrThrow().text == "brave" &&
        brave.output.field("count").getOrThrow().number == "1" &&
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
        tavily.output.field("provider").getOrThrow().text == "tavily" &&
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
        searxng.output.field("provider").getOrThrow().text == "searxng" &&
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
        runtime.execute(
            context,
            ToolCall(
                "empty",
                "web_search",
                objectValue([
                    ValueField("query", textValue(""))
                ])
            )
        ).isError(),
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
        secretValues: Array<String>
    ): Result<ProcessResult> {
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
    runtime.execute(context, call).value().getOrThrow()
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

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
