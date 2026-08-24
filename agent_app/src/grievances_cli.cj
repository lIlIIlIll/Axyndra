package agent_app

import agent_domain.*
import agent_product.*
import model_adapters.*
import std.collection.*
import std.convert.*

func runGrievancesCli(
    session: ApplicationSession,
    arguments: Array<String>
): Int64 {
    if (hasArgument(arguments, "--help") ||
        hasArgument(arguments, "-h")) {
        printGrievancesHelp()
        return 0
    }
    let action = grievanceAction(arguments)
    if (action != "list" && action != "clean" && action != "push") {
        eprintln(
            "error: Expected ACTION to be one of: list, clean, push; " +
                "got " + action
        )
        return 2
    }
    match (grievanceUnknownFlag(arguments)) {
        case Some(flag) =>
            eprintln("error: Nonexistent flag: " + flag)
            return 2
        case None => ()
    }
    let json = hasArgument(arguments, "--json") ||
        hasArgument(arguments, "-j")
    if (action == "list") {
        let limit = match (grievancePositiveInteger(
            grievanceOption(arguments, "--limit", "-n"),
            "--limit",
            20
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                eprintln("error: " + error.message)
                return 2
        }
        let tool = grievanceOption(arguments, "--tool", "-t")
        return printGrievanceList(session, limit, tool, json)
    }
    if (action == "clean") {
        return cleanGrievanceCli(session, arguments, json)
    }
    pushGrievanceCli(session, json)
}

func printGrievancesHelp(): Unit {
    println(
        "View, clean, or push reported tool issues (auto-QA grievances)\n\n" +
        "USAGE\n" +
        "  $ axyndra grievances [ACTION] [FLAGS]\n\n" +
        "ARGUMENTS\n" +
        "  ACTION   list (default), clean, or push (list|clean|push)\n\n" +
        "FLAGS\n" +
        "  -n, --limit=<int>   Number of recent issues to show (list)\n" +
        "  -t, --tool=<value>  Filter by tool name (list, clean)\n" +
        "  -j, --json          Output as JSON\n" +
        "      --id=<int>      Delete a single grievance by id (clean)\n" +
        "      --all           Delete every grievance (clean)"
    )
}

func printGrievanceList(
    session: ApplicationSession,
    limit: Int64,
    tool: String,
    json: Bool
): Int64 {
    match (session.listGrievances(limit, tool)) {
        case Result.Err(error) =>
            printError(error)
            1
        case Result.Ok(result) =>
            if (json) {
                let values = ArrayList<AgentValue>()
                for (row in result.rows) {
                    values.add(grievanceCliValue(row))
                }
                println(encodeAgentValue(listValue(values.toArray())))
                return 0
            }
            if (!result.databaseFound) {
                println(
                    "No grievances database found. Auto-QA has not " +
                        "recorded any reports yet (or was disabled)."
                )
                return 0
            }
            if (result.rows.isEmpty()) {
                println("No grievances recorded yet.")
                return 0
            }
            for (row in result.rows) {
                println(
                    "#" + row.id.toString() + " " + row.tool +
                        " (" + row.model + " v" + row.version + ")"
                )
                println("  " + row.report)
                println()
            }
            println(
                "Showing " + result.rows.size.toString() +
                    " most recent" +
                    if (tool == "") { "" } else { " for " + tool }
            )
            0
    }
}

func cleanGrievanceCli(
    session: ApplicationSession,
    arguments: Array<String>,
    json: Bool
): Int64 {
    let idText = grievanceOption(arguments, "--id", "")
    let tool = grievanceOption(arguments, "--tool", "-t")
    let all = hasArgument(arguments, "--all")
    let selectors = (if (idText == "") { 0 } else { 1 }) +
        (if (tool == "") { 0 } else { 1 }) +
        (if (all) { 1 } else { 0 })
    if (selectors == 0) {
        eprintln("Specify exactly one of --id, --tool, or --all.")
        return 1
    }
    if (selectors > 1) {
        eprintln("--id, --tool, and --all are mutually exclusive.")
        return 1
    }
    let id: ?Int64 = if (idText == "") {
        None
    } else {
        match (grievancePositiveInteger(idText, "--id", 0)) {
            case Result.Ok(value) => Some(value)
            case Result.Err(error) =>
                eprintln("error: " + error.message)
                return 2
        }
    }
    match (session.cleanGrievances(id, tool, all)) {
        case Result.Err(error) =>
            printError(error)
            1
        case Result.Ok(result) =>
            if (json) {
                println(encodeAgentValue(objectValue([
                    ValueField("deleted", integerValue(result.deleted))
                ])))
            } else if (!result.databaseFound) {
                println(
                    "No grievances database found. Auto-QA has not " +
                        "recorded any reports yet (or was disabled)."
                )
            } else if (result.deleted == 0) {
                println("No matching grievances to delete.")
            } else {
                let scope = match (id) {
                    case Some(value) => "#" + value.toString()
                    case None =>
                        if (tool == "") {
                            "(all entries)"
                        } else {
                            "for " + tool
                        }
                }
                println(
                    "Deleted " + result.deleted.toString() +
                        " grievance" +
                        if (result.deleted == 1) { "" } else { "s" } +
                        " " + scope + "."
                )
            }
            0
    }
}

func pushGrievanceCli(
    session: ApplicationSession,
    json: Bool
): Int64 {
    match (session.listGrievances(1, "")) {
        case Result.Err(error) =>
            printError(error)
            1
        case Result.Ok(result) =>
            if (!result.databaseFound) {
                if (json) {
                    println(encodeAgentValue(objectValue([
                        ValueField("pushed", integerValue(0)),
                        ValueField("ok", boolValue(true))
                    ])))
                } else {
                    println(
                        "No grievances database found — nothing to push."
                    )
                }
                return 0
            }
            eprintln(
                "Push skipped — axyndra has no configured grievance " +
                    "endpoint."
            )
            1
    }
}

func grievanceCliValue(row: ProductGrievance): AgentValue {
    objectValue([
        ValueField("id", integerValue(row.id)),
        ValueField("model", textValue(row.model)),
        ValueField("version", textValue(row.version)),
        ValueField("tool", textValue(row.tool)),
        ValueField("report", textValue(row.report))
    ])
}

func grievanceAction(arguments: Array<String>): String {
    var skipNext = false
    for (argument in arguments) {
        if (skipNext) {
            skipNext = false
            continue
        }
        if (argument == "--limit" || argument == "-n" ||
            argument == "--tool" || argument == "-t" ||
            argument == "--id") {
            skipNext = true
            continue
        }
        if (!argument.startsWith("-")) { return argument }
    }
    "list"
}

func grievanceOption(
    arguments: Array<String>,
    longName: String,
    shortName: String
): String {
    let longValue = argumentValue(arguments, longName)
    if (longValue != "") { return longValue }
    if (shortName == "") { return "" }
    argumentValue(arguments, shortName)
}

func grievancePositiveInteger(
    authored: String,
    name: String,
    fallback: Int64
): Result<Int64> {
    if (authored == "") { return Result.Ok(fallback) }
    let value = try {
        Int64.parse(authored)
    } catch (_: Exception) {
        return Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "grievances.invalid_integer",
            "Expected " + name + " to be an integer; got \"" +
                authored + "\""
        ))
    }
    if (value < 1) {
        return Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "grievances.invalid_integer",
            "Expected " + name + " to be at least 1; got \"" +
                authored + "\""
        ))
    }
    Result.Ok(value)
}

func grievanceUnknownFlag(arguments: Array<String>): ?String {
    var skipNext = false
    for (argument in arguments) {
        if (skipNext) {
            skipNext = false
            continue
        }
        if (argument == "--limit" || argument == "-n" ||
            argument == "--tool" || argument == "-t" ||
            argument == "--id") {
            skipNext = true
            continue
        }
        if (argument == "--json" || argument == "-j" ||
            argument == "--all" ||
            argument.startsWith("--limit=") ||
            argument.startsWith("--tool=") ||
            argument.startsWith("--id=")) {
            continue
        }
        if (argument.startsWith("-")) { return Some(argument) }
    }
    None
}
