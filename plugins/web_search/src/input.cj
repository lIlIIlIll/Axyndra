package web_search_plugin

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

class SearchFailure <: Exception {
    let code: String
    init(code: String, message: String) { super(message); this.code = code }
}

class SearchInput {
    let query: String
    let provider: String
    let recency: String
    let limit: Int64
    let maxTokens: ?String
    init(query: String, provider: String, recency: String, limit: Int64, maxTokens: ?String) {
        this.query = query; this.provider = provider; this.recency = recency
        this.limit = limit; this.maxTokens = maxTokens
    }
}

// Availability is supplied as values by the eventual protocol adapter. This
// layer neither discovers configuration nor reads credentials, files or env.
class SearchAvailability {
    let brave: Bool
    let tavily: Bool
    let searxEndpoint: String
    init(brave!: Bool = false, tavily!: Bool = false, searxEndpoint!: String = "") {
        this.brave = brave; this.tavily = tavily; this.searxEndpoint = searxEndpoint.trimAscii()
    }
}

func searchSchema(): JsonNode {
    let properties = ArrayList<JsonObjectEntry>()
    properties.add(JsonObjectEntry("query", jsonObject([JsonObjectEntry("type", jsonString("string"))])))
    properties.add(JsonObjectEntry("provider", searchEnumSchema(["auto", "none", "brave", "tavily", "searxng"])))
    properties.add(JsonObjectEntry("recency", searchEnumSchema(["day", "week", "month", "year"])))
    for (name in ["limit", "max_tokens", "temperature", "num_search_results"]) {
        properties.add(JsonObjectEntry(name, jsonObject([JsonObjectEntry("type", jsonString("number"))])))
    }
    jsonObject([
        JsonObjectEntry("type", jsonString("object")), JsonObjectEntry("properties", jsonObject(properties.toArray())),
        JsonObjectEntry("required", jsonArray([jsonString("query")])), JsonObjectEntry("additionalProperties", jsonBool(false))
    ])
}

func searchEnumSchema(values: Array<String>): JsonNode {
    let entries = ArrayList<JsonNode>()
    for (value in values) { entries.add(jsonString(value)) }
    jsonObject([JsonObjectEntry("type", jsonString("string")), JsonObjectEntry("enum", jsonArray(entries.toArray()))])
}

func searchText(value: JsonNode, name: String, fallback!: String = ""): String {
    match (value.field(name)) {
        case Some(field) => if (field.unifiedKind == UnifiedJsonKind.Text) { field.text } else { fallback }
        case None => fallback
    }
}

func searchContains(values: Array<String>, expected: String): Bool {
    for (value in values where value == expected) { return true }
    false
}

func searchInteger(value: JsonNode, name: String, fallback: Int64): Int64 {
    match (value.field(name)) {
        case Some(field) => try { Int64.parse(field.asNumberText()) } catch (_: Exception) { fallback }
        case None => fallback
    }
}

func decodeSearchInput(value: JsonNode): SearchInput {
    if (value.unifiedKind != UnifiedJsonKind.Object) {
        throw SearchFailure("tool.web_search_invalid_argument", "web search input must be an object")
    }
    for (entry in value.fields) {
        let text = searchContains(["query", "provider", "recency"], entry.name)
        let number = searchContains(["limit", "max_tokens", "temperature", "num_search_results"], entry.name)
        if ((!text && !number) || (text && entry.value.unifiedKind != UnifiedJsonKind.Text) ||
            (number && entry.value.unifiedKind != UnifiedJsonKind.Number)) {
            throw SearchFailure("tool.web_search_invalid_argument", "unknown or incorrectly typed search argument: " + entry.name)
        }
    }
    let query = searchText(value, "query").trimAscii()
    if (query == "" || query.contains("\u{0000}")) {
        throw SearchFailure("tool.web_search_invalid_argument", "web search query must be non-empty and NUL-free")
    }
    let provider = searchText(value, "provider", fallback: "auto")
    if (!searchContains(["auto", "none", "brave", "tavily", "searxng"], provider)) {
        throw SearchFailure("tool.web_search_invalid_argument", "unsupported web search provider: " + provider)
    }
    let recency = searchText(value, "recency")
    if (recency != "" && !searchContains(["day", "week", "month", "year"], recency)) {
        throw SearchFailure("tool.web_search_invalid_argument", "recency must be day, week, month, or year")
    }
    let limit = searchInteger(value, "num_search_results", searchInteger(value, "limit", 10))
    let maxTokens: ?String = match (value.field("max_tokens")) { case Some(field) => Some(field.asNumberText()); case None => None }
    // temperature remains accepted but unused, matching the existing three
    // provider implementations. Numeric integer parsing preserves old fallback.
    SearchInput(query, provider, recency, min(20, max(1, limit)), maxTokens)
}

func selectSearchProvider(input: SearchInput, available: SearchAvailability): String {
    if (input.provider != "auto") { return input.provider }
    if (available.brave) { return "brave" }
    if (available.tavily) { return "tavily" }
    if (available.searxEndpoint != "") { return "searxng" }
    "none"
}

func searchProviderLabel(provider: String): String {
    match (provider) { case "brave" => "Brave"; case "tavily" => "Tavily"; case "searxng" => "SearXNG"; case _ => "Web search provider" }
}
