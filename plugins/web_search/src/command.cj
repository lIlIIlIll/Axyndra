package web_search_plugin

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// Legacy CLI labels are retained only for an explicit unsupported-provider
// result. They do not claim additional adapters or request network access.
let SEARCH_COMMAND_PROVIDERS = [
    "auto", "perplexity", "gemini", "anthropic", "codex", "xai", "zai", "exa", "tinyfish", "jina", "kagi", "tavily",
    "firecrawl", "brave", "kimi", "parallel", "synthetic", "searxng", "startpage", "duckduckgo", "ecosia", "google", "mojeek", "public"
]

enum SearchCommand { Help | Search(SearchInput, Bool) | Unavailable(String, Bool) }

func searchCommandValue(arguments: Array<String>, name: String): String {
    var next = false
    for (argument in arguments) {
        if (argument == "--") { break }
        if (next) { return argument }
        if (argument == name) { next = true; continue }
        if (argument.startsWith(name + "=")) { return argument[name.size + 1..] }
    }
    ""
}

func searchCommandHas(arguments: Array<String>, name: String): Bool {
    for (argument in arguments) {
        if (argument == "--") { break }
        if (argument == name) { return true }
    }
    false
}

func parseSearchCommand(arguments: Array<String>): SearchCommand {
    if (searchCommandHas(arguments, "--help") || searchCommandHas(arguments, "-h")) { return SearchCommand.Help }
    for (name in ["--provider", "--recency", "--limit", "-l"]) {
        if (searchCommandHas(arguments, name) && searchCommandValue(arguments, name) == "") {
            throw SearchFailure("web_search.command_argument", "Flag " + name + " expects a value")
        }
    }
    let provider = searchCommandValue(arguments, "--provider")
    if (provider != "" && !searchContains(SEARCH_COMMAND_PROVIDERS, provider)) {
        throw SearchFailure("web_search.command_argument", "unsupported --provider value: " + provider)
    }
    let recency = searchCommandValue(arguments, "--recency")
    if (recency != "" && !searchContains(["day", "week", "month", "year"], recency)) {
        throw SearchFailure("web_search.command_argument", "Expected --recency to be one of: day, week, month, year; got \"" + recency + "\"")
    }
    let longLimit = searchCommandValue(arguments, "--limit")
    let limitText = if (longLimit != "") { longLimit } else { searchCommandValue(arguments, "-l") }
    if (limitText != "") {
        let limit = try { Int64.parse(limitText) } catch (_: Exception) {
            throw SearchFailure("web_search.command_argument", "--limit must be a number")
        }
        if (limit < 1) { throw SearchFailure("web_search.command_argument", "--limit must be a positive integer") }
    }
    let queryParts = ArrayList<String>()
    var skip = false
    for (argument in arguments) {
        if (skip) { skip = false; continue }
        if (searchContains(["--provider", "--recency", "--limit", "-l"], argument)) { skip = true; continue }
        if (argument == "--compact" || argument.startsWith("--provider=") ||
            argument.startsWith("--recency=") || argument.startsWith("--limit=")) { continue }
        if (argument.startsWith("-")) { throw SearchFailure("web_search.command_argument", "Nonexistent flag: " + argument) }
        queryParts.add(argument)
    }
    let query = searchJoin(queryParts.toArray(), " ").trimAscii()
    if (query == "") { throw SearchFailure("web_search.command_argument", "Query is required") }
    let compact = searchCommandHas(arguments, "--compact")
    if (provider != "" && provider != "auto" && !searchContains(["brave", "tavily", "searxng"], provider)) {
        return SearchCommand.Unavailable(provider, compact)
    }
    let input = jsonObject([JsonObjectEntry("query", jsonString(query))])
    if (provider != "") { input.put("provider", jsonString(provider)) }
    if (recency != "") { input.put("recency", jsonString(recency)) }
    if (limitText != "") { input.put("limit", jsonNumber(limitText)) }
    SearchCommand.Search(decodeSearchInput(input), compact)
}

func searchJoin(parts: Array<String>, separator: String): String {
    var output = ""
    for (index in 0..parts.size) {
        if (index > 0) { output += separator }
        output += parts[index]
    }
    output
}

func renderSearchCompact(content: String): String {
    let lines = content.split("\n")
    let visible = searchJoin(lines[..min(lines.size, 6)], "\n")
    if (lines.size > 6) { visible + "\n…" } else { visible }
}

func searchCommandHelp(): String {
    "Search through the installed web search plugin\n\nUSAGE\n" +
    "  axyndra tools inspect plugin.axyndra:web-search.web_search\n" +
    "  axyndra tools invoke plugin.axyndra:web-search.web_search '{\"query\":\"Cangjie\",\"provider\":\"auto\",\"limit\":5}'\n\n" +
    "JSON INPUT\n  query: required search text\n  provider: auto, brave, tavily, searxng, or none\n" +
    "  recency: day, week, month, or year\n  limit: result count from 1 to 20\n" +
    "  num_search_results: overrides limit\n  max_tokens: forwarded by Tavily\n  temperature: accepted and unused\n\n" +
    "Install and enable the plugin first, then configure the host's exact HTTP grants and credential references.\n" +
    "This help command is offline; searches use the generic Tool approval and execution path."
}

func searchUnavailableResult(provider: String): JsonNode {
    searchFailureResult(provider, "Search provider \"" + provider + "\" is not available in this axyndra build.")
}
