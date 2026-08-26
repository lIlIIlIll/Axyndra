package agent_product

import yjson.*
import yjson_support.*
import agent_domain.*
import agent_ports.*
import tool_runtime.*
import std.collection.*
import std.env.*
import std.fs.*

public interface WebSearchTransport {
    func execute(
        arguments: Array<String>,
        operationId: OperationId,
        secretValues: Array<String>
    ): Result<ProcessResult>
}

public class CurlWebSearchTransport <: WebSearchTransport {
    private let processes: ProcessPort
    private let executable: String

    public init(
        processes: ProcessPort,
        executable!: String = ""
    ) {
        this.processes = processes
        this.executable = if (executable != "") {
            executable
        } else {
            resolveExecutable(
                ["/usr/bin/curl", "/usr/local/bin/curl"],
                "curl"
            )
        }
    }

    public func execute(
        arguments: Array<String>,
        operationId: OperationId,
        secretValues: Array<String>
    ): Result<ProcessResult> {
        processes.execute(ProcessRequest(
            executable,
            operationId: operationId,
            arguments: arguments,
            timeoutMillis: 120000,
            sandboxMode: ProcessSandboxMode.WorkspaceReadOnly,
            networkAccess: true,
            redactedValues: secretValues
        ))
    }
}

class ProductSearchSource {
    let title: String
    let url: String
    let snippet: String
    let publishedDate: String

    init(
        title: String,
        url: String,
        snippet: String,
        publishedDate: String
    ) {
        this.title = title
        this.url = url
        this.snippet = snippet
        this.publishedDate = publishedDate
    }
}

class ProductSearchResponse {
    let provider: String
    let answer: String
    let sources: Array<ProductSearchSource>

    init(
        provider: String,
        answer: String,
        sources: Array<ProductSearchSource>
    ) {
        this.provider = provider
        this.answer = answer
        this.sources = sources
    }
}

public class ProductWebSearchRuntime {
    private let transport: WebSearchTransport
    private let settingsRoot: String

    public init(
        transport: WebSearchTransport,
        settingsRoot: String
    ) {
        this.transport = transport
        this.settingsRoot = settingsRoot
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        executeSelected(context, call, "")
    }

    public func executeSelected(
        context: ToolInvocationContext,
        call: ToolCall,
        providerOverride: String
    ): Result<ToolResult> {
        let _ = context
        let query = match (requiredString(call, "query")) {
            case Result.Ok(value) => value.trimAscii()
            case Result.Err(error) => return Result.Err(error)
        }
        if (query == "") {
            return webSearchArgumentError<ToolResult>(
                call,
                "query",
                "web search query must not be empty"
            )
        }
        let recency = optionalString(call, "recency", "")
        if (recency != "" && recency != "day" && recency != "week" &&
            recency != "month" && recency != "year") {
            return webSearchArgumentError<ToolResult>(
                call,
                "recency",
                "recency must be day, week, month, or year"
            )
        }
        let authoredLimit = optionalInteger(call, "limit", 10)
        let authoredSearchResults = optionalInteger(
            call,
            "num_search_results",
            authoredLimit
        )
        let limit = if (authoredSearchResults < 1) {
            1
        } else if (authoredSearchResults > 20) {
            20
        } else {
            authoredSearchResults
        }
        let provider = if (providerOverride == "" ||
            providerOverride == "auto") {
            resolveWebSearchProvider()
        } else {
            providerOverride
        }
        if (provider != "none" &&
            provider != "brave" &&
            provider != "tavily" &&
            provider != "searxng") {
            return Result.Ok(webSearchFailure(
                call,
                provider,
                "Search provider \"" + provider +
                    "\" is not available in this axyndra build."
            ))
        }
        if ((provider == "brave" &&
            webSearchVariable("BRAVE_API_KEY") == "") ||
            (provider == "tavily" &&
            webSearchVariable("TAVILY_API_KEY") == "") ||
            (provider == "searxng" &&
            webSearchVariable("SEARXNG_URL") == "")) {
            return Result.Ok(webSearchFailure(
                call,
                provider,
                webSearchProviderLabel(provider) +
                    " is not configured."
            ))
        }
        if (provider == "none") {
            return Result.Ok(ToolResult(
                call.callId,
                objectValue([
                    ValueField(
                        "content",
                        textValue(
                            "Error: No web search provider configured."
                        )
                    ),
                    ValueField("provider", textValue("none")),
                    ValueField("count", integerValue(0)),
                    ValueField("sources", listValue([])),
                    ValueField(
                        "error",
                        textValue("No web search provider configured.")
                    )
                ])
            ))
        }
        let request = match (webSearchArguments(
            provider,
            query,
            recency,
            limit,
            call
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let result = match (transport.execute(
            request,
            OperationId(
                "web-search-" + safeOperationPart(call.callId)
            ),
            webSearchSecretValues(provider)
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (result.exitCode != 0) {
            return Result.Ok(webSearchFailure(
                call,
                provider,
                if (result.stderr.trimAscii() == "") {
                    "provider request failed with exit code " +
                        result.exitCode.toString()
                } else {
                    result.stderr.trimAscii()
                }
            ))
        }
        let parsed = try {
            parseWebSearchResponse(
                provider,
                parseUnifiedJson(result.stdout, maxBytes: 16777216),
                limit
            )
        } catch (error: Exception) {
            return Result.Ok(webSearchFailure(
                call,
                provider,
                "invalid provider response: " + error.message
            ))
        }
        if (parsed.answer.trimAscii() == "" &&
            parsed.sources.size == 0) {
            return Result.Ok(webSearchFailure(
                call,
                provider,
                webSearchProviderLabel(provider) +
                    " returned no renderable search content."
            ))
        }
        Result.Ok(webSearchResult(call, parsed))
    }

    private func webSearchSecretValues(provider: String): Array<String> {
        match (provider) {
            case "brave" => [webSearchVariable("BRAVE_API_KEY")]
            case "tavily" => [webSearchVariable("TAVILY_API_KEY")]
            case "searxng" => [webSearchVariable("SEARXNG_URL")]
            case _ => []
        }
    }

    private func resolveWebSearchProvider(): String {
        if (webSearchVariable("BRAVE_API_KEY") != "") {
            return "brave"
        }
        if (webSearchVariable("TAVILY_API_KEY") != "") {
            return "tavily"
        }
        if (webSearchVariable("SEARXNG_URL") != "") {
            return "searxng"
        }
        "none"
    }

    private func webSearchVariable(name: String): String {
        match (getVariable(name)) {
            case Some(value) =>
                if (value.trimAscii() != "") {
                    return value.trimAscii()
                }
            case None => ()
        }
        let fileName = match (name) {
            case "BRAVE_API_KEY" => "brave.key"
            case "TAVILY_API_KEY" => "tavily.key"
            case _ => ""
        }
        if (fileName == "") { return "" }
        let path = settingsRoot + "/credentials/" + fileName
        if (!exists(Path(path))) { return "" }
        try {
            String.fromUtf8(File.readFrom(path)).trimAscii()
        } catch (_: Exception) {
            ""
        }
    }

    private func webSearchArguments(
        provider: String,
        query: String,
        recency: String,
        limit: Int64,
        call: ToolCall
    ): Result<Array<String>> {
        match (provider) {
            case "brave" =>
                let arguments = ArrayList<String>()
                arguments.add(all: [
                    "--fail-with-body", "--silent", "--show-error",
                    "--get",
                    "https://api.search.brave.com/res/v1/web/search",
                    "-H",
                    "Accept: application/json",
                    "-H",
                    "X-Subscription-Token: " +
                        webSearchVariable("BRAVE_API_KEY"),
                    "--data-urlencode",
                    "q=" + query,
                    "--data-urlencode",
                    "count=" + limit.toString()
                ])
                if (recency != "") {
                    arguments.add("--data-urlencode")
                    arguments.add(
                        "freshness=" + braveRecency(recency)
                    )
                }
                Result.Ok(arguments.toArray())
            case "tavily" =>
                let payload = jsonObject([
                    JsonObjectEntry(
                        "api_key",
                        jsonString(
                            webSearchVariable("TAVILY_API_KEY")
                        )
                    ),
                    JsonObjectEntry("query", jsonString(query)),
                    JsonObjectEntry(
                        "max_results",
                        jsonNumber(limit.toString())
                    ),
                    JsonObjectEntry(
                        "include_answer",
                        jsonBool(true)
                    ),
                    JsonObjectEntry(
                        "search_depth",
                        jsonString("basic")
                    )
                ])
                if (recency != "") {
                    payload.put(
                        "time_range",
                        jsonString(recency)
                    )
                }
                match (call.arguments.field("max_tokens")) {
                    case Some(value) =>
                        if (value.unifiedKind == ValueKind.Number) {
                            payload.put(
                                "max_tokens",
                                jsonNumber(value.number)
                            )
                        }
                    case None => ()
                }
                Result.Ok([
                    "--fail-with-body", "--silent", "--show-error",
                    "https://api.tavily.com/search",
                    "-H", "Content-Type: application/json",
                    "--data", payload.stringify()
                ])
            case "searxng" =>
                let endpoint = webSearchVariable("SEARXNG_URL")
                    .removeSuffix("/")
                Result.Ok([
                    "--fail-with-body", "--silent", "--show-error",
                    "--get", endpoint + "/search",
                    "--data-urlencode", "q=" + query,
                    "--data-urlencode", "format=json",
                    "--data-urlencode", "limit=" + limit.toString(),
                    "--data-urlencode",
                    if (recency == "") {
                        "time_range="
                    } else {
                        "time_range=" + recency
                    }
                ])
            case _ => webSearchArgumentError<Array<String>>(
                call,
                "provider",
                "unsupported web search provider"
            )
        }
    }
}

class WebSearchTool <: ToolExecutor {
    private let runtime: ProductWebSearchRuntime
    init(runtime: ProductWebSearchRuntime) { this.runtime = runtime }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        runtime.execute(context, call)
    }
}

func parseWebSearchResponse(
    provider: String,
    root: JsonNode,
    limit: Int64
): ProductSearchResponse {
    let sources = ArrayList<ProductSearchSource>()
    var answer = ""
    let rawItems: Array<JsonNode> = match (provider) {
        case "brave" =>
            match (root.field("web")) {
                case Some(web) => jsonArrayItems(web, "results")
                case None => []
            }
        case "tavily" =>
            answer = jsonString(root, "answer")
            jsonArrayItems(root, "results")
        case "searxng" => jsonArrayItems(root, "results")
        case _ => []
    }
    for (item in rawItems) {
        if (sources.size >= limit) { break }
        let title = jsonString(item, "title")
        let url = jsonString(item, "url")
        if (url == "") { continue }
        let snippet = if (provider == "brave") {
            jsonString(item, "description")
        } else {
            jsonString(item, "content")
        }
        let published = if (provider == "tavily") {
            jsonString(item, "published_date")
        } else {
            jsonString(item, "publishedDate")
        }
        sources.add(ProductSearchSource(
            if (title == "") { url } else { title },
            url,
            snippet,
            published
        ))
    }
    ProductSearchResponse(provider, answer, sources.toArray())
}

func webSearchResult(
    call: ToolCall,
    response: ProductSearchResponse
): ToolResult {
    var text = ""
    if (response.answer.trimAscii() != "") {
        text += response.answer.trimAscii()
        if (response.sources.size > 0) {
            text += "\n\n## Sources\n" +
                response.sources.size.toString() + " " +
                if (response.sources.size == 1) {
                    "source"
                } else {
                    "sources"
                }
        }
    }
    let sourceValues = ArrayList<AgentValue>()
    for (index in 0..response.sources.size) {
        let source = response.sources[index]
        if (text != "") { text += "\n" }
        text += "[" + (index + 1).toString() + "] " + source.title
        if (source.publishedDate != "") {
            text += " (" + source.publishedDate + ")"
        }
        text += "\n    " + source.url
        if (source.snippet != "") {
            text += "\n    " + webSearchTruncate(source.snippet, 240)
        }
        sourceValues.add(objectValue([
            ValueField("title", textValue(source.title)),
            ValueField("url", textValue(source.url)),
            ValueField("snippet", textValue(source.snippet)),
            ValueField(
                "publishedDate",
                textValue(source.publishedDate)
            )
        ]))
    }
    ToolResult(
        call.callId,
        objectValue([
            ValueField("content", textValue(text)),
            ValueField("provider", textValue(response.provider)),
            ValueField("count", integerValue(response.sources.size)),
            ValueField("sources", listValue(sourceValues.toArray())),
            ValueField("error", nullValue())
        ])
    )
}

func webSearchFailure(
    call: ToolCall,
    provider: String,
    message: String
): ToolResult {
    ToolResult(
        call.callId,
        objectValue([
            ValueField("content", textValue("Error: " + message)),
            ValueField("provider", textValue(provider)),
            ValueField("count", integerValue(0)),
            ValueField("sources", listValue([])),
            ValueField("error", textValue(message))
        ])
    )
}

func jsonArrayItems(value: JsonNode, name: String): Array<JsonNode> {
    match (value.field(name)) {
        case Some(array) =>
            if (array.unifiedKind == UnifiedJsonKind.List) { array.items } else { [] }
        case None => []
    }
}

func jsonString(value: JsonNode, name: String): String {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind == UnifiedJsonKind.Text) { field.text } else { "" }
        case None => ""
    }
}

func braveRecency(value: String): String {
    match (value) {
        case "day" => "pd"
        case "week" => "pw"
        case "month" => "pm"
        case "year" => "py"
        case _ => ""
    }
}

func webSearchProviderLabel(provider: String): String {
    match (provider) {
        case "brave" => "Brave"
        case "tavily" => "Tavily"
        case "searxng" => "SearXNG"
        case _ => "Web search provider"
    }
}

func webSearchTruncate(value: String, limit: Int64): String {
    let bytes = unsafe { value.rawData() }
    if (bytes.size <= limit) { return value }
    String.fromUtf8(bytes[0..limit]) + "…"
}

func webSearchArgumentError<T>(
    call: ToolCall,
    argument: String,
    message: String
): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        "tool.web_search_invalid_argument",
        message,
        fields: [
            ErrorField("tool", call.name),
            ErrorField("argument", argument)
        ]
    ))
}
