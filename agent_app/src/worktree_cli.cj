package agent_app

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_product.*
import model_adapters.*
import std.collection.*
import std.fs.*

func runWorktreeCli(
    session: ApplicationSession,
    arguments: Array<String>
): Int64 {
    if (hasArgument(arguments, "--help") ||
        hasArgument(arguments, "-h")) {
        printWorktreeHelp()
        return 0
    }
    let unknown = worktreeUnknownOption(arguments)
    if (unknown != "") {
        println("error: Nonexistent flag: " + unknown)
        println()
        println("Run `axyndra worktree --help` for details.")
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
        println(
            "error: Expected action to be one of: list, clear; got \"" +
                authored + "\""
        )
        println()
        println("USAGE")
        println("  $ axyndra worktree [ACTION] [FLAGS]")
        println()
        println("Run `axyndra worktree --help` for details.")
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
        )
    }
    listWorktrees(session, json)
}

func listWorktrees(
    session: ApplicationSession,
    json: Bool
): Int64 {
    let entries = match (session.managedWorktrees()) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            printError(error)
            return 1
    }
    if (json) {
        let values = ArrayList<AgentValue>()
        for (entry in entries) {
            values.add(worktreeEntryValue(entry))
        }
        println(encodeAgentValue(listValue(values.toArray())))
        return 0
    }
    if (entries.isEmpty()) {
        println(
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
            println("live      " + entry.path)
        } else {
            orphaned++
            println("orphaned  " + entry.path)
        }
        let detail = worktreeEntryDetail(entry)
        if (detail != "") { println("          " + detail) }
    }
    println()
    println(
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
): Int64 {
    let result = match (session.clearManagedWorktrees(all, dryRun)) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            printError(error)
            return 1
    }
    if (dryRun) {
        if (json) {
            println(encodeAgentValue(objectValue([
                ValueField(
                    "wouldRemove",
                    cliStringList(result.wouldRemove)
                )
            ])))
            return 0
        }
        if (result.wouldRemove.isEmpty()) {
            println(
                if (all) {
                    "No worktrees to remove."
                } else {
                    "No orphaned worktrees to remove."
                }
            )
            return 0
        }
        for (path in result.wouldRemove) {
            println("would remove  " + path)
        }
        println()
        println(
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
            println(encodeAgentValue(objectValue([
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
            println(encodeAgentValue(objectValue([
                ValueField("removed", integerValue(removed)),
                ValueField("failed", integerValue(failed)),
                ValueField("results", listValue(values.toArray()))
            ])))
        }
        return if (failed > 0) { 1 } else { 0 }
    }
    if (result.results.isEmpty()) {
        println(
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
            println("removed  " + entry.path)
        } else {
            println("failed   " + entry.path)
            if (entry.error != "") {
                println("          " + entry.error)
            }
        }
    }
    println()
    println(
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

func printWorktreeHelp(): Unit {
    println("List or clear agent-managed git worktrees (~/.axyndra/wt)")
    println()
    println("USAGE")
    println("  $ axyndra worktree [ACTION] [FLAGS]")
    println()
    println("ARGUMENTS")
    println("  ACTION   list (default) or clear (list|clear)")
    println()
    println("FLAGS")
    println(
        "      --all      Clear every entry, including live " +
            "PR-checkout worktrees (clear)"
    )
    println(
        "  -n, --dry-run  Print what would be removed without " +
            "touching the filesystem (clear)"
    )
    println("  -j, --json     Emit machine-readable JSON")
    println()
    println("EXAMPLES")
    println("  axyndra worktree")
    println("  axyndra worktree list --json")
    println("  axyndra worktree clear")
    println("  axyndra worktree clear --dry-run")
    println("  axyndra worktree clear --all")
}
