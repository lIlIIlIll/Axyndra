package agent_cli_contract

import agent_cli.*
import agent_domain.*
import std.collection.*

main(): Int64 {
    let expected = [
        "help",
        "setup",
        "providers",
        "model",
        "switch",
        "login",
        "logout",
        "new",
        "clear",
        "session",
        "branch",
        "fork",
        "compact",
        "handoff",
        "export",
        "dump",
        "todo",
        "goal",
        "plan",
        "plan-review",
        "vibe",
        "guided-goal",
        "loop",
        "queue",
        "rename",
        "import",
        "reset",
        "settings",
        "theme",
        "tools",
        "cancel",
        "agents",
        "agent",
        "jobs",
        "usage",
        "stats",
        "changelog",
        "hotkeys",
        "context",
        "extensions",
        "mcp",
        "tree",
        "debug",
        "ssh",
        "exit",
        "quit"
    ]
    let actual = availableSlashCommands()
    expect(
        actual.size == expected.size,
        "slash registry exposes only implemented product commands"
    )
    let router = CommandRouter()
    for (name in expected) {
        expect(
            contains(actual, name),
            "slash registry contains " + name
        )
        match (router.route("/" + name)) {
            case Result.Ok(RoutedInput.Command(_)) => ()
            case _ => throw IllegalStateException("slash command did not route locally: " + name)
        }
    }
    let definitions = slashCommandDefinitions()
    for (definition in definitions) {
        expect(
            definition.group != "" && definition.description != "" && definition.usage.startsWith("/"),
            "slash command help metadata is complete: " + definition.name
        )
    }
    match (router.route("ordinary prompt")) {
        case Result.Ok(RoutedInput.Prompt(value)) => expect(value == "ordinary prompt", "ordinary input is a prompt")
        case _ => throw IllegalStateException("ordinary input did not route to the agent")
    }
    expect(
        router.route("/not-implemented").isError(),
        "unknown slash input is rejected locally"
    )
    let surface = availableSlashSurfaceNames()
    for (name in [
        "todo",
        "edit",
        "copy",
        "export",
        "import",
        "append",
        "start",
        "done",
        "drop",
        "rm",
        "goal",
        "set",
        "show",
        "pause",
        "resume",
        "budget",
        "ssh",
        "add",
        "list",
        "remove",
        "changelog",
        "full"
    ]) {
        expect(
            contains(surface, name),
            "slash surface metadata contains " + name
        )
    }
    expect(
        router.route("/edit").isError(),
        "todo subcommands are not misregistered as top-level commands"
    )
    match (router.route("/export \"dir/a b.html\"")) {
        case Result.Ok(RoutedInput.Command(ClientCommand.Builtin(name, arguments))) =>
            expect(name == "export" && arguments == ["dir/a b.html"], "quoted path routes as one argument")
        case _ => throw IllegalStateException("quoted path did not route")
    }
    match (router.route("/todo append \"Build Phase\" write tests")) {
        case Result.Ok(RoutedInput.Command(ClientCommand.Builtin(name, arguments))) =>
            expect(
                name == "todo" && arguments == ["append", "Build Phase", "write", "tests"],
                "quoted todo phase remains one parsed argument"
            )
        case _ => throw IllegalStateException("quoted todo append did not route")
    }
    match (router.route("/reject operation-1 \"needs \\\"quotes\\\" and C:\\\\tmp\"")) {
        case Result.Ok(RoutedInput.Command(ClientCommand.RejectWithReason(operation, reason))) =>
            expect(
                operation == "operation-1" && reason == "needs \"quotes\" and C:\\tmp",
                "quoted command escapes decode predictably"
            )
        case _ => throw IllegalStateException("quoted reject reason did not route")
    }
    match (router.route("/export \"a\\qb\"")) {
        case Result.Ok(RoutedInput.Command(ClientCommand.Builtin(_, arguments))) =>
            expect(arguments == ["a\\qb"], "unknown backslash escapes remain literal")
        case _ => throw IllegalStateException("literal backslash argument did not route")
    }
    match (router.route("/export My\\ Dir/Win\\\\Path.txt")) {
        case Result.Ok(RoutedInput.Command(ClientCommand.Builtin(_, arguments))) =>
            expect(
                arguments == ["My Dir/Win\\Path.txt"],
                "supported unquoted shell escapes decode as one path token"
            )
        case _ => throw IllegalStateException("unquoted escaped path did not route")
    }
    match (router.route("/export \"unfinished")) {
        case Result.Err(error) => expect(error.code == "cli.unterminated_quote", "unterminated slash quote is typed")
        case _ => throw IllegalStateException("unterminated slash quote was accepted")
    }
    match (router.route("ordinary \"unfinished")) {
        case Result.Ok(RoutedInput.Prompt(value)) =>
            expect(value == "ordinary \"unfinished", "ordinary prompt quotes remain model input")
        case _ => throw IllegalStateException("ordinary prompt quote was parsed as a command")
    }
    let permissive = parseCommandInput("/export \"dir/a b", allowUnterminatedQuote: true).value().getOrThrow()
    expect(
        permissive.unterminatedQuote && permissive.tokens.size == 2 &&
            permissive.tokens[1].value == "dir/a b" && permissive.tokens[1].quoted,
        "completion parser preserves an open quoted token"
    )
    completionEngineContract()
    for (definition in definitions where definition.name == "todo") {
        expect(
            definition.pathArgumentPrefixes == [["export"], ["import"]],
            "todo path completion positions come from registry metadata"
        )
    }
    let cli = reservedCliCommandRegistry()
    let expectedReserved = [
        "launch",
        "acp",
        "auth-broker",
        "auth-gateway",
        "agents",
        "bench",
        "cleanse",
        "commit",
        "completions",
        "__complete",
        "__process-broker-worker",
        "__process-broker-client",
        "config",
        "dry-balance",
        "gc",
        "grep",
        "gallery",
        "grievances",
        "install",
        "join",
        "models",
        "mcp-server",
        "reviewer-dry-run",
        "plugin",
        "say",
        "setup",
        "shell",
        "read",
        "ssh",
        "stats",
        "update",
        "usage",
        "tiny-models",
        "token",
        "ttsr",
        "worktree",
        "search"
    ]
    let reserved = cli.reservedNames()
    expect(
        reserved.size == expectedReserved.size,
        "CLI reservation inventory has no additions or removals without a contract update"
    )
    for (name in expectedReserved) {
        expect(cli.isReserved(name), "reserved CLI contains " + name)
    }
    match (cli.resolve("wt")) {
        case Some(spec) => expect(spec.name == "worktree", "CLI aliases resolve canonically")
        case None => throw IllegalStateException("worktree alias is missing")
    }
    match (cli.resolve("q")) {
        case Some(spec) => expect(spec.name == "search", "search alias resolves canonically")
        case None => throw IllegalStateException("search alias is missing")
    }
    match (cli.resolve("join")) {
        case Some(spec) => match (spec.visibility) {
            case CliCommandVisibility.Hidden => ()
            case _ => throw IllegalStateException("join must remain hidden")
        }
        case None => throw IllegalStateException("join reservation is missing")
    }
    for (name in ["__complete", "__process-broker-worker", "__process-broker-client"]) {
        match (cli.resolve(name)) {
            case Some(spec) => match (spec.visibility) {
                case CliCommandVisibility.Internal => ()
                case _ => throw IllegalStateException(name + " must remain internal")
            }
            case None => throw IllegalStateException(name + " reservation is missing")
        }
    }
    println("agent_cli contract passed")
    0
}

func contains(values: Array<String>, expected: String): Bool {
    for (value in values where value == expected) {
        return true
    }
    false
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) {
        throw IllegalStateException(message)
    }
}

func completionEngineContract(): Unit {
    let slash = commandCompletionPlan("  /he", "  /he".size)
    expect(
        isSlashTarget(slash.target) && slash.activePrefix == "/he" && slash.replaceStart == 2,
        "slash completion is planned only for the first token"
    )
    let laterSlash = commandCompletionPlan("prompt /he", "prompt /he".size)
    expect(
        isPathTarget(laterSlash.target),
        "a slash outside the first token remains ordinary path-like input"
    )
    let subcommand = commandCompletionPlan("/todo do", "/todo do".size)
    expect(
        isSubcommandTarget(subcommand.target) && subcommand.commandName == "todo",
        "subcommand position comes from slash registry metadata"
    )
    let todoPath = commandCompletionPlan("/todo export ", "/todo export ".size)
    expect(
        isPathTarget(todoPath.target) && todoPath.commandName == "todo",
        "path position comes from slash registry metadata"
    )

    let unicode = "界file"
    let unicodeBoundary = commandCompletionPlan(unicode, 1)
    expect(
        unicodeBoundary.cursor == 0 && unicodeBoundary.replaceEnd == 0,
        "completion clamps a byte cursor to a UTF-8 rune boundary"
    )

    let middleSource = "/export \"中suffix.txt\""
    let middleCursor = "/export \"中".size
    let middle = commandCompletionPlan(middleSource, middleCursor)
    let middleItems = commandCompletionCandidates(
        middle,
        pathCandidates: [CompletionCandidate("中文 路径.txt", detail: "file")]
    )
    expect(
        middleItems.size == 1 && middle.replaceStart == "/export \"".size &&
            middle.replaceEnd == middleCursor && middle.closingQuoteAfterCursor,
        "quoted path planning replaces only the prefix before a middle cursor"
    )
    expect(
        acceptCompletion(middleSource, middle, middleItems[0]) ==
            "/export \"中文 路径.txtsuffix.txt\"",
        "middle completion preserves the existing token suffix"
    )

    let openQuote = commandCompletionPlan("/export \"My", "/export \"My".size)
    let openDirectory = commandCompletionCandidates(
        openQuote,
        pathCandidates: [CompletionCandidate("My Dir/", detail: "directory", directory: true)]
    )
    let openFile = commandCompletionCandidates(
        openQuote,
        pathCandidates: [CompletionCandidate("My File.txt", detail: "file")]
    )
    expect(
        openDirectory.size == 1 &&
            acceptCompletion("/export \"My", openQuote, openDirectory[0]) == "/export \"My Dir/",
        "directory completion keeps an open quote for continued traversal"
    )
    expect(
        openFile.size == 1 &&
            acceptCompletion("/export \"My", openQuote, openFile[0]) == "/export \"My File.txt",
        "file completion does not close an authored open quote"
    )

    let backslash = commandCompletionPlan("/export Win", "/export Win".size)
    let backslashItems = commandCompletionCandidates(
        backslash,
        pathCandidates: [CompletionCandidate("Win\\Path.txt", detail: "file")]
    )
    expect(
        backslashItems.size == 1 && backslashItems[0].insertText == "Win\\\\Path.txt",
        "unquoted path completion shell-escapes a literal backslash"
    )

    let ordered = filterCompletionCandidates(
        [
            CompletionCandidate("beta"),
            CompletionCandidate("alpha2"),
            CompletionCandidate("Alpha"),
            CompletionCandidate("alphabet"),
            CompletionCandidate("Alpha")
        ],
        "a"
    )
    expect(
        completionValues(ordered) == ["Alpha", "alpha2", "alphabet"],
        "candidate matching deduplicates and sorts deterministically"
    )
    let contains = filterCompletionCandidates(
        [CompletionCandidate("xalpha"), CompletionCandidate("alphabet")],
        "alp",
        mode: CompletionMatchMode.Contains
    )
    expect(
        completionValues(contains) == ["alphabet", "xalpha"],
        "contains matching ranks prefix matches before interior matches"
    )

    let noMatchSource = "/todo zz"
    let noMatchPlan = commandCompletionPlan(noMatchSource, noMatchSource.size)
    let noMatch = commandCompletionCandidates(noMatchPlan)
    expect(
        noMatch.isEmpty() && noMatchSource == "/todo zz",
        "no matching completion leaves the caller draft unchanged"
    )
}

func acceptCompletion(
    source: String,
    plan: CommandCompletionPlan,
    candidate: CompletionCandidate
): String {
    source[..plan.replaceStart] + candidate.insertText + source[plan.replaceEnd..]
}

func completionValues(candidates: Array<CompletionCandidate>): Array<String> {
    let values = ArrayList<String>()
    for (candidate in candidates) {
        values.add(candidate.value)
    }
    values.toArray()
}

func isSlashTarget(target: CommandCompletionTarget): Bool {
    match (target) {
        case CommandCompletionTarget.SlashCommand => true
        case _ => false
    }
}

func isSubcommandTarget(target: CommandCompletionTarget): Bool {
    match (target) {
        case CommandCompletionTarget.Subcommand => true
        case _ => false
    }
}

func isPathTarget(target: CommandCompletionTarget): Bool {
    match (target) {
        case CommandCompletionTarget.Path => true
        case _ => false
    }
}
