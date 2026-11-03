package web_search_plugin

import std.collection.*
import yjson.*
import yjson_support.*

class SearchSource {
    let title: String
    let url: String
    let snippet: String
    let publishedDate: String
    init(title: String, url: String, snippet: String, publishedDate: String) {
        this.title = title; this.url = url; this.snippet = snippet; this.publishedDate = publishedDate
    }
}

class SearchResponse {
    let provider: String
    let answer: String
    let sources: Array<SearchSource>
    init(provider: String, answer: String, sources: Array<SearchSource>) {
        this.provider = provider; this.answer = answer; this.sources = sources
    }
}

func searchArray(value: JsonNode, name: String): Array<JsonNode> {
    match (value.field(name)) {
        case Some(array) => if (array.unifiedKind == UnifiedJsonKind.List) { array.items.toArray() } else { [] }
        case None => []
    }
}

func parseSearchResponse(provider: String, root: JsonNode, limit: Int64): SearchResponse {
    let sources = ArrayList<SearchSource>()
    let answer = if (provider == "tavily") { searchText(root, "answer") } else { "" }
    let items: Array<JsonNode> = if (provider == "brave") {
        match (root.field("web")) { case Some(web) => searchArray(web, "results"); case None => [] }
    } else { searchArray(root, "results") }
    for (item in items) {
        if (sources.size >= limit) { break }
        let url = searchText(item, "url")
        if (url == "") { continue }
        let title = searchText(item, "title", fallback: "")
        sources.add(SearchSource(if (title == "") { url } else { title }, url,
            searchText(item, if (provider == "brave") { "description" } else { "content" }),
            searchText(item, if (provider == "tavily") { "published_date" } else { "publishedDate" })))
    }
    SearchResponse(provider, answer, sources.toArray())
}

func decodeSearchResponse(provider: String, body: String, limit: Int64): JsonNode {
    let response = try {
        parseSearchResponse(provider, parseUnifiedJson(body, maxBytes: 16777216), limit)
    } catch (error: Exception) {
        return searchFailureResult(provider, "invalid provider response: " + error.message)
    }
    if (response.answer.trimAscii() == "" && response.sources.isEmpty()) {
        return searchFailureResult(provider, searchProviderLabel(provider) + " returned no renderable search content.")
    }
    renderSearchResponse(response)
}

func renderSearchResponse(response: SearchResponse): JsonNode {
    var content = response.answer.trimAscii()
    if (content != "" && !response.sources.isEmpty()) {
        content += "\n\n## Sources\n" + response.sources.size.toString() + " " +
            if (response.sources.size == 1) { "source" } else { "sources" }
    }
    let sources = ArrayList<JsonNode>()
    for (index in 0..response.sources.size) {
        let source = response.sources[index]
        if (content != "") { content += "\n" }
        content += "[" + (index + 1).toString() + "] " + source.title
        if (source.publishedDate != "") { content += " (" + source.publishedDate + ")" }
        content += "\n    " + source.url
        if (source.snippet != "") { content += "\n    " + searchTruncateUtf8(source.snippet, 240) }
        sources.add(jsonObject([
            JsonObjectEntry("title", jsonString(source.title)), JsonObjectEntry("url", jsonString(source.url)),
            JsonObjectEntry("snippet", jsonString(source.snippet)), JsonObjectEntry("publishedDate", jsonString(source.publishedDate))
        ]))
    }
    jsonObject([
        JsonObjectEntry("content", jsonString(content)), JsonObjectEntry("provider", jsonString(response.provider)),
        JsonObjectEntry("count", jsonNumber(response.sources.size.toString())), JsonObjectEntry("sources", jsonArray(sources.toArray())),
        JsonObjectEntry("error", jsonNull())
    ])
}

func searchFailureResult(provider: String, message: String): JsonNode {
    jsonObject([
        JsonObjectEntry("content", jsonString("Error: " + message)), JsonObjectEntry("provider", jsonString(provider)),
        JsonObjectEntry("count", jsonNumber("0")), JsonObjectEntry("sources", jsonArray([])),
        JsonObjectEntry("error", jsonString(message))
    ])
}

func searchTransportFailure(provider: String, exitCode: Int64, stderr: String): JsonNode {
    searchFailureResult(provider, if (stderr.trimAscii() == "") {
        "provider request failed with exit code " + exitCode.toString()
    } else { stderr.trimAscii() })
}

// Retain the existing 240-byte display budget without splitting a UTF-8 scalar.
// The structured source keeps the complete snippet; this is presentation only.
func searchTruncateUtf8(value: String, limit: Int64): String {
    let bytes = value.toArray()
    if (bytes.size <= limit) { return value }
    var end = max(0, limit)
    while (end > 0 && (bytes[end] & 0xc0u8) == 0x80u8) { end-- }
    String.fromUtf8(bytes[..end]) + "…"
}
