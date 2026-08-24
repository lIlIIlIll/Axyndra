package agent_cli

import agent_domain.*
import std.collection.*

public enum CliCommandVisibility {
    Public | Hidden | Internal
}

public class CliOutput {
    public let exitCode: Int64
    public let stdout: String
    public let stderr: String
    public let structured: ?AgentValue

    public init(
        exitCode!: Int64 = 0,
        stdout!: String = "",
        stderr!: String = "",
        structured!: ?AgentValue = None
    ) {
        this.exitCode = exitCode
        this.stdout = stdout
        this.stderr = stderr
        this.structured = structured
    }
}

public type CliCommandHandler = (Array<String>) -> Result<CliOutput>

public class CliCommandSpec {
    public let name: String
    public let aliases: Array<String>
    public let description: String
    public let visibility: CliCommandVisibility
    public let flags: Array<String>
    public let handler: CliCommandHandler

    public init(
        name: String,
        description: String,
        handler: CliCommandHandler,
        aliases!: Array<String> = [],
        visibility!: CliCommandVisibility = CliCommandVisibility.Public,
        flags!: Array<String> = []
    ) {
        if (name.trimAscii() == "") {
            throw IllegalArgumentException("CLI command name must not be empty")
        }
        this.name = name
        this.aliases = aliases
        this.description = description
        this.visibility = visibility
        this.flags = flags
        this.handler = handler
    }
}

public class CliCommandRegistry {
    private let specs: Array<CliCommandSpec>

    public init(specs: Array<CliCommandSpec>) {
        for (index in 0..specs.size) {
            for (other in index + 1..specs.size) {
                if (specs[index].name == specs[other].name) {
                    throw IllegalArgumentException(
                        "duplicate CLI command: " + specs[index].name
                    )
                }
            }
        }
        this.specs = specs
    }

    public func resolve(authored: String): ?CliCommandSpec {
        for (spec in specs) {
            if (spec.name == authored) { return Some(spec) }
            for (alias in spec.aliases where alias == authored) {
                return Some(spec)
            }
        }
        None
    }

    public func isReserved(authored: String): Bool {
        resolve(authored).isSome()
    }

    public func reservedNames(): Array<String> {
        let names = ArrayList<String>()
        for (spec in specs) { names.add(spec.name) }
        names.toArray()
    }

    public func visibleCommands(): Array<CliCommandSpec> {
        let values = ArrayList<CliCommandSpec>()
        for (spec in specs) {
            match (spec.visibility) {
                case CliCommandVisibility.Public => values.add(spec)
                case _ => ()
            }
        }
        values.toArray()
    }

    public func dispatch(
        authored: String,
        arguments: Array<String>
    ): Result<CliOutput> {
        match (resolve(authored)) {
            case Some(spec) => spec.handler(arguments)
            case None => Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "cli.unknown_command",
                "unknown CLI command",
                fields: [ErrorField("command", authored)]
            ))
        }
    }
}

public func reservedCliCommandRegistry(): CliCommandRegistry {
    let unavailable: CliCommandHandler = { _: Array<String> =>
        Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "cli.handler_unbound",
            "CLI command handler is not bound"
        ))
    }
    CliCommandRegistry([
        CliCommandSpec("launch", "Start the agent", unavailable),
        CliCommandSpec("acp", "Run the ACP v1 stdio server", unavailable),
        CliCommandSpec("auth-broker", "Manage the credential broker", unavailable,
            visibility: CliCommandVisibility.Hidden),
        CliCommandSpec("auth-gateway", "Run the provider gateway", unavailable,
            visibility: CliCommandVisibility.Hidden),
        CliCommandSpec("agents", "Manage bundled agents", unavailable),
        CliCommandSpec("bench", "Benchmark model requests", unavailable,
            visibility: CliCommandVisibility.Hidden),
        CliCommandSpec("cleanse", "Repair workspace diagnostics", unavailable,
            visibility: CliCommandVisibility.Hidden),
        CliCommandSpec("commit", "Generate a repository commit", unavailable,
            visibility: CliCommandVisibility.Hidden),
        CliCommandSpec("completions", "Print shell completions", unavailable),
        CliCommandSpec(
            "__complete",
            "Resolve dynamic completions",
            unavailable,
            visibility: CliCommandVisibility.Internal
        ),
        CliCommandSpec(
            "__process-broker-worker",
            "Run the workspace process broker",
            unavailable,
            visibility: CliCommandVisibility.Internal
        ),
        CliCommandSpec(
            "__process-broker-client",
            "Call the workspace process broker",
            unavailable,
            visibility: CliCommandVisibility.Internal
        ),
        CliCommandSpec("config", "Inspect or update configuration", unavailable),
        CliCommandSpec("dry-balance", "Simulate credential balancing", unavailable,
            visibility: CliCommandVisibility.Hidden),
        CliCommandSpec("gc", "Run storage garbage collection", unavailable),
        CliCommandSpec("grep", "Search workspace contents", unavailable),
        CliCommandSpec("gallery", "Render transcript cards", unavailable),
        CliCommandSpec("grievances", "Inspect failure reports", unavailable),
        CliCommandSpec("install", "Install or link plugins", unavailable,
            visibility: CliCommandVisibility.Hidden),
        CliCommandSpec(
            "join",
            "Join a collaboration session",
            unavailable,
            visibility: CliCommandVisibility.Hidden
        ),
        CliCommandSpec("models", "List configured models", unavailable),
        CliCommandSpec("mcp-server", "Expose product tools over MCP stdio", unavailable),
        CliCommandSpec(
            "reviewer-dry-run",
            "Run no-tools approval reviewer fixtures",
            unavailable,
            visibility: CliCommandVisibility.Internal
        ),
        CliCommandSpec("plugin", "Manage plugins", unavailable,
            visibility: CliCommandVisibility.Hidden),
        CliCommandSpec("say", "Synthesize speech", unavailable,
            visibility: CliCommandVisibility.Hidden),
        CliCommandSpec("setup", "Configure providers and models", unavailable),
        CliCommandSpec("shell", "Open a persistent shell", unavailable),
        CliCommandSpec("read", "Read a workspace file", unavailable),
        CliCommandSpec("ssh", "Manage SSH hosts", unavailable),
        CliCommandSpec("stats", "View usage statistics", unavailable),
        CliCommandSpec(
            "update",
            "Upgrade installed plugins",
            unavailable,
            visibility: CliCommandVisibility.Hidden
        ),
        CliCommandSpec("usage", "Show provider usage limits", unavailable),
        CliCommandSpec("tiny-models", "Manage pinned model assets", unavailable,
            visibility: CliCommandVisibility.Hidden),
        CliCommandSpec("token", "Print a provider credential", unavailable),
        CliCommandSpec("ttsr", "Scan text transformation rules", unavailable,
            visibility: CliCommandVisibility.Hidden),
        CliCommandSpec(
            "worktree",
            "Manage isolated worktrees",
            unavailable,
            aliases: ["wt"]
        ),
        CliCommandSpec(
            "search",
            "Test web search providers",
            unavailable,
            aliases: ["q"]
        )
    ])
}
