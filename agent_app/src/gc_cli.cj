package agent_app

import agent_domain.*
import agent_product.*
import model_adapters.*
import std.collection.*
import std.convert.*

func runGcCli(
    session: ApplicationSession,
    arguments: Array<String>
): Int64 {
    if (hasArgument(arguments, "--help") ||
        hasArgument(arguments, "-h")) {
        printGcHelp()
        return 0
    }
    let parseError = gcParseError(arguments)
    if (parseError != "") {
        eprintln("error: " + parseError)
        eprintln("")
        eprintln("USAGE")
        eprintln("  $ axyndra gc [FLAGS]")
        eprintln("")
        eprintln("Run `axyndra gc --help` for details.")
        return 2
    }
    let selected =
        hasArgument(arguments, "--blobs") ||
        hasArgument(arguments, "--archive") ||
        hasArgument(arguments, "--wal")
    let options = ProductGcOptions(
        argumentValueOr(
            arguments,
            "--agent-dir",
            session.stateRoot()
        ),
        apply: hasArgument(arguments, "--apply"),
        runBlobs: if (selected) {
            hasArgument(arguments, "--blobs")
        } else {
            true
        },
        runArchive: if (selected) {
            hasArgument(arguments, "--archive")
        } else {
            true
        },
        runWal: if (selected) {
            hasArgument(arguments, "--wal")
        } else {
            true
        },
        coldArchiveAfterDays: gcIntegerOption(
            arguments,
            "--cold-archive-after-days",
            30
        ),
        retainNewestGlobal: gcIntegerOption(
            arguments,
            "--retain-newest-global",
            20
        ),
        retainNewestPerCwd: gcIntegerOption(
            arguments,
            "--retain-newest-per-cwd",
            10
        ),
        activeSessionId: session.id().value
    )
    let result = match (session.garbageCollect(options)) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            printError(error)
            return 1
    }
    if (hasArgument(arguments, "--json")) {
        println(encodeAgentValue(gcResultValue(result)))
    } else {
        printGcText(result)
    }
    let errors = collectGcResultErrors(result)
    if (!errors.isEmpty()) {
        eprintln(
            "GC completed with " + errors.size.toString() + " error" +
                if (errors.size == 1) { ":" } else { "s:" }
        )
        for (error in errors) { eprintln("- " + error) }
        return 1
    }
    0
}

func gcParseError(arguments: Array<String>): String {
    for (name in [
        "--agent-dir",
        "--cold-archive-after-days",
        "--retain-newest-global",
        "--retain-newest-per-cwd"
    ]) {
        if (hasArgument(arguments, name) &&
            argumentValue(arguments, name) == "") {
            return "Flag " + name + " expects a value"
        }
    }
    for (name in [
        "--cold-archive-after-days",
        "--retain-newest-global",
        "--retain-newest-per-cwd"
    ]) {
        let authored = argumentValue(arguments, name)
        if (authored == "") { continue }
        let value = try {
            Int64.parse(authored)
        } catch (_: Exception) {
            return "Expected " + name + " to be an integer; got \"" +
                authored + "\""
        }
        let _ = value
    }
    var skipNext = false
    for (argument in arguments) {
        if (skipNext) {
            skipNext = false
            continue
        }
        if (argument == "--agent-dir" ||
            argument == "--cold-archive-after-days" ||
            argument == "--retain-newest-global" ||
            argument == "--retain-newest-per-cwd") {
            skipNext = true
            continue
        }
        if (argument == "--apply" ||
            argument == "--json" ||
            argument == "--blobs" ||
            argument == "--archive" ||
            argument == "--wal" ||
            argument == "--help" ||
            argument == "-h" ||
            argument.startsWith("--agent-dir=") ||
            argument.startsWith("--cold-archive-after-days=") ||
            argument.startsWith("--retain-newest-global=") ||
            argument.startsWith("--retain-newest-per-cwd=")) {
            continue
        }
        if (argument.startsWith("-")) {
            return "Nonexistent flag: " + argument
        }
        return "Unexpected argument: " + argument
    }
    ""
}

func gcIntegerOption(
    arguments: Array<String>,
    name: String,
    defaultValue: Int64
): Int64 {
    let authored = argumentValue(arguments, name)
    if (authored == "") { return defaultValue }
    try {
        Int64.parse(authored)
    } catch (_: Exception) {
        defaultValue
    }
}

func gcResultValue(result: ProductGcResult): AgentValue {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("agentDir", textValue(result.agentDir)))
    fields.add(ValueField("apply", boolValue(result.apply)))
    match (result.blobs) {
        case Some(value) =>
            fields.add(ValueField("blobs", blobGcValue(value)))
        case None => ()
    }
    match (result.archive) {
        case Some(value) =>
            fields.add(ValueField("archive", archiveGcValue(value)))
        case None => ()
    }
    match (result.wal) {
        case Some(value) =>
            fields.add(ValueField("wal", walGcValue(value)))
        case None => ()
    }
    fields.add(ValueField("lockPath", textValue(result.lockPath)))
    objectValue(fields.toArray())
}

func blobGcValue(value: ProductBlobGcResult): AgentValue {
    objectValue([
        ValueField("referenced", integerValue(value.referenced)),
        ValueField("candidates", integerValue(value.candidates)),
        ValueField("wouldDelete", integerValue(value.wouldDelete)),
        ValueField("deleted", integerValue(value.deleted)),
        ValueField("bytes", integerValue(value.bytes)),
        ValueField("errors", cliStringList(value.errors))
    ])
}

func archiveGcValue(value: ProductArchiveGcResult): AgentValue {
    objectValue([
        ValueField("scanned", integerValue(value.scanned)),
        ValueField(
            "skippedActive",
            integerValue(value.skippedActive)
        ),
        ValueField(
            "keptNewestGlobal",
            integerValue(value.keptNewestGlobal)
        ),
        ValueField(
            "keptNewestPerCwd",
            integerValue(value.keptNewestPerCwd)
        ),
        ValueField(
            "wouldArchive",
            integerValue(value.wouldArchive)
        ),
        ValueField("archived", integerValue(value.archived)),
        ValueField(
            "historyRowsDeleted",
            integerValue(value.historyRowsDeleted)
        ),
        ValueField("ftsRebuilt", boolValue(value.ftsRebuilt)),
        ValueField("errors", cliStringList(value.errors))
    ])
}

func walGcValue(value: ProductWalGcResult): AgentValue {
    let databases = ArrayList<AgentValue>()
    for (database in value.databases) {
        databases.add(objectValue([
            ValueField("dbPath", textValue(database.dbPath)),
            ValueField(
                "walBytes",
                integerValue(database.walBytes)
            ),
            ValueField(
                "wouldCheckpoint",
                boolValue(database.wouldCheckpoint)
            ),
            ValueField(
                "checkpointed",
                boolValue(database.checkpointed)
            ),
            ValueField("busy", integerValue(database.busy)),
            ValueField("log", integerValue(database.log)),
            ValueField(
                "checkpointedFrames",
                integerValue(database.checkpointedFrames)
            )
        ]))
    }
    objectValue([
        ValueField("databases", listValue(databases.toArray())),
        ValueField("walBytes", integerValue(value.walBytes)),
        ValueField(
            "wouldCheckpoint",
            boolValue(value.wouldCheckpoint)
        ),
        ValueField("checkpointed", boolValue(value.checkpointed))
    ])
}

func printGcText(result: ProductGcResult): Unit {
    println(
        "GC " + if (result.apply) { "applied" } else { "dry-run" } +
            " (" + result.agentDir + ")"
    )
    match (result.blobs) {
        case Some(value) =>
            println(
                "blobs: " + value.deleted.toString() + "/" +
                    value.wouldDelete.toString() + " files, " +
                    formatGcBytes(value.bytes) + ", " +
                    value.referenced.toString() + " refs"
            )
            if (!value.errors.isEmpty()) {
                println(
                    "blob errors: " + value.errors.size.toString()
                )
            }
        case None => ()
    }
    match (result.archive) {
        case Some(value) =>
            println(
                "sessions: " + value.archived.toString() + "/" +
                    value.wouldArchive.toString() + " archived, " +
                    value.historyRowsDeleted.toString() +
                    " history rows removed"
            )
            if (value.skippedActive > 0) {
                println(
                    "sessions skipped active: " +
                        value.skippedActive.toString()
                )
            }
            if (!value.errors.isEmpty()) {
                println(
                    "session errors: " + value.errors.size.toString()
                )
            }
        case None => ()
    }
    match (result.wal) {
        case Some(value) =>
            println(
                "wal: " + if (value.checkpointed) {
                    "checkpointed"
                } else {
                    "checkpoint dry-run"
                } + ", " + formatGcBytes(value.walBytes) +
                    " across " + value.databases.size.toString() +
                    " dbs"
            )
        case None => ()
    }
}

func collectGcResultErrors(
    result: ProductGcResult
): Array<String> {
    let values = ArrayList<String>()
    match (result.blobs) {
        case Some(blobs) =>
            for (error in blobs.errors) {
                values.add("blobs: " + error)
            }
        case None => ()
    }
    match (result.archive) {
        case Some(archive) =>
            for (error in archive.errors) {
                values.add("archive: " + error)
            }
        case None => ()
    }
    values.toArray()
}

func formatGcBytes(bytes: Int64): String {
    if (bytes < 1024) { return bytes.toString() + " B" }
    if (bytes < 1048576) {
        return gcOneDecimal(bytes, 1024) + " KiB"
    }
    if (bytes < 1073741824) {
        return gcOneDecimal(bytes, 1048576) + " MiB"
    }
    gcOneDecimal(bytes, 1073741824) + " GiB"
}

func gcOneDecimal(bytes: Int64, divisor: Int64): String {
    let tenths = bytes * 10 / divisor
    (tenths / 10).toString() + "." +
        (tenths % 10).toString()
}

func printGcHelp(): Unit {
    println("Run storage garbage collection")
    println()
    println("USAGE")
    println("  $ axyndra gc [FLAGS]")
    println()
    println("FLAGS")
    println(
        "      --apply                          " +
            "Apply changes (default is dry-run)"
    )
    println("      --json                           Output JSON")
    println(
        "      --agent-dir=<value>              " +
            "Agent directory to maintain"
    )
    println(
        "      --blobs                          " +
            "Sweep unreferenced blobs"
    )
    println(
        "      --archive                        " +
            "Archive cold sessions"
    )
    println(
        "      --wal                            " +
            "Checkpoint history/model database WAL files"
    )
    println(
        "      --cold-archive-after-days=<int>  " +
            "Minimum session age before archiving"
    )
    println(
        "      --retain-newest-global=<int>     " +
            "Always keep this many newest sessions active"
    )
    println(
        "      --retain-newest-per-cwd=<int>    " +
            "Always keep this many newest sessions per cwd active"
    )
}
