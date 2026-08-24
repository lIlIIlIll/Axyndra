package agent_product

import json4cj.*
import agent_domain.*
import std.collection.*
import std.convert.*
import std.fs.*

public class ProductThemeDefinition {
    public let name: String
    public let raised: String
    public let userMessageBg: String
    public let text: String
    public let muted: String
    public let accent: String
    public let secondary: String
    public let success: String
    public let warning: String
    public let danger: String
    public let userMessageText: String
    public let reasoning: String
    public let tool: String

    public init(
        name: String,
        raised: String,
        userMessageBg: String,
        text: String,
        muted: String,
        accent: String,
        secondary: String,
        success: String,
        warning: String,
        danger: String,
        userMessageText: String,
        reasoning: String,
        tool: String
    ) {
        this.name = name
        this.raised = raised
        this.userMessageBg = userMessageBg
        this.text = text
        this.muted = muted
        this.accent = accent
        this.secondary = secondary
        this.success = success
        this.warning = warning
        this.danger = danger
        this.userMessageText = userMessageText
        this.reasoning = reasoning
        this.tool = tool
    }
}

public func loadProductThemes(
    settingsRoot: String
): Result<Array<ProductThemeDefinition>> {
    let root = settingsRoot + "/themes"
    if (!exists(Path(root))) {
        return Result.Ok([])
    }
    try {
        let paths = ArrayList<String>()
        for (entry in Directory.readFrom(root)) {
            if (!entry.name.endsWith(".json")) { continue }
            let path = Path(root).join(entry.name).toString()
            if (FileInfo(Path(path)).isRegular()) { paths.add(path) }
        }
        sortThemePaths(paths)
        let themes = ArrayList<ProductThemeDefinition>()
        for (path in paths) {
            themes.add(parseProductTheme(
                String.fromUtf8(File.readFrom(path)),
                path
            ))
        }
        Result.Ok(themes.toArray())
    } catch (error: Exception) {
        Result.Err(AgentError(
            AgentErrorKind.Configuration,
            "theme.invalid",
            "cannot load theme configuration: " + error.message,
            fields: [ErrorField("path", root)]
        ))
    }
}

func parseProductTheme(source: String, path: String): ProductThemeDefinition {
    let root = parseJson(source)
    if (root.kind != JsonKind.Object) {
        throw IllegalArgumentException("theme root must be a JSON object: " + path)
    }
    let name = requiredThemeString(root, "name")
    if (!safeThemeName(name) || builtinThemeName(name)) {
        throw IllegalArgumentException(
            "theme name must be unique and contain letters, digits, '-' or '_': " + name
        )
    }
    let colors = requiredThemeObject(root, "colors")
    let variables = match (root.field("vars")) {
        case Some(value) =>
            if (value.kind != JsonKind.Object) {
                throw IllegalArgumentException("theme vars must be a JSON object: " + path)
            }
            value
        case None => JsonValue.objectValue([])
    }
    let selected = themeColor(colors, variables, "selectedBg", "")
    let pending = themeColor(colors, variables, "toolPendingBg", selected)
    let border = themeColor(colors, variables, "borderAccent", "")
    ProductThemeDefinition(
        name,
        pending,
        themeColor(colors, variables, "userMessageBg", ""),
        themeColor(colors, variables, "text", ""),
        themeColor(colors, variables, "muted", ""),
        themeColor(colors, variables, "accent", ""),
        themeColor(colors, variables, "mdLink", border),
        themeColor(colors, variables, "success", ""),
        themeColor(colors, variables, "warning", ""),
        themeColor(colors, variables, "error", ""),
        themeColor(colors, variables, "userMessageText", ""),
        themeColor(colors, variables, "thinkingText", ""),
        themeColor(colors, variables, "toolTitle", "")
    )
}

func requiredThemeObject(value: JsonValue, name: String): JsonValue {
    match (value.field(name)) {
        case Some(found) =>
            if (found.kind != JsonKind.Object) {
                throw IllegalArgumentException("theme field '" + name + "' must be an object")
            }
            found
        case None => throw IllegalArgumentException("theme field '" + name + "' is required")
    }
}

func requiredThemeString(value: JsonValue, name: String): String {
    match (value.field(name)) {
        case Some(found) =>
            if (found.kind != JsonKind.Text || found.text.trimAscii() == "") {
                throw IllegalArgumentException("theme field '" + name + "' must be a non-empty string")
            }
            found.text.trimAscii().toAsciiLower()
        case None => throw IllegalArgumentException("theme field '" + name + "' is required")
    }
}

func themeColor(
    colors: JsonValue,
    variables: JsonValue,
    name: String,
    fallback: String
): String {
    match (colors.field(name)) {
        case Some(value) => resolveThemeColor(value, variables, 0)
        case None => fallback
    }
}

func resolveThemeColor(
    value: JsonValue,
    variables: JsonValue,
    depth: Int64
): String {
    if (depth > 16) {
        throw IllegalArgumentException("theme variable reference is cyclic")
    }
    if (value.kind == JsonKind.Number) {
        let index = Int64.parse(value.text)
        if (index < 0 || index > 255) {
            throw IllegalArgumentException("theme palette index must be between 0 and 255")
        }
        return value.text
    }
    if (value.kind != JsonKind.Text) {
        throw IllegalArgumentException("theme colors must be strings or palette indexes")
    }
    let token = value.text.trimAscii()
    if (token == "" || token.startsWith("#")) { return token }
    match (variables.field(token)) {
        case Some(next) => resolveThemeColor(next, variables, depth + 1)
        case None => throw IllegalArgumentException("unknown theme color variable: " + token)
    }
}

func safeThemeName(value: String): Bool {
    if (value == "") { return false }
    for (byte in value.toArray()) {
        if (!((byte >= b'a' && byte <= b'z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'-' || byte == b'_')) {
            return false
        }
    }
    true
}

func builtinThemeName(value: String): Bool {
    value == "omp" || value == "dark" || value == "light" || value == "mono"
}

func sortThemePaths(values: ArrayList<String>): Unit {
    var index: Int64 = 1
    while (index < values.size) {
        var current = index
        while (current > 0 && values[current] < values[current - 1]) {
            let previous = values[current - 1]
            values[current - 1] = values[current]
            values[current] = previous
            current--
        }
        index++
    }
}
