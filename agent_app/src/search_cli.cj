package agent_app

import agent_domain.*
import agent_product.*
import model_adapters.*
import std.collection.*
import std.convert.*

let SEARCH_PROVIDERS = [
    "auto", "perplexity", "gemini", "anthropic", "codex", "xai",
    "zai", "exa", "tinyfish", "jina", "kagi", "tavily",
    "firecrawl", "brave", "kimi", "parallel", "synthetic",
    "searxng", "startpage", "duckduckgo", "ecosia", "google",
    "mojeek", "public"
]

func runSearchCli(
    session: ApplicationSession,
    arguments: Array<String>
): Int64 {
    if (hasArgument(arguments, "--help") ||
        hasArgument(arguments, "-h")) {
        printSearchHelp()
        return 0
    }
    let parseError = searchParseError(arguments)
    if (parseError != "") {
        eprintln("error: " + parseError)
        eprintln("")
        eprintln("USAGE")
        eprintln("  $ axyndra search [QUERY...] [FLAGS]")
        eprintln("")
        eprintln("Run `axyndra search --help` for details.")
        return 1
    }
    let query = joinSearchPositionals(arguments)
    if (query == "") {
        eprintln("Error: Query is required")
        return 1
    }
    let provider = argumentValueOr(arguments, "--provider", "auto")
    let recency = argumentValue(arguments, "--recency")
    let limit = searchLimit(arguments)
    let result = match (session.searchWeb(
        query,
        provider,
        recency,
        limit
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            printError(error)
            return 1
    }
    let content = match (result.output.field("content")) {
        case Some(value) => value.text
        case None => encodeAgentValue(result.output)
    }
    if (hasArgument(arguments, "--compact")) {
        printSearchCompact(content)
    } else {
        println(content)
    }
    match (result.output.field("error")) {
        case Some(value) =>
            if (value.kind != ValueKind.Null) { 1 } else { 0 }
        case None => if (result.isError) { 1 } else { 0 }
    }
}

func searchParseError(arguments: Array<String>): String {
    for (name in ["--provider", "--recency", "--limit", "-l"]) {
        if (hasArgument(arguments, name) &&
            argumentValue(arguments, name) == "") {
            return "Flag " + name + " expects a value"
        }
    }
    let provider = argumentValue(arguments, "--provider")
    if (provider != "" && !containsSearchValue(
        SEARCH_PROVIDERS,
        provider
    )) {
        return "Expected --provider to be one of: " +
            joinSearchValues(SEARCH_PROVIDERS, ", ") +
            "; got \"" + provider + "\""
    }
    let recency = argumentValue(arguments, "--recency")
    if (recency != "" && !containsSearchValue(
        ["day", "week", "month", "year"],
        recency
    )) {
        return "Expected --recency to be one of: day, week, month, year; " +
            "got \"" + recency + "\""
    }
    let authoredLimit = searchLimitText(arguments)
    if (authoredLimit != "") {
        let value = try {
            Int64.parse(authoredLimit)
        } catch (_: Exception) {
            return "--limit must be a number"
        }
        if (value < 1) { return "--limit must be a positive integer" }
    }
    var skipNext = false
    for (argument in arguments) {
        if (skipNext) {
            skipNext = false
            continue
        }
        if (argument == "--provider" ||
            argument == "--recency" ||
            argument == "--limit" ||
            argument == "-l") {
            skipNext = true
            continue
        }
        if (argument == "--compact" ||
            argument == "--help" ||
            argument == "-h" ||
            argument.startsWith("--provider=") ||
            argument.startsWith("--recency=") ||
            argument.startsWith("--limit=")) {
            continue
        }
        if (argument.startsWith("-")) {
            return "Nonexistent flag: " + argument
        }
    }
    ""
}

func searchLimit(arguments: Array<String>): ?Int64 {
    let value = searchLimitText(arguments)
    if (value == "") { return None }
    try {
        Some(Int64.parse(value))
    } catch (_: Exception) {
        None
    }
}

func searchLimitText(arguments: Array<String>): String {
    let long = argumentValue(arguments, "--limit")
    if (long != "") { return long }
    argumentValue(arguments, "-l")
}

func joinSearchPositionals(arguments: Array<String>): String {
    let values = ArrayList<String>()
    var skipNext = false
    for (argument in arguments) {
        if (skipNext) {
            skipNext = false
            continue
        }
        if (argument == "--provider" ||
            argument == "--recency" ||
            argument == "--limit" ||
            argument == "-l") {
            skipNext = true
            continue
        }
        if (argument == "--compact" ||
            argument == "--help" ||
            argument == "-h" ||
            argument.startsWith("--provider=") ||
            argument.startsWith("--recency=") ||
            argument.startsWith("--limit=")) {
            continue
        }
        if (!argument.startsWith("-")) { values.add(argument) }
    }
    joinSearchValues(values.toArray(), " ")
}

func printSearchCompact(content: String): Unit {
    let lines = content.split("\n")
    let count = min(lines.size, 6)
    for (index in 0..count) { println(lines[index]) }
    if (lines.size > count) { println("…") }
}

func containsSearchValue(
    values: Array<String>,
    expected: String
): Bool {
    for (value in values where value == expected) { return true }
    false
}

func joinSearchValues(
    values: Array<String>,
    separator: String
): String {
    var result = ""
    for (value in values) {
        if (result != "") { result += separator }
        result += value
    }
    result
}

func printSearchHelp(): Unit {
    println("Test web search providers")
    println()
    println("USAGE")
    println("  $ axyndra search [QUERY...] [FLAGS]")
    println()
    println("ARGUMENTS")
    println("  QUERY   Search query text")
    println()
    println("FLAGS")
    println("      --provider=<value>  Search provider")
    println("      --recency=<value>   Recency filter")
    println("  -l, --limit=<int>       Max results to return")
    println("      --compact           Render condensed output")
}
