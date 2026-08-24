package agent_mcp

import agent_domain.*
import std.collection.*
import std.convert.*
import std.sync.*

public class McpToolAlias {
    public let alias: String
    public let serverId: String
    public let toolName: String

    public init(alias: String, serverId: String, toolName: String) {
        this.alias = alias
        this.serverId = serverId
        this.toolName = toolName
    }
}

public class McpToolAliasRegistry {
    private let values = ArrayList<McpToolAlias>()
    private let lock = Mutex()

    public init() {}

    public func register(serverId: String, toolName: String): Result<McpToolAlias> {
        if (serverId.trimAscii() == "" || toolName.trimAscii() == "") {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "mcp.tool_identity_empty",
                "MCP server id and tool name must not be empty"
            ))
        }
        lock.lock()
        try {
            for (item in values where item.serverId == serverId && item.toolName == toolName) {
                return Result.Ok(item)
            }
            let base = mcpToolAlias(serverId, toolName)
            var alias = base
            for (item in values where item.alias == alias) {
                alias = mcpToolAliasWithHash(serverId, toolName)
                break
            }
            for (item in values where item.alias == alias) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "mcp.tool_alias_collision",
                    "MCP tool alias collision could not be resolved",
                    fields: [ErrorField("alias", alias)]
                ))
            }
            let mapped = McpToolAlias(alias, serverId, toolName)
            values.add(mapped)
            Result.Ok(mapped)
        } finally {
            lock.unlock()
        }
    }

    public func resolve(alias: String): ?McpToolAlias {
        lock.lock()
        try {
            for (item in values where item.alias == alias) { return Some(item) }
            None
        } finally {
            lock.unlock()
        }
    }

    public func snapshot(): Array<McpToolAlias> {
        lock.lock()
        try { values.toArray() } finally { lock.unlock() }
    }
}

public func mcpToolAlias(serverId: String, toolName: String): String {
    let base = "mcp__" + sanitizeAliasPart(serverId) + "__" + sanitizeAliasPart(toolName)
    if (base.size <= 64) { return base }
    mcpToolAliasWithHash(serverId, toolName)
}

func mcpToolAliasWithHash(serverId: String, toolName: String): String {
    let suffix = "_" + stableAliasHash(serverId + "\u{0}" + toolName)
    let base = "mcp__" + sanitizeAliasPart(serverId) + "__" + sanitizeAliasPart(toolName)
    let keep = 64 - suffix.size
    let prefix = if (base.size <= keep) { base } else { base[..keep] }
    prefix + suffix
}

func sanitizeAliasPart(source: String): String {
    let output = ArrayList<Byte>()
    var separator = false
    for (byte in unsafe { source.rawData() }) {
        if ((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'_') {
            output.add(byte)
            separator = false
        } else if (!separator) {
            output.add(b'_')
            separator = true
        }
    }
    while (!output.isEmpty() && output[output.size - 1] == b'_') {
        output.remove(at: output.size - 1)
    }
    if (output.isEmpty()) { return "tool" }
    String.fromUtf8(output.toArray())
}

func stableAliasHash(source: String): String {
    var value: Int64 = 2166136261
    for (byte in unsafe { source.rawData() }) {
        value = (value * 16777619 + Int64(byte)) % 4294967291
    }
    var text = value.toString(radix: 16)
    while (text.size < 8) { text = "0" + text }
    if (text.size > 8) { text = text[text.size - 8..] }
    text
}
