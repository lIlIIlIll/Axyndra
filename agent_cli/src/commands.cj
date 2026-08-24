package agent_cli

import agent_domain.*
import std.collection.*

public enum ClientCommand {
    Help
    | Exit
    | RunStatus(String)
    | Events(String, Int64)
    | Approve(String)
    | ApproveSession(String)
    | Reject(String)
    | RejectWithReason(String, String)
    | NewSession
    | ArchiveReset(String)
    | Builtin(String, Array<String>)
}

public enum RoutedInput {
    Prompt(String) | Command(ClientCommand)
}

public class CommandInputToken {
    public let value: String
    public let sourceStart: Int64
    public let contentStart: Int64
    public let sourceEnd: Int64
    public let quoted: Bool

    public init(
        value: String,
        sourceStart: Int64,
        contentStart: Int64,
        sourceEnd: Int64,
        quoted: Bool
    ) {
        this.value = value
        this.sourceStart = sourceStart
        this.contentStart = contentStart
        this.sourceEnd = sourceEnd
        this.quoted = quoted
    }
}

public class CommandInputParse {
    public let tokens: Array<CommandInputToken>
    public let unterminatedQuote: Bool

    public init(tokens: Array<CommandInputToken>, unterminatedQuote: Bool) {
        this.tokens = tokens
        this.unterminatedQuote = unterminatedQuote
    }
}

public enum CompletionMatchMode {
    Prefix | Contains
}

public enum CommandCompletionTarget {
    Unavailable | SlashCommand | Subcommand | Path
}

// A UI-neutral completion candidate. Callers may attach display detail and
// mark directories, but matching and ordering stay shared across shells and
// terminal frontends.
public class CompletionCandidate {
    public let value: String
    public let insertText: String
    public let detail: String
    public let directory: Bool

    public init(
        value: String,
        insertText!: String = "",
        detail!: String = "",
        directory!: Bool = false
    ) {
        this.value = value
        this.insertText = if (insertText == "") { value } else { insertText }
        this.detail = detail
        this.directory = directory
    }
}

// The plan uses UTF-8 byte offsets, matching String slicing and the composer
// contract. replaceEnd is the cursor rather than the end of the active token,
// so accepting a completion in the middle of a draft preserves its suffix.
public class CommandCompletionPlan {
    public let target: CommandCompletionTarget
    public let tokensBefore: Array<String>
    public let commandName: String
    public let activePrefix: String
    public let replaceStart: Int64
    public let replaceEnd: Int64
    public let cursor: Int64
    public let activeQuoted: Bool
    public let quoteWrapped: Bool
    public let closingQuoteAfterCursor: Bool

    public init(
        target: CommandCompletionTarget,
        tokensBefore: Array<String>,
        commandName: String,
        activePrefix: String,
        replaceStart: Int64,
        replaceEnd: Int64,
        cursor: Int64,
        activeQuoted: Bool,
        quoteWrapped: Bool,
        closingQuoteAfterCursor: Bool
    ) {
        this.target = target
        this.tokensBefore = tokensBefore
        this.commandName = commandName
        this.activePrefix = activePrefix
        this.replaceStart = replaceStart
        this.replaceEnd = replaceEnd
        this.cursor = cursor
        this.activeQuoted = activeQuoted
        this.quoteWrapped = quoteWrapped
        this.closingQuoteAfterCursor = closingQuoteAfterCursor
    }
}

public func parseCommandInput(
    source: String,
    allowUnterminatedQuote!: Bool = false
): Result<CommandInputParse> {
    let tokens = ArrayList<CommandInputToken>()
    let data = unsafe { source.rawData() }
    var index: Int64 = 0
    var unterminated = false
    while (index < data.size) {
        while (index < data.size && isCommandWhitespace(data[index])) {
            index++
        }
        if (index >= data.size) {
            break
        }
        let sourceStart = index
        let contentStart = if (data[index] == b'"') {
            index + 1
        } else {
            index
        }
        let decoded = ArrayList<Byte>()
        var inQuote = false
        var quoted = false
        while (index < data.size) {
            let byte = data[index]
            if (!inQuote && isCommandWhitespace(byte)) {
                break
            }
            if (byte == b'\\' && index + 1 < data.size &&
                ((inQuote && (data[index + 1] == b'"' || data[index + 1] == b'\\')) ||
                (!inQuote && (isCommandWhitespace(data[index + 1]) || data[index + 1] == b'"' ||
                data[index + 1] == b'\\')))) {
                decoded.add(data[index + 1])
                index += 2
                continue
            }
            if (byte == b'"') {
                quoted = true
                inQuote = !inQuote
                index++
                continue
            }
            decoded.add(byte)
            index++
        }
        if (inQuote) {
            unterminated = true
        }
        tokens.add(
            CommandInputToken(
                String.fromUtf8(decoded.toArray()),
                sourceStart,
                contentStart,
                index,
                quoted
            )
        )
    }
    if (unterminated && !allowUnterminatedQuote) {
        return Result.Err(
            AgentError(
                AgentErrorKind.InvalidInput,
                "cli.unterminated_quote",
                "unterminated double quote"
            )
        )
    }
    Result.Ok(CommandInputParse(tokens.toArray(), unterminated))
}

public func parseCommandInputForCompletion(source: String): CommandInputParse {
    match (parseCommandInput(source, allowUnterminatedQuote: true)) {
        case Result.Ok(parsed) => parsed
        case Result.Err(_) => CommandInputParse([], false)
    }
}

public func commandCompletionPlan(source: String, cursor: Int64): CommandCompletionPlan {
    let boundedCursor = clampCommandCursor(source, cursor)
    let full = parseCommandInputForCompletion(source)
    let prefix = parseCommandInputForCompletion(source[..boundedCursor])
    var active: ?CommandInputToken = None
    for (token in full.tokens) {
        if (boundedCursor >= token.sourceStart && boundedCursor <= token.sourceEnd) {
            active = Some(token)
            break
        }
    }

    let tokensBefore = ArrayList<String>()
    var activePrefix = ""
    var replaceStart = boundedCursor
    var activeQuoted = false
    var quoteWrapped = false
    var closingQuoteAfterCursor = false
    match (active) {
        case Some(token) =>
            for (candidate in full.tokens where candidate.sourceEnd <= token.sourceStart) {
                tokensBefore.add(candidate.value)
            }
            for (candidate in prefix.tokens where candidate.sourceStart == token.sourceStart) {
                activePrefix = candidate.value
            }
            activeQuoted = token.quoted
            quoteWrapped = token.contentStart > token.sourceStart
            replaceStart = if (quoteWrapped) { token.contentStart } else { token.sourceStart }
            closingQuoteAfterCursor = quoteWrapped && hasClosingQuote(source, boundedCursor, token.sourceEnd)
        case None =>
            for (token in prefix.tokens) {
                tokensBefore.add(token.value)
            }
    }

    let (target, commandName) = completionTarget(tokensBefore.toArray(), activePrefix)
    CommandCompletionPlan(
        target,
        tokensBefore.toArray(),
        commandName,
        activePrefix,
        replaceStart,
        boundedCursor,
        boundedCursor,
        activeQuoted,
        quoteWrapped,
        closingQuoteAfterCursor
    )
}

// Registry candidates are built here; filesystem entries remain caller input
// so agent_cli stays independent of the terminal and filesystem layers.
public func commandCompletionCandidates(
    plan: CommandCompletionPlan,
    pathCandidates!: Array<CompletionCandidate> = []
): Array<CompletionCandidate> {
    match (plan.target) {
        case CommandCompletionTarget.SlashCommand =>
            let candidates = ArrayList<CompletionCandidate>()
            for (definition in slashCommandDefinitions()) {
                let command = "/" + definition.name
                candidates.add(
                    CompletionCandidate(
                        command,
                        insertText: command + " ",
                        detail: "command"
                    )
                )
            }
            filterCompletionCandidates(candidates.toArray(), plan.activePrefix)
        case CommandCompletionTarget.Subcommand =>
            let definition = match (slashCommandDefinitionForCompletion(plan.commandName)) {
                case Some(value) => value
                case None => return []
            }
            let candidates = ArrayList<CompletionCandidate>()
            for (subcommand in definition.subcommands) {
                candidates.add(
                    CompletionCandidate(
                        subcommand,
                        insertText: subcommand + " ",
                        detail: "subcommand"
                    )
                )
            }
            filterCompletionCandidates(candidates.toArray(), plan.activePrefix)
        case CommandCompletionTarget.Path =>
            let matched = filterCompletionCandidates(pathCandidates, plan.activePrefix)
            let candidates = ArrayList<CompletionCandidate>()
            for (candidate in matched) {
                candidates.add(
                    CompletionCandidate(
                        candidate.value,
                        insertText: pathCandidateInsertText(plan, candidate),
                        detail: candidate.detail,
                        directory: candidate.directory
                    )
                )
            }
            candidates.toArray()
        case CommandCompletionTarget.Unavailable => []
    }
}

public func filterCompletionCandidates(
    candidates: Array<CompletionCandidate>,
    prefix: String,
    mode!: CompletionMatchMode = CompletionMatchMode.Prefix
): Array<CompletionCandidate> {
    let filtered = ArrayList<CompletionCandidate>()
    let normalizedPrefix = prefix.toAsciiLower()
    for (candidate in candidates) {
        let normalized = candidate.value.toAsciiLower()
        let matches = match (mode) {
            case CompletionMatchMode.Prefix => normalized.startsWith(normalizedPrefix)
            case CompletionMatchMode.Contains => normalized.contains(normalizedPrefix)
        }
        if (!matches || containsCompletionValue(filtered, candidate.value)) {
            continue
        }
        filtered.add(candidate)
        var index = filtered.size - 1
        while (index > 0 && completionCandidateBefore(filtered[index], filtered[index - 1], normalizedPrefix, mode)) {
            let previous = filtered[index - 1]
            filtered[index - 1] = filtered[index]
            filtered[index] = previous
            index--
        }
    }
    filtered.toArray()
}

public class CommandRouter {
    public init() {}

    public func route(input: String): Result<RoutedInput> {
        let value = input.trimAscii()
        if (value == "") {
            return Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "cli.empty_input",
                    "input must not be empty"
                )
            )
        }
        if (!value.startsWith("/")) {
            return Result.Ok(RoutedInput.Prompt(value))
        }
        let parts = match (parseCommandInput(value)) {
            case Result.Ok(parsed) => commandTokenValues(parsed.tokens)
            case Result.Err(error) => return Result.Err(error)
        }
        match (parts[0]) {
            case "/help" => noArguments(parts, ClientCommand.Help)
            case "/exit" => noArguments(parts, ClientCommand.Exit)
            case "/new" => noArguments(parts, ClientCommand.NewSession)
            case "/status" => oneArgument(parts, {
                value => ClientCommand.RunStatus(value)
            })
            case "/events" =>
                if (parts.size != 3) {
                    usage("/events <run-id> <after-sequence>")
                } else {
                    let after = match (parseSequence(parts[2])) {
                        case Some(value) => value
                        case None => return usage("/events <run-id> <after-sequence>")
                    }
                    Result.Ok(RoutedInput.Command(ClientCommand.Events(parts[1], after)))
                }
            case "/approve" => oneArgument(parts, {
                value => ClientCommand.Approve(value)
            })
            case "/approve-session" => oneArgument(parts, {
                value => ClientCommand.ApproveSession(value)
            })
            case "/reject" => rejectCommand(parts)
            case "/archive-reset" => oneArgument(parts, {
                value => ClientCommand.ArchiveReset(value)
            })
            case _ =>
                let name = withoutSlash(parts[0])
                if (isBuiltinSlashCommand(name)) {
                    Result.Ok(RoutedInput.Command(ClientCommand.Builtin(name, arguments(parts))))
                } else {
                    Result.Err(
                        AgentError(
                            AgentErrorKind.InvalidInput,
                            "cli.unknown_command",
                            "unknown slash command",
                            fields: [ErrorField("command", parts[0])]
                        )
                    )
                }
        }
    }

    private func noArguments(
        parts: Array<String>,
        command: ClientCommand
    ): Result<RoutedInput> {
        if (parts.size == 1) {
            Result.Ok(RoutedInput.Command(command))
        } else {
            usage(parts[0])
        }
    }

    private func oneArgument(
        parts: Array<String>,
        create: (String) -> ClientCommand
    ): Result<RoutedInput> {
        if (parts.size == 2 && parts[1].trimAscii() != "") {
            Result.Ok(RoutedInput.Command(create(parts[1])))
        } else {
            usage(parts[0] + " <id>")
        }
    }

    private func rejectCommand(parts: Array<String>): Result<RoutedInput> {
        if (parts.size < 2 || parts[1].trimAscii() == "") {
            return usage("/reject <operation-id> [reason]")
        }
        if (parts.size == 2) {
            return Result.Ok(RoutedInput.Command(ClientCommand.Reject(parts[1])))
        }
        Result.Ok(
            RoutedInput.Command(
                ClientCommand.RejectWithReason(
                    parts[1],
                    joinParts(parts, 2)
                )
            )
        )
    }

    private func usage<T>(expected: String): Result<T> {
        Result.Err(
            AgentError(
                AgentErrorKind.InvalidInput,
                "cli.invalid_command_arguments",
                "invalid command arguments",
                fields: [ErrorField("usage", expected)]
            )
        )
    }
}

public class SlashCommandDefinition {
    public let name: String
    public let group: String
    public let description: String
    public let usage: String
    public let aliases: Array<String>
    public let source: String
    public let subcommands: Array<String>
    public let pathArgumentPrefixes: Array<Array<String>>

    public init(
        name: String,
        group: String,
        description: String,
        usage!: String = "",
        aliases!: Array<String> = [],
        source!: String = "builtin",
        subcommands!: Array<String> = [],
        pathArgumentPrefixes!: Array<Array<String>> = []
    ) {
        this.name = name
        this.group = group
        this.description = description
        this.usage = if (usage == "") {
            "/" + name
        } else {
            usage
        }
        this.aliases = aliases
        this.source = source
        this.subcommands = subcommands
        this.pathArgumentPrefixes = pathArgumentPrefixes
    }

    public func inputHint(): String {
        let prefix = "/" + name
        if (usage == prefix) {
            return ""
        }
        let prefixWithSpace = prefix + " "
        if (!usage.startsWith(prefixWithSpace)) {
            return usage
        }
        let data = unsafe { usage.rawData() }
        let offset = unsafe { prefixWithSpace.rawData().size }
        String.fromUtf8(data[offset..data.size])
    }
}

public func slashCommandDefinitions(): Array<SlashCommandDefinition> {
    [
        SlashCommandDefinition("help", "Setup & help", "Show this command guide"),
        SlashCommandDefinition("setup", "Setup & help", "Configure providers and models", usage: "/setup [providers]"),
        SlashCommandDefinition("providers", "Setup & help", "Open provider configuration"),
        SlashCommandDefinition("model", "Setup & help", "Show or select the active model", usage: "/model [model-id]"),
        SlashCommandDefinition("switch", "Setup & help", "Open the model selector"),
        SlashCommandDefinition("login", "Setup & help", "Store provider credentials", usage: "/login [provider-profile]"),
        SlashCommandDefinition("logout", "Setup & help", "Remove provider credentials",
            usage: "/logout [provider-profile]"),
        SlashCommandDefinition("settings", "Setup & help", "Show the active configuration"),
        SlashCommandDefinition("theme", "Setup & help", "List or select a terminal theme", usage: "/theme [name]"),
        SlashCommandDefinition("hotkeys", "Setup & help", "Show keyboard shortcuts"),
        SlashCommandDefinition("new", "Sessions", "Start a new session"),
        SlashCommandDefinition("clear", "Sessions", "Start a new session and clear the view"),
        SlashCommandDefinition("session", "Sessions", "List or switch sessions", usage: "/session [session-id]"),
        SlashCommandDefinition("branch", "Sessions", "Open the branch selector"),
        SlashCommandDefinition("fork", "Sessions", "Fork the current session"),
        SlashCommandDefinition("compact", "Sessions", "Compact old conversation context"),
        SlashCommandDefinition("handoff", "Sessions", "Continue in a clean session", usage: "/handoff [instructions]"),
        SlashCommandDefinition("rename", "Sessions", "Show or rename this session", usage: "/rename [name]"),
        SlashCommandDefinition(
            "import",
            "Sessions",
            "Import an OMP JSONL session",
            usage: "/import <session.jsonl>",
            pathArgumentPrefixes: [[]]
        ),
        SlashCommandDefinition(
            "export",
            "Sessions",
            "Export this session as HTML",
            usage: "/export [path]",
            pathArgumentPrefixes: [[]]
        ),
        SlashCommandDefinition("dump", "Sessions", "Dump the current transcript and request"),
        SlashCommandDefinition("tree", "Sessions", "Show the session branch tree"),
        SlashCommandDefinition("reset", "Sessions", "Archive state and start clean", usage: "/reset <archive-label>"),
        SlashCommandDefinition(
            "todo",
            "Work modes",
            "Manage the session todo list",
            usage: "/todo [subcommand]",
            subcommands: [
                "edit",
                "copy",
                "export",
                "import",
                "append",
                "start",
                "done",
                "drop",
                "rm",
                "help",
                "?"
            ],
            pathArgumentPrefixes: [["export"], ["import"]]
        ),
        SlashCommandDefinition(
            "goal",
            "Work modes",
            "Create and manage an autonomous goal",
            usage: "/goal <subcommand>",
            subcommands: [
                "set",
                "show",
                "pause",
                "resume",
                "drop",
                "budget"
            ]
        ),
        SlashCommandDefinition("plan", "Work modes", "Toggle read-only planning mode", usage: "/plan [request]"),
        SlashCommandDefinition("plan-review", "Work modes", "Review the latest structured plan"),
        SlashCommandDefinition("vibe", "Work modes", "Toggle delegated director mode", usage: "/vibe [request]"),
        SlashCommandDefinition("guided-goal", "Work modes", "Turn a rough objective into a goal",
            usage: "/guided-goal [objective]"),
        SlashCommandDefinition("loop", "Work modes", "Repeat work after each yield", usage: "/loop [options] [prompt]"),
        SlashCommandDefinition("queue", "Work modes", "Queue input for the next safe boundary",
            usage: "/queue <message>"),
        SlashCommandDefinition("tools", "Agents & tools", "List tools available to the agent"),
        SlashCommandDefinition("cancel", "Agents & tools", "Cancel active work or approval"),
        SlashCommandDefinition("agents", "Agents & tools", "List subagents and their status"),
        SlashCommandDefinition("agent", "Agents & tools", "Open a subagent transcript", usage: "/agent <subagent-id>"),
        SlashCommandDefinition("jobs", "Agents & tools", "List background jobs"),
        SlashCommandDefinition("extensions", "Agents & tools", "Manage installed extensions"),
        SlashCommandDefinition("mcp", "Agents & tools", "Show configured MCP servers"),
        SlashCommandDefinition(
            "ssh",
            "Agents & tools",
            "Manage SSH hosts used by ACP",
            usage: "/ssh <add|list|remove|help>",
            subcommands: ["add", "list", "remove", "rm", "help"]
        ),
        SlashCommandDefinition("usage", "Inspect", "Show provider usage and session statistics"),
        SlashCommandDefinition("stats", "Inspect", "Show session execution statistics"),
        SlashCommandDefinition("context", "Inspect", "Show current context usage"),
        SlashCommandDefinition("debug", "Inspect", "Show a diagnostic session snapshot"),
        SlashCommandDefinition(
            "changelog",
            "Inspect",
            "Show release and compatibility notes",
            usage: "/changelog [full]",
            subcommands: ["full"]
        ),
        SlashCommandDefinition("exit", "Exit", "Exit axyndra"),
        SlashCommandDefinition("quit", "Exit", "Exit axyndra")
    ]
}

public func availableSlashCommands(): Array<String> {
    let names = ArrayList<String>()
    for (definition in slashCommandDefinitions()) {
        names.add(definition.name)
    }
    names.toArray()
}

public func availableSlashSurfaceNames(): Array<String> {
    let names = ArrayList<String>()
    for (definition in slashCommandDefinitions()) {
        addSlashSurfaceName(names, definition.name)
        for (subcommand in definition.subcommands) {
            addSlashSurfaceName(names, subcommand)
        }
    }
    names.toArray()
}

func addSlashSurfaceName(
    names: ArrayList<String>,
    value: String
): Unit {
    for (name in names where name == value) {
        return
    }
    names.add(value)
}

public func isBuiltinSlashCommand(name: String): Bool {
    for (candidate in availableSlashCommands() where candidate == name) {
        return true
    }
    false
}

func withoutSlash(value: String): String {
    let bytes = unsafe { value.rawData() }
    if (bytes.size <= 1) {
        return ""
    }
    String.fromUtf8(bytes[1..bytes.size])
}

func arguments(parts: Array<String>): Array<String> {
    if (parts.size <= 1) {
        return []
    }
    parts[1..parts.size]
}

func parseSequence(value: String): ?Int64 {
    if (value == "") {
        return None
    }
    var result: Int64 = 0
    let data = unsafe { value.rawData() }
    for (byte in data) {
        if (byte < b'0' || byte > b'9') {
            return None
        }
        result = result * 10 + Int64(byte - b'0')
    }
    Some(result)
}

func joinParts(parts: Array<String>, start: Int64): String {
    var result = ""
    for (index in start..parts.size) {
        if (parts[index].trimAscii() == "") {
            continue
        }
        if (result != "") {
            result += " "
        }
        result += parts[index]
    }
    result
}

func commandTokenValues(tokens: Array<CommandInputToken>): Array<String> {
    let values = ArrayList<String>()
    for (token in tokens) {
        values.add(token.value)
    }
    values.toArray()
}

func isCommandWhitespace(byte: Byte): Bool {
    byte == b' ' || byte == b'\t' || byte == b'\r' || byte == b'\n'
}

func clampCommandCursor(source: String, cursor: Int64): Int64 {
    let target = min(max(0, cursor), source.size)
    let bytes = unsafe { source.rawData() }
    var offset: Int64 = 0
    var boundary: Int64 = 0
    while (offset < bytes.size && offset <= target) {
        boundary = offset
        let (_, length) = Rune.fromUtf8(bytes, offset)
        offset += length
    }
    if (target == source.size) { source.size } else { boundary }
}

func completionTarget(
    tokensBefore: Array<String>,
    activePrefix: String
): (CommandCompletionTarget, String) {
    if (tokensBefore.isEmpty()) {
        if (activePrefix.startsWith("/")) {
            return (CommandCompletionTarget.SlashCommand, "")
        }
        return (CommandCompletionTarget.Path, "")
    }
    let commandToken = tokensBefore[0]
    if (!commandToken.startsWith("/")) {
        return (CommandCompletionTarget.Path, "")
    }
    let authoredName = withoutSlash(commandToken)
    let definition = match (slashCommandDefinitionForCompletion(authoredName)) {
        case Some(value) => value
        case None => return (CommandCompletionTarget.Unavailable, authoredName)
    }
    let argumentsBefore: Array<String> = if (tokensBefore.size > 1) {
        tokensBefore[1..]
    } else {
        []
    }
    if (argumentsBefore.isEmpty() && !definition.subcommands.isEmpty()) {
        return (CommandCompletionTarget.Subcommand, definition.name)
    }
    if (completionPathPrefixMatches(definition.pathArgumentPrefixes, argumentsBefore)) {
        return (CommandCompletionTarget.Path, definition.name)
    }
    (CommandCompletionTarget.Unavailable, definition.name)
}

func slashCommandDefinitionForCompletion(name: String): ?SlashCommandDefinition {
    for (definition in slashCommandDefinitions()) {
        if (definition.name == name) {
            return Some(definition)
        }
        for (alias in definition.aliases where alias == name) {
            return Some(definition)
        }
    }
    None
}

func completionPathPrefixMatches(
    prefixes: Array<Array<String>>,
    argumentsBefore: Array<String>
): Bool {
    for (prefix in prefixes where prefix == argumentsBefore) {
        return true
    }
    false
}

func hasClosingQuote(source: String, cursor: Int64, tokenEnd: Int64): Bool {
    let bytes = unsafe { source.rawData() }
    var offset = cursor
    let end = min(tokenEnd, bytes.size)
    while (offset < end) {
        if (bytes[offset] == b'\\' && offset + 1 < end &&
            (bytes[offset + 1] == b'"' || bytes[offset + 1] == b'\\')) {
            offset += 2
            continue
        }
        if (bytes[offset] == b'"') {
            return true
        }
        offset++
    }
    false
}

func pathCandidateInsertText(
    plan: CommandCompletionPlan,
    candidate: CompletionCandidate
): String {
    let authored = candidate.insertText
    if (plan.quoteWrapped || plan.activeQuoted) {
        return escapeQuotedCompletionPath(authored)
    }
    escapeUnquotedCompletionPath(authored)
}

func escapeQuotedCompletionPath(path: String): String {
    let escaped = ArrayList<Byte>()
    for (byte in unsafe { path.rawData() }) {
        if (byte == b'"' || byte == b'\\') {
            escaped.add(b'\\')
        }
        escaped.add(byte)
    }
    String.fromUtf8(escaped.toArray())
}

func escapeUnquotedCompletionPath(path: String): String {
    let escaped = ArrayList<Byte>()
    for (byte in unsafe { path.rawData() }) {
        if (isCommandWhitespace(byte) || byte == b'"' || byte == b'\\') {
            escaped.add(b'\\')
        }
        escaped.add(byte)
    }
    String.fromUtf8(escaped.toArray())
}

func containsCompletionValue(
    candidates: ArrayList<CompletionCandidate>,
    value: String
): Bool {
    for (candidate in candidates where candidate.value == value) {
        return true
    }
    false
}

func completionCandidateBefore(
    left: CompletionCandidate,
    right: CompletionCandidate,
    normalizedPrefix: String,
    mode: CompletionMatchMode
): Bool {
    let leftNormalized = left.value.toAsciiLower()
    let rightNormalized = right.value.toAsciiLower()
    let containsMode = match (mode) {
        case CompletionMatchMode.Contains => true
        case CompletionMatchMode.Prefix => false
    }
    if (containsMode && normalizedPrefix != "") {
        let leftPrefix = leftNormalized.startsWith(normalizedPrefix)
        let rightPrefix = rightNormalized.startsWith(normalizedPrefix)
        if (leftPrefix != rightPrefix) {
            return leftPrefix
        }
    }
    if (leftNormalized != rightNormalized) {
        return leftNormalized < rightNormalized
    }
    left.value < right.value
}
