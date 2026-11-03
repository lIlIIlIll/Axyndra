package agent_app

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_product.*
import std.collection.*
import std.fs.*

func runWorktreeCli(
    session: ApplicationSession,
    arguments: Array<String>
, io!: CliIo180 = consoleCliIo180): Int64 {
    if (hasArgument(arguments, "--help") ||
        hasArgument(arguments, "-h")) {
        printWorktreeHelp(io: io)
        return 0
    }
    let unknown = worktreeUnknownOption(arguments)
    if (unknown != "") {
        io.println("error: Nonexistent flag: " + unknown)
        io.println()
        io.println("Run `axyndra worktree --help` for details.")
        return 2
    }
    let positionals = worktreePositionals(arguments)
    if (positionals.size > 1 ||
        (!positionals.isEmpty() &&
            positionals[0] != "list" &&
            positionals[0] != "clear")) {
        let authored = if (positionals.isEmpty()) {
            ""
        } else {
            positionals[0]
        }
        io.println(
            "error: Expected action to be one of: list, clear; got \"" +
                authored + "\""
        )
        io.println()
        io.println("USAGE")
        io.println("  $ axyndra worktree [ACTION] [FLAGS]")
        io.println()
        io.println("Run `axyndra worktree --help` for details.")
        return 1
    }
    let action = if (positionals.isEmpty()) {
        "list"
    } else {
        positionals[0]
    }
    let json = hasArgument(arguments, "--json") ||
        hasArgument(arguments, "-j")
    if (action == "clear") {
        return clearWorktrees(
            session,
            hasArgument(arguments, "--all"),
            hasArgument(arguments, "--dry-run") ||
                hasArgument(arguments, "-n"),
            json
        , io: io)
    }
    listWorktrees(session, json, io: io)
}

func listWorktrees(
    session: ApplicationSession,
    json: Bool
, io!: CliIo180 = consoleCliIo180): Int64 {
    let entries = match (session.managedWorktrees()) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            printError(error, io: io)
            return 1
    }
    if (json) {
        let values = ArrayList<AgentValue>()
        for (entry in entries) {
            values.add(worktreeEntryValue(entry))
        }
        io.println(encodeAgentValue(listValue(values.toArray())))
        return 0
    }
    if (entries.isEmpty()) {
        io.println(
            "No agent-managed worktrees found under " +
                Path(session.configRoot()).join("wt").toString() + "."
        )
        return 0
    }
    var live: Int64 = 0
    var orphaned: Int64 = 0
    for (entry in entries) {
        if (entry.orphanReason == "") {
            live++
            io.println("live      " + entry.path)
        } else {
            orphaned++
            io.println("orphaned  " + entry.path)
        }
        let detail = worktreeEntryDetail(entry)
        if (detail != "") { io.println("          " + detail) }
    }
    io.println()
    io.println(
        live.toString() + " live · " +
            orphaned.toString() + " orphaned · " +
            entries.size.toString() + " total"
    )
    0
}

func clearWorktrees(
    session: ApplicationSession,
    all: Bool,
    dryRun: Bool,
    json: Bool
, io!: CliIo180 = consoleCliIo180): Int64 {
    let result = match (session.clearManagedWorktrees(all, dryRun)) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            printError(error, io: io)
            return 1
    }
    if (dryRun) {
        if (json) {
            io.println(encodeAgentValue(objectValue([
                ValueField(
                    "wouldRemove",
                    cliStringList(result.wouldRemove)
                )
            ])))
            return 0
        }
        if (result.wouldRemove.isEmpty()) {
            io.println(
                if (all) {
                    "No worktrees to remove."
                } else {
                    "No orphaned worktrees to remove."
                }
            )
            return 0
        }
        for (path in result.wouldRemove) {
            io.println("would remove  " + path)
        }
        io.println()
        io.println(
            result.wouldRemove.size.toString() + " dir" +
                if (result.wouldRemove.size == 1) {
                    " would be removed."
                } else {
                    "s would be removed."
                }
        )
        return 0
    }
    let removed = result.removed()
    let failed = result.failed()
    if (json) {
        if (result.results.isEmpty()) {
            io.println(encodeAgentValue(objectValue([
                ValueField("removed", integerValue(0)),
                ValueField("kept", integerValue(result.kept))
            ])))
        } else {
            let values = ArrayList<AgentValue>()
            for (entry in result.results) {
                let fields = ArrayList<ValueField>()
                fields.add(ValueField("path", textValue(entry.path)))
                fields.add(ValueField("ok", boolValue(entry.ok)))
                if (entry.error != "") {
                    fields.add(ValueField(
                        "error",
                        textValue(entry.error)
                    ))
                }
                values.add(objectValue(fields.toArray()))
            }
            io.println(encodeAgentValue(objectValue([
                ValueField("removed", integerValue(removed)),
                ValueField("failed", integerValue(failed)),
                ValueField("results", listValue(values.toArray()))
            ])))
        }
        return if (failed > 0) { 1 } else { 0 }
    }
    if (result.results.isEmpty()) {
        io.println(
            if (all) {
                "No worktrees to remove."
            } else {
                "No orphaned worktrees to remove."
            }
        )
        return 0
    }
    for (entry in result.results) {
        if (entry.ok) {
            io.println("removed  " + entry.path)
        } else {
            io.println("failed   " + entry.path)
            if (entry.error != "") {
                io.println("          " + entry.error)
            }
        }
    }
    io.println()
    io.println(
        removed.toString() + " removed" +
            if (failed > 0) {
                " · " + failed.toString() + " failed"
            } else {
                ""
            }
    )
    if (failed > 0) { 1 } else { 0 }
}

func worktreeEntryValue(entry: ProductWorktreeEntry): AgentValue {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("path", textValue(entry.path)))
    fields.add(ValueField("kind", textValue(entry.kind)))
    if (entry.parentRepo != "") {
        fields.add(ValueField(
            "parentRepo",
            textValue(entry.parentRepo)
        ))
    }
    if (entry.branch != "") {
        fields.add(ValueField("branch", textValue(entry.branch)))
    }
    if (entry.orphanReason != "") {
        fields.add(ValueField(
            "orphanReason",
            textValue(entry.orphanReason)
        ))
    }
    objectValue(fields.toArray())
}

func worktreeEntryDetail(entry: ProductWorktreeEntry): String {
    var detail = match (entry.kind) {
        case "pr-checkout" =>
            let repo = if (entry.parentRepo == "") {
                "unknown repo"
            } else {
                Path(entry.parentRepo).fileName
            }
            repo + " · " + if (entry.branch == "") {
                "unknown branch"
            } else {
                entry.branch
            }
        case "task-isolation" => "task-isolation sandbox"
        case "empty" => "empty project shell"
        case _ => "unrecognized contents"
    }
    if (entry.orphanReason != "") {
        detail += " — " + entry.orphanReason
    }
    detail
}

func worktreePositionals(arguments: Array<String>): Array<String> {
    let values = ArrayList<String>()
    for (argument in arguments) {
        if (!argument.startsWith("-")) { values.add(argument) }
    }
    values.toArray()
}

func worktreeUnknownOption(arguments: Array<String>): String {
    for (argument in arguments) {
        if (!argument.startsWith("-")) { continue }
        if (argument == "--all" ||
            argument == "--dry-run" ||
            argument == "-n" ||
            argument == "--json" ||
            argument == "-j" ||
            argument == "--help" ||
            argument == "-h") {
            continue
        }
        return argument
    }
    ""
}

func printWorktreeHelp(io!: CliIo180 = consoleCliIo180): Unit {
    io.println("List or clear agent-managed git worktrees (~/.axyndra/wt)")
    io.println()
    io.println("USAGE")
    io.println("  $ axyndra worktree [ACTION] [FLAGS]")
    io.println()
    io.println("ARGUMENTS")
    io.println("  ACTION   list (default) or clear (list|clear)")
    io.println()
    io.println("FLAGS")
    io.println(
        "      --all      Clear every entry, including live " +
            "PR-checkout worktrees (clear)"
    )
    io.println(
        "  -n, --dry-run  Print what would be removed without " +
            "touching the filesystem (clear)"
    )
    io.println("  -j, --json     Emit machine-readable JSON")
    io.println()
    io.println("EXAMPLES")
    io.println("  axyndra worktree")
    io.println("  axyndra worktree list --json")
    io.println("  axyndra worktree clear")
    io.println("  axyndra worktree clear --dry-run")
    io.println("  axyndra worktree clear --all")
}
