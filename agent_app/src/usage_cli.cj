package agent_app

import agent_domain.*
import agent_product.*
import model_adapters.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.time.*

let USAGE_DAY_MILLIS: Int64 = 86400000

func runUsageCli(
    session: ApplicationSession,
    arguments: Array<String>
): Int64 {
    if (hasArgument(arguments, "--help") ||
        hasArgument(arguments, "-h")) {
        printUsageHelp()
        return 0
    }
    let parseError = usageParseError(arguments)
    if (parseError != "") {
        eprintln("error: " + parseError)
        eprintln("")
        eprintln("USAGE")
        eprintln("  $ axyndra usage [ACTION] [FLAGS]")
        eprintln("")
        eprintln("Run `axyndra usage --help` for details.")
        return 2
    }
    let action = usageAction(arguments)
    let provider = usageProvider(arguments).toAsciiLower()
    if (action == "invalidate") {
        return invalidateUsage(session, provider)
    }
    if (hasArgument(arguments, "--history")) {
        return usageHistory(
            session,
            provider,
            usageDays(arguments),
            hasArgument(arguments, "--json") ||
                hasArgument(arguments, "-j")
        )
    }
    usageSnapshot(
        session,
        provider,
        hasArgument(arguments, "--json") ||
            hasArgument(arguments, "-j")
    )
}

func usageSnapshot(
    session: ApplicationSession,
    provider: String,
    json: Bool
): Int64 {
    let accounts = usageAccounts(session, provider)
    if (json) {
        let accountValues = ArrayList<AgentValue>()
        // OMP suppresses providers without a quota endpoint unless the
        // provider was explicitly requested. axyndra currently configures
        // DeepSeek/OpenAI-compatible API-key profiles, which have no
        // provider usage-limit endpoint.
        if (provider != "") {
            for (account in accounts) {
                accountValues.add(objectValue([
                    ValueField(
                        "provider",
                        textValue(account.provider)
                    ),
                    ValueField("type", textValue("api_key"))
                ]))
            }
        }
        println(encodeAgentValue(objectValue([
            ValueField(
                "generatedAt",
                integerValue(usageNowMillis())
            ),
            ValueField("reports", listValue([])),
            ValueField(
                "accountsWithoutUsage",
                listValue(accountValues.toArray())
            ),
            ValueField(
                "disabledCredentials",
                listValue([])
            ),
            ValueField("capacity", objectValue([]))
        ])))
        return 0
    }
    if (accounts.isEmpty()) {
        let scope = if (provider == "") {
            ""
        } else {
            " for provider \"" + provider + "\""
        }
        eprintln(
            "No credentials found" + scope +
                ". Run `axyndra` and use /login to add accounts."
        )
        return 1
    }
    let scope = if (provider == "") {
        ""
    } else {
        " for provider \"" + provider + "\""
    }
    eprintln(
        "No usage data" + scope +
            ". Stored credentials are for providers without a usage endpoint."
    )
    1
}

func usageHistory(
    session: ApplicationSession,
    provider: String,
    days: Int64,
    json: Bool
): Int64 {
    let generatedAt = usageNowMillis()
    let since = generatedAt - days * USAGE_DAY_MILLIS
    let entries = loadUsageHistory(session.stateRoot(), provider, since)
    if (json) {
        println(encodeAgentValue(objectValue([
            ValueField(
                "generatedAt",
                integerValue(generatedAt)
            ),
            ValueField("sinceMs", integerValue(since)),
            ValueField("entries", listValue(entries))
        ])))
        return 0
    }
    if (entries.isEmpty()) {
        let scope = if (provider == "") {
            ""
        } else {
            " for provider \"" + provider + "\""
        }
        eprintln(
            "No usage history recorded" + scope +
                " yet. Snapshots accumulate whenever usage is fetched " +
                "(TUI footer, /usage, axyndra usage)."
        )
        return 1
    }
    println(
        "Usage history · last " + days.toString() + " days · " +
            entries.size.toString() + " snapshots"
    )
    for (entry in entries) {
        println(encodeAgentValue(entry))
    }
    0
}

func invalidateUsage(
    session: ApplicationSession,
    provider: String
): Int64 {
    let root = session.stateRoot() + "/usage-cache"
    try {
        if (provider == "") {
            let _ = removeIfExists(root, recursive: true)
            println(
                "Invalidated cached usage reports for all providers."
            )
        } else {
            if (usageSafeProvider(provider)) {
                let _ = removeIfExists(root + "/" + provider + ".json")
            }
            println(
                "Invalidated cached usage reports for provider \"" +
                    provider + "\"."
            )
        }
        0
    } catch (error: Exception) {
        eprintln("Error: cannot invalidate usage cache: " + error.message)
        1
    }
}

class UsageAccount {
    let provider: String
    let profile: String

    init(provider: String, profile: String) {
        this.provider = provider
        this.profile = profile
    }
}

func usageAccounts(
    session: ApplicationSession,
    provider: String
): ArrayList<UsageAccount> {
    let values = ArrayList<UsageAccount>()
    for (profile in session.providers()) {
        if (provider != "" &&
            profile.provider.toAsciiLower() != provider &&
            profile.id.toAsciiLower() != provider) {
            continue
        }
        if (!session.providerAuthenticated(profile.id)) { continue }
        values.add(UsageAccount(profile.provider, profile.id))
    }
    values
}

func loadUsageHistory(
    stateRoot: String,
    provider: String,
    since: Int64
): Array<AgentValue> {
    let path = stateRoot + "/usage-history.jsonl"
    if (!exists(Path(path))) { return [] }
    let values = ArrayList<AgentValue>()
    try {
        let source = String.fromUtf8(File.readFrom(path))
        for (line in source.split("\n")
             where line.trimAscii() != "") {
            let value = match (decodeAgentValue(
                line,
                maxBytes: 1048576
            )) {
                case Result.Ok(item) => item
                case Result.Err(_) => continue
            }
            let timestamp = usageIntegerOr(value, "timestamp")
            if (timestamp < since) { continue }
            if (provider != "" &&
                usageTextOr(value, "provider").toAsciiLower() !=
                    provider) {
                continue
            }
            values.add(value)
        }
    } catch (_: Exception) {
        return []
    }
    values.toArray()
}

func usageParseError(arguments: Array<String>): String {
    for (name in ["--provider", "-p", "--days", "-d"]) {
        if (hasArgument(arguments, name) &&
            argumentValue(arguments, name) == "") {
            return "Flag " + name + " expects a value"
        }
    }
    let days = usageDaysText(arguments)
    if (days != "") {
        try {
            let _ = Int64.parse(days)
        } catch (_: Exception) {
            return "Expected --days to be an integer; got \"" +
                days + "\""
        }
    }
    let action = usageAction(arguments)
    if (action != "" && action != "invalidate") {
        return "Expected action to be: invalidate; got \"" +
            action + "\""
    }
    var skipNext = false
    var sawAction = false
    for (argument in arguments) {
        if (skipNext) {
            skipNext = false
            continue
        }
        if (argument == "--provider" ||
            argument == "-p" ||
            argument == "--days" ||
            argument == "-d") {
            skipNext = true
            continue
        }
        if (argument == "--json" ||
            argument == "-j" ||
            argument == "--redact" ||
            argument == "-r" ||
            argument == "--history" ||
            argument == "--help" ||
            argument == "-h" ||
            argument.startsWith("--provider=") ||
            argument.startsWith("--days=")) {
            continue
        }
        if (argument.startsWith("-")) {
            return "Nonexistent flag: " + argument
        }
        if (!sawAction) {
            sawAction = true
        } else {
            return "Unexpected argument: " + argument
        }
    }
    ""
}

func usageAction(arguments: Array<String>): String {
    var skipNext = false
    for (argument in arguments) {
        if (skipNext) {
            skipNext = false
            continue
        }
        if (argument == "--provider" ||
            argument == "-p" ||
            argument == "--days" ||
            argument == "-d") {
            skipNext = true
            continue
        }
        if (argument.startsWith("-")) { continue }
        return argument
    }
    ""
}

func usageProvider(arguments: Array<String>): String {
    let long = argumentValue(arguments, "--provider")
    if (long != "") { return long }
    argumentValue(arguments, "-p")
}

func usageDaysText(arguments: Array<String>): String {
    let long = argumentValue(arguments, "--days")
    if (long != "") { return long }
    argumentValue(arguments, "-d")
}

func usageDays(arguments: Array<String>): Int64 {
    let value = usageDaysText(arguments)
    if (value == "") { return 7 }
    let parsed = try {
        Int64.parse(value)
    } catch (_: Exception) {
        return 7
    }
    if (parsed > 0) { parsed } else { 7 }
}

func usageSafeProvider(value: String): Bool {
    if (value == "") { return false }
    for (rune in value.runes()) {
        let allowed =
            (rune >= r'a' && rune <= r'z') ||
            (rune >= r'0' && rune <= r'9') ||
            rune == r'-' || rune == r'_'
        if (!allowed) { return false }
    }
    true
}

func usageTextOr(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) =>
            if (item.kind == ValueKind.Text) { item.text } else { "" }
        case None => ""
    }
}

func usageIntegerOr(value: AgentValue, name: String): Int64 {
    match (value.field(name)) {
        case Some(item) =>
            if (item.kind == ValueKind.Number) {
                try {
                    Int64.parse(item.number)
                } catch (_: Exception) {
                    0
                }
            } else {
                0
            }
        case None => 0
    }
}

func usageNowMillis(): Int64 {
    DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
}

func printUsageHelp(): Unit {
    println(
        "Show provider usage limits for every authenticated account"
    )
    println()
    println("USAGE")
    println("  $ axyndra usage [ACTION] [FLAGS]")
    println()
    println("ARGUMENTS")
    println("  ACTION   Optional subcommand to execute (invalidate)")
    println()
    println("FLAGS")
    println(
        "  -j, --json              Output usage reports as JSON"
    )
    println(
        "  -p, --provider=<value>  Only show usage for this " +
            "provider id (e.g. anthropic)"
    )
    println(
        "  -r, --redact            Redact account emails/ids " +
            "for sharing screenshots"
    )
    println(
        "      --history           Show recorded usage-limit " +
            "history instead of a live snapshot"
    )
    println(
        "  -d, --days=<int>        History window in days " +
            "(with --history)"
    )
}
