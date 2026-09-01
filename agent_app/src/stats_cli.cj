package agent_app

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_product.*
import model_adapters.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.process.*

func runStatsCli(
    session: ApplicationSession,
    arguments: Array<String>
): Int64 {
    if (hasArgument(arguments, "--help") ||
        hasArgument(arguments, "-h")) {
        printStatsHelp()
        return 0
    }
    match (statsParseError(arguments)) {
        case Some(message) =>
            eprintln("error: " + message)
            eprintln("")
            eprintln("USAGE")
            eprintln("  $ axyndra stats [FLAGS]")
            eprintln("")
            eprintln("Run `axyndra stats --help` for details.")
            return 2
        case None => ()
    }
    eprintln("Syncing session files...")
    let stats = match (session.dashboardStats()) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            printError(error)
            return 1
    }
    println(
        "Synced 0 new entries from " + stats.files.toString() +
            " files (" + stats.overall.totalRequests.toString() +
            " total)"
    )
    println("")
    if (hasArgument(arguments, "--json") ||
        hasArgument(arguments, "-j")) {
        println(encodeAgentValue(statsValue(stats)))
        return 0
    }
    if (hasArgument(arguments, "--summary") ||
        hasArgument(arguments, "-s")) {
        printStatsSummary(stats.overall)
        return 0
    }
    runStatsDashboard(
        session,
        stats,
        statsPort(arguments)
    )
}

func printStatsHelp(): Unit {
    println(
        "View usage statistics\n\n" +
        "USAGE\n" +
        "  $ axyndra stats [FLAGS]\n\n" +
        "FLAGS\n" +
        "  -p, --port=<int>  Port for the dashboard server\n" +
        "  -j, --json        Output stats as JSON\n" +
        "  -s, --summary     Print summary to console"
    )
}

func statsParseError(arguments: Array<String>): ?String {
    let authoredPort = statsPortText(arguments)
    if ((hasArgument(arguments, "--port") ||
        hasArgument(arguments, "-p")) && authoredPort == "") {
        return Some("Flag --port expects a value")
    }
    if (authoredPort != "") {
        let port = try {
            Int64.parse(authoredPort)
        } catch (_: Exception) {
            return Some(
                "Expected --port to be an integer; got \"" +
                    authoredPort + "\""
            )
        }
        if (port < 1 || port > 65535) {
            return Some(
                "Expected --port to be between 1 and 65535; got \"" +
                    authoredPort + "\""
            )
        }
    }
    var skipNext = false
    for (argument in arguments) {
        if (skipNext) {
            skipNext = false
            continue
        }
        if (argument == "--port" || argument == "-p") {
            skipNext = true
            continue
        }
        if (argument == "--json" || argument == "-j" ||
            argument == "--summary" || argument == "-s" ||
            argument == "--help" || argument == "-h" ||
            argument.startsWith("--port=") ||
            argument.startsWith("-p=")) {
            continue
        }
        if (argument.startsWith("-")) {
            return Some("Nonexistent flag: " + argument)
        }
        return Some("Unexpected argument: " + argument)
    }
    None
}

func statsPortText(arguments: Array<String>): String {
    let longValue = argumentValue(arguments, "--port")
    if (longValue != "") { return longValue }
    argumentValue(arguments, "-p")
}

func statsPort(arguments: Array<String>): Int64 {
    let authored = statsPortText(arguments)
    if (authored == "") { return 3847 }
    try {
        Int64.parse(authored)
    } catch (_: Exception) {
        3847
    }
}

func statsValue(stats: ProductDashboardStats): AgentValue {
    let sessions = ArrayList<AgentValue>()
    for (value in stats.bySession) {
        sessions.add(objectValue([
            ValueField("sessionId", textValue(value.sessionId)),
            ValueField("model", textValue(value.model)),
            ValueField("provider", textValue(value.provider)),
            ValueField("usage", statsUsageValue(value.usage))
        ]))
    }
    let providers = ArrayList<AgentValue>()
    for (value in stats.byProvider) {
        providers.add(objectValue([
            ValueField("provider", textValue(value.provider)),
            ValueField("sessions", integerValue(value.sessions)),
            ValueField("usage", statsUsageValue(value.usage))
        ]))
    }
    objectValue([
        ValueField("overall", statsUsageValue(stats.overall)),
        ValueField("byTurn", statsRunsValue(stats.byTurn)),
        ValueField("byRun", statsRunsValue(stats.byRun)),
        ValueField("bySession", listValue(sessions.toArray())),
        ValueField("byProvider", listValue(providers.toArray())),
        ValueField("files", integerValue(stats.files))
    ])
}

func statsRunsValue(values: Array<ProductRunStats>): AgentValue {
    let items = ArrayList<AgentValue>()
    for (value in values) {
        items.add(objectValue([
            ValueField("turnId", textValue(value.turnId)),
            ValueField("runId", textValue(value.runId)),
            ValueField("sessionId", textValue(value.sessionId)),
            ValueField("model", textValue(value.model)),
            ValueField("provider", textValue(value.provider)),
            ValueField("kind", textValue(value.kind)),
            ValueField("status", textValue(value.status)),
            ValueField("archived", boolValue(value.archived)),
            ValueField("timestamp", integerValue(value.timestamp)),
            ValueField("usage", statsUsageValue(value.usage))
        ]))
    }
    listValue(items.toArray())
}

func statsUsageValue(value: ProductStatsOverall): AgentValue {
    objectValue([
        ValueField("totalRequests", integerValue(value.totalRequests)),
        ValueField("successfulRequests", integerValue(value.successfulRequests)),
        ValueField("failedRequests", integerValue(value.failedRequests)),
        ValueField("cancelledRequests", integerValue(value.cancelledRequests)),
        ValueField("errorRate", numberValue(value.errorRate.toString())),
        ValueField("cancellationRate", numberValue(value.cancellationRate.toString())),
        ValueField("totalInputTokens", integerValue(value.totalInputTokens)),
        ValueField("totalOutputTokens", integerValue(value.totalOutputTokens)),
        ValueField("totalReasoningTokens", integerValue(value.totalReasoningTokens)),
        ValueField("totalCacheReadTokens", integerValue(value.totalCacheReadTokens)),
        ValueField("totalCacheWriteTokens", integerValue(value.totalCacheWriteTokens)),
        ValueField("cacheRate", numberValue(value.cacheRate.toString())),
        ValueField("totalCostMicros", match (value.totalCostMicros) {
            case Some(cost) => integerValue(cost)
            case None => nullValue()
        }),
        ValueField("totalCostKnown", boolValue(value.totalCostKnown)),
        ValueField("totalCost", if (value.totalCostKnown) {
            numberValue(value.totalCost.toString())
        } else if (value.totalRequests == 0) {
            // The sum of an empty request set is known to be zero; null means
            // that at least one real provider request lacks price data.
            numberValue("0")
        } else {
            nullValue()
        }),
        ValueField("totalRuns", integerValue(value.totalRuns)),
        ValueField("totalTurns", integerValue(value.totalTurns)),
        ValueField("totalToolCalls", integerValue(value.totalToolCalls)),
        ValueField("firstTimestamp", integerValue(value.firstTimestamp)),
        ValueField("lastTimestamp", integerValue(value.lastTimestamp))
    ])
}

func printStatsSummary(overall: ProductStatsOverall): Unit {
    println("=== AI Usage Statistics ===")
    println("Overall:")
    println(
        "  Requests: " + overall.totalRequests.toString() +
            " (" + overall.failedRequests.toString() + " errors)"
    )
    println(
        "  Error Rate: " + statsPercent(
            overall.failedRequests,
            overall.totalRequests
        )
    )
    println(
        "  Total Tokens: " +
            (overall.totalInputTokens +
                overall.totalOutputTokens).toString()
    )
    println("  Input Tokens: " + overall.totalInputTokens.toString())
    println("  Output Tokens: " + overall.totalOutputTokens.toString())
    println(
        "  Cache Rate: " + statsPercent(
            overall.totalCacheReadTokens,
            overall.totalInputTokens
        )
    )
    println("  Total Cost: " + if (overall.totalCostKnown) {
        "$" + statsCost(overall.totalCost)
    } else if (overall.totalRequests == 0) {
        "$0.0000"
    } else {
        "unknown"
    })
    println(
        "  Premium Requests: " +
            statsWholeNumber(overall.totalPremiumRequests)
    )
    println("  Avg Duration: -")
    println("  Avg TTFT: -")
}

func statsPercent(numerator: Int64, denominator: Int64): String {
    if (denominator <= 0) { return "0.0%" }
    let tenths = (numerator * 1000 + denominator / 2) /
        denominator
    (tenths / 10).toString() + "." +
        (tenths % 10).toString() + "%"
}

func statsCost(value: Float64): String {
    let scaled = Int64(value * 10000.0 + 0.5)
    let fraction = (scaled % 10000).toString()
    var padding = ""
    var index = fraction.size
    while (index < 4) {
        padding += "0"
        index++
    }
    (scaled / 10000).toString() + "." + padding + fraction
}

func statsWholeNumber(value: Float64): String {
    Int64(value).toString()
}

func runStatsDashboard(
    session: ApplicationSession,
    stats: ProductDashboardStats,
    port: Int64
): Int64 {
    let root = session.stateRoot() + "/stats-dashboard"
    try {
        if (!exists(Path(root))) {
            Directory.create(root, recursive: true)
        }
        let json = encodeAgentValue(statsValue(stats))
        File.writeTo(
            root + "/index.html",
            statsDashboardHtml(json).toArray()
        )
        let server = launch(
            "/usr/bin/python3",
            [
                "-m", "http.server", port.toString(),
                "--bind", "127.0.0.1",
                "--directory", root
            ],
            stdOut: ProcessRedirect.Discard,
            stdErr: ProcessRedirect.Inherit
        )
        atExit({ =>
            try {
                findProcess(server.pid).terminate(force: true)
            } catch (_: Exception) {}
        })
        let url = "http://127.0.0.1:" + port.toString() + "/"
        println("Stats dashboard running at " + url)
        println("Press Ctrl+C to stop.")
        try {
            let opener = launch(
                "/usr/bin/xdg-open",
                [url],
                stdOut: ProcessRedirect.Discard,
                stdErr: ProcessRedirect.Discard
            )
            let _ = opener.wait()
        } catch (_: Exception) {}
        server.wait()
    } catch (error: Exception) {
        eprintln("error: failed to start stats dashboard: " + error.message)
        1
    }
}

func statsDashboardHtml(json: String): String {
    "<!doctype html><html><head><meta charset=\"utf-8\">" +
        "<meta name=\"viewport\" content=\"width=device-width\">" +
        "<title>axyndra statistics</title><style>" +
        "body{font:15px ui-monospace,monospace;background:#101418;" +
        "color:#e6edf3;margin:0;padding:2rem}" +
        "main{max-width:960px;margin:auto}" +
        "pre{white-space:pre-wrap;background:#161b22;padding:1.25rem;" +
        "border-radius:10px;overflow:auto}</style></head><body><main>" +
        "<h1>AI Usage Statistics</h1><pre id=\"stats\">" +
        statsHtmlEscape(json) +
        "</pre></main></body></html>"
}

func statsHtmlEscape(value: String): String {
    value
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
}
