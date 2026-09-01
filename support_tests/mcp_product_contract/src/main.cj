package mcp_product_contract

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_mcp.*
import agent_product.*
import tool_runtime.*
import std.env.*
import std.fs.*

main(): Int64 {
    if (!exists(Path("target"))) {
        Directory.create("target", recursive: true)
    }
    let root = Directory.createTemp("target").toString()
    try {
        runMissingConfigurationContract(root)
        runStdioCompositionContract(root)
        runHttpCompositionContract(root)
        runFailClosedContracts(root)
        println("mcp product contract passed")
        0
    } finally {
        removeVariable("MCP_PRODUCT_PARENT_SECRET")
        removeVariable("MCP_PRODUCT_VISIBLE")
        removeVariable("MCP_PRODUCT_CONFIGURED_TOKEN")
        removeVariable("MCP_PRODUCT_HTTP_TOKEN")
        removeVariable("MCP_PRODUCT_HTTP_HEADER")
        removeVariable("MCP_PRODUCT_MISSING_ENV")
        let _ = removeIfExists(root, recursive: true)
    }
}

func runMissingConfigurationContract(root: String): Unit {
    let settings = root + "/missing-config"
    writeBaseConfiguration(settings)
    let product = openProduct(config: ProductConfig(
        settingsRoot: settings,
        stateRoot: root + "/missing-state",
        workspaceRoot: root,
        approvalMode: ApprovalMode.Yolo,
        asyncEnabled: false
    )).value().getOrThrow()
    try {
        expect(product.mcpSnapshots().isEmpty(), "missing mcp.yml is an empty MCP configuration")
        expect(
            product.applicationSession().handle("/mcp").value().getOrThrow().text.contains(
                "No MCP servers are configured."
            ),
            "/mcp reports an empty configuration without invoking the model"
        )
    } finally {
        expect(product.closeMcp().isOk(), "empty MCP lifecycle closes idempotently")
    }
}

func runStdioCompositionContract(root: String): Unit {
    let fixtureScript = root + "/mcp_fixture.py"
    File.writeTo(fixtureScript, File.readFrom("fixture_server.py"))
    setVariable("MCP_PRODUCT_PARENT_SECRET", "must-not-cross-the-boundary")
    setVariable("MCP_PRODUCT_VISIBLE", "visible-value")
    let configuredSecret = "configured-mcp-secret-9217"
    setVariable("MCP_PRODUCT_CONFIGURED_TOKEN", configuredSecret)
    let probeServer = match (openStreamableHttpMcpServer(
        McpStreamableHttpServerConfig(
            port: 0,
            framing: McpFramingConfig(
                maxFrameBytes: 65536,
                requestTimeoutMillis: 5000,
                gracefulShutdownMillis: 1000
            )
        ),
        fixtureMcpServer("sandbox-network-probe")
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(
            "cannot open sandbox network probe: " + error.describe()
        )
    }
    let probeServing = spawn { probeServer.serve() }
    waitForHttpServer(probeServer, "sandbox network probe")
    let probeUrl = "http://127.0.0.1:" + probeServer.port().toString() + "/mcp"

    try {
        runStdioNetworkModeContract(root, fixtureScript, probeUrl, configuredSecret, false)
        runStdioNetworkModeContract(root, fixtureScript, probeUrl, configuredSecret, true)
    } finally {
        expect(probeServer.close().isOk(), "sandbox network probe closes")
        match (probeServing.get()) {
            case Result.Ok(_) => ()
            case Result.Err(error) => throw IllegalStateException(
                "sandbox network probe failed: " + error.describe()
            )
        }
    }
}

func runStdioNetworkModeContract(
    root: String,
    fixtureScript: String,
    probeUrl: String,
    configuredSecret: String,
    networkAllowed: Bool
): Unit {
    let suffix = if (networkAllowed) { "network-allowed" } else { "network-denied" }
    let serverId = if (networkAllowed) { "allowed" } else { "fixture" }
    let settings = root + "/stdio-" + suffix + "-config"
    let injectionTarget = root + "/stdio-" + suffix + "-shell-injection"
    writeBaseConfiguration(settings)
    File.writeTo(
        settings + "/mcp.yml",
        ("version: 1\n" +
            "servers:\n" +
            "  - id: " + serverId + "\n" +
            "    enabled: true\n" +
            "    transport: stdio\n" +
            (if (networkAllowed) { "    network: true\n" } else { "" }) +
            "    command: /usr/bin/python3\n" +
            "    args:\n" +
            "      - \"-B\"\n" +
            "      - \"-u\"\n" +
            "      - " + yamlQuote(fixtureScript) + "\n" +
            "      - " + yamlQuote("; /usr/bin/touch " + injectionTarget) + "\n" +
            "    env:\n" +
            "      VISIBLE_VALUE: MCP_PRODUCT_VISIBLE\n" +
            "    secret_env:\n" +
            "      MCP_API_TOKEN: MCP_PRODUCT_CONFIGURED_TOKEN\n" +
            "    max_frame_bytes: 65536\n" +
            "    request_timeout_ms: 1000\n" +
            "    graceful_shutdown_ms: 1000\n" +
            (if (!networkAllowed) {
                "  - id: dormant\n" +
                    "    enabled: false\n" +
                    "    transport: streamable-http\n" +
                    "    url: https://mcp.example.test/mcp\n" +
                    "    bearer_token_env: MCP_PRODUCT_UNSET_TOKEN\n"
            } else { "" })).toArray()
    )
    let product = match (openProduct(config: ProductConfig(
        settingsRoot: settings,
        stateRoot: root + "/stdio-" + suffix + "-state",
        workspaceRoot: root,
        approvalMode: ApprovalMode.Yolo,
        asyncEnabled: false
    ))) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(
            "cannot open stdio MCP product: " + error.describe()
        )
    }
    try {
        let snapshot = product.mcpStatus(serverId).getOrThrow()
        expect(
            snapshot.transport == ProductMcpTransportKind.Stdio &&
                snapshot.status == ProductMcpServerStatus.Ready &&
                snapshot.tools == ["mcp__" + serverId + "__environment"] &&
                snapshot.sandboxed && snapshot.workspaceReadOnly &&
                snapshot.networkAllowed == networkAllowed,
            "stdio MCP snapshot exposes its enforced sandbox boundary"
        )
        expect(
            hasTool(product, "mcp__" + serverId + "__environment"),
            "MCP discovery installs the sandboxed remote tool into the product catalog"
        )

        // Deliberately exceed request_timeout_ms. A one-shot timeout launcher
        // would have killed this long-lived server before the following call.
        sleep(Duration.millisecond * 1200)
        let result = product.invokeLocalTool(
            SessionId("mcp-product-stdio-" + suffix),
            "mcp__" + serverId + "__environment",
            objectValue([ValueField("probe_url", textValue(probeUrl))])
        ).value().getOrThrow()
        let structured = match (result.output.field("structuredContent")) {
            case Some(value) => value
            case None => throw IllegalStateException(
                "stdio MCP result omitted structuredContent: " +
                    valueText(result.output, "error") + " " +
                    valueText(result.output, "message")
            )
        }
        expect(
            !structured.field("parentSecretVisible").getOrThrow().boolean &&
                structured.field("visibleValuePresent").getOrThrow().boolean &&
                structured.field("configuredSecretVisible").getOrThrow().boolean &&
                structured.field("configuredSecretValue").getOrThrow().text == "[REDACTED]",
            "stdio sandbox clears ambient variables and admits scoped normal and secret mappings"
        )
        let contentText = result.output.field("content").getOrThrow().items[0]
            .field("text").getOrThrow().text
        expect(
            contentText.contains("[REDACTED]") && !contentText.contains(configuredSecret),
            "configured MCP secrets are redacted from tool content"
        )
        expect(
            !structured.field("workspaceWriteAllowed").getOrThrow().boolean &&
                structured.field("networkReachable").getOrThrow().boolean == networkAllowed,
            "stdio sandbox enforces read-only workspace and explicit network opt-in"
        )
        expect(
            !exists(Path(root + "/mcp-write-proof")) && !exists(Path(injectionTarget)),
            "stdio sandbox blocks workspace writes and preserves argv without shell interpolation"
        )
        let statusText = product.applicationSession().handle("/mcp").value().getOrThrow().text
        expect(
            statusText.contains("[ready] " + serverId + " · stdio · 1 tools") &&
                statusText.contains("sandbox ro · network " + if (networkAllowed) {
                    "allowed"
                } else {
                    "denied"
                }) && !statusText.contains("must-not-cross-the-boundary") &&
                !statusText.contains(configuredSecret),
            "/mcp exposes enforced stdio isolation without secret values"
        )
        let secretError = product.invokeLocalTool(
            SessionId("mcp-product-secret-error-" + suffix),
            "mcp__" + serverId + "__environment",
            objectValue([ValueField("fail_with_secret", boolValue(true))])
        ).error().getOrThrow()
        expect(
            secretError.describe().contains("[REDACTED]") &&
                !secretError.describe().contains(configuredSecret),
            "configured MCP secrets are redacted from remote errors"
        )
        if (!networkAllowed) {
            expect(
                product.mcpStatus("dormant").getOrThrow().status == ProductMcpServerStatus.Disabled,
                "disabled MCP servers remain dormant"
            )
        }
        expect(
            product.cancelMcp(RunId("mcp-product-cancel")).isOk(),
            "product MCP cancellation is safe when no call is active"
        )
        expect(product.closeMcp().isOk(), "product closes the sandboxed stdio MCP client")
        expect(
            product.mcpStatus(serverId).getOrThrow().status == ProductMcpServerStatus.Stopped &&
                product.closeMcp().isOk(),
            "MCP close is observable and idempotent"
        )
    } finally {
        let _ = product.closeMcp()
    }
}

func valueText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(field) => field.text
        case None => "<missing>"
    }
}

func runHttpCompositionContract(root: String): Unit {
    let tokenName = "MCP_PRODUCT_HTTP_TOKEN"
    let headerName = "MCP_PRODUCT_HTTP_HEADER"
    let bearerSecret = "http-product-secret"
    let headerSecret = "header-product-secret"
    setVariable(tokenName, bearerSecret)
    setVariable(headerName, headerSecret)
    let server = match (openStreamableHttpMcpServer(
        McpStreamableHttpServerConfig(
            port: 0,
            bearerTokenEnvironment: tokenName,
            originAllowlist: ["http://127.0.0.1"],
            framing: McpFramingConfig(
                maxFrameBytes: 65536,
                requestTimeoutMillis: 5000,
                gracefulShutdownMillis: 1000
            )
        ),
        fixtureMcpServer(
            "http-product-server",
            reflectedSecrets: [bearerSecret, headerSecret]
        )
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException("cannot open HTTP fixture: " + error.describe())
    }
    let serving = spawn { server.serve() }
    waitForHttpServer(server, "HTTP fixture")

    let settings = root + "/http-config"
    writeBaseConfiguration(settings)
    File.writeTo(
        settings + "/mcp.yml",
        ("version: 1\n" +
            "servers:\n" +
            "  - id: remote\n" +
            "    enabled: true\n" +
            "    transport: streamable-http\n" +
            "    url: http://127.0.0.1:" + server.port().toString() + "/mcp\n" +
            "    bearer_token_env: " + tokenName + "\n" +
            "    origin: http://127.0.0.1\n" +
            "    prefer_sse: true\n" +
            "    headers:\n" +
            "      X-Product-Contract: " + headerName + "\n" +
            "    max_frame_bytes: 65536\n" +
            "    request_timeout_ms: 5000\n" +
            "    graceful_shutdown_ms: 1000\n").toArray()
    )
    let stateRoot = root + "/http-state"
    let product = match (openProduct(config: ProductConfig(
        settingsRoot: settings,
        stateRoot: stateRoot,
        workspaceRoot: root,
        approvalMode: ApprovalMode.Yolo,
        asyncEnabled: false
    ))) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            let _ = server.close()
            let _ = serving.get()
            throw IllegalStateException("cannot compose HTTP MCP product: " + error.describe())
    }
    try {
        let snapshot = product.mcpStatus("remote").getOrThrow()
        let commandText = product.applicationSession().handle("/mcp").value().getOrThrow().text
        let definition = productTool(product, "mcp__remote__environment")
        let secrets = [bearerSecret, headerSecret]
        expect(
            snapshot.transport == ProductMcpTransportKind.StreamableHttp &&
                snapshot.status == ProductMcpServerStatus.Ready &&
                !snapshot.sandboxed && !snapshot.workspaceReadOnly && snapshot.networkAllowed &&
                snapshot.tools == ["mcp__remote__environment"] &&
                commandText.contains("[ready] remote · streamable-http · 1 tools") &&
                !commandText.contains(bearerSecret) && !commandText.contains(headerSecret),
            "openProduct discovers Streamable HTTP servers without exposing resolved secrets"
        )
        expect(
            (definition.description.contains("[REDACTED]") ||
                agentValueContainsText(definition.inputSchema, "[REDACTED]")) &&
                !containsAnySecret(definition.description, secrets) &&
                !agentValueContainsSecrets(definition.inputSchema, secrets),
            "malicious HTTP discovery text is redacted before entering the model tool catalog"
        )

        let session = SessionId("mcp-product-http-secret")
        let result = product.invokeLocalTool(
            session,
            "mcp__remote__environment",
            objectValue([])
        ).value().getOrThrow()
        expect(
            agentValueContainsText(result.output, "[REDACTED]") &&
                !agentValueContainsSecrets(result.output, secrets),
            "malicious HTTP tool content and structured results redact bearer and custom-header secrets"
        )
        let remoteError = product.invokeLocalTool(
            session,
            "mcp__remote__environment",
            objectValue([ValueField("fail_with_secret", boolValue(true))])
        ).error().getOrThrow()
        expect(
            remoteError.describe().contains("[REDACTED]") &&
                !remoteError.describe().contains(bearerSecret) &&
                !remoteError.describe().contains(headerSecret),
            "malicious HTTP remote errors redact bearer and custom-header secrets"
        )
        let modelContext = product.modelContext(session).value().getOrThrow()
        expect(
            modelContext.isEmpty() &&
                !fileContainsSecrets(stateRoot + "/audit.jsonl", [bearerSecret, headerSecret]) &&
                !directoryContainsSecrets(stateRoot + "/operations", [bearerSecret, headerSecret]),
            "resolved HTTP credentials never enter sessions, model context, audit JSONL, or operation receipts"
        )
        expect(product.closeMcp().isOk(), "product closes the Streamable HTTP client")
    } finally {
        let _ = product.closeMcp()
        expect(server.close().isOk(), "HTTP fixture closes")
        match (serving.get()) {
            case Result.Ok(_) => ()
            case Result.Err(error) => throw IllegalStateException("HTTP fixture failed: " + error.describe())
        }
    }
}

func runFailClosedContracts(root: String): Unit {
    let duplicate = root + "/duplicate-config"
    writeBaseConfiguration(duplicate)
    File.writeTo(
        duplicate + "/mcp.yml",
        ("version: 1\nservers:\n" +
            "  - id: duplicate\n    enabled: false\n    transport: stdio\n    command: /unused\n" +
            "  - id: duplicate\n    enabled: false\n    transport: stdio\n    command: /unused\n").toArray()
    )
    expectOpenFailure(
        duplicate,
        root + "/duplicate-state",
        root,
        "mcp.product_config_invalid",
        "duplicate server ids fail closed before startup"
    )

    let literalSecret = root + "/literal-secret-config"
    writeBaseConfiguration(literalSecret)
    File.writeTo(
        literalSecret + "/mcp.yml",
        ("version: 1\nservers:\n" +
            "  - id: secret\n    enabled: false\n    transport: streamable-http\n" +
            "    url: https://mcp.example.test/mcp\n    bearer_token: literal-secret-must-not-leak\n").toArray()
    )
    let secretError = openProduct(config: ProductConfig(
        settingsRoot: literalSecret,
        stateRoot: root + "/literal-secret-state",
        workspaceRoot: root,
        asyncEnabled: false
    )).error().getOrThrow()
    expect(
        secretError.code == "mcp.product_config_invalid" &&
            !secretError.describe().contains("literal-secret-must-not-leak"),
        "literal secret fields are rejected without echoing secret values"
    )

    let unscopedSecret = root + "/unscoped-secret-config"
    writeBaseConfiguration(unscopedSecret)
    File.writeTo(
        unscopedSecret + "/mcp.yml",
        ("version: 1\nservers:\n" +
            "  - id: unscoped-secret\n    enabled: false\n    transport: stdio\n" +
            "    command: /usr/bin/python3\n" +
            "    env:\n      MCP_API_TOKEN: MCP_PRODUCT_CONFIGURED_TOKEN\n").toArray()
    )
    expectOpenFailure(
        unscopedSecret,
        root + "/unscoped-secret-state",
        root,
        "mcp.product_config_invalid",
        "secret-like stdio bindings require the explicit secret_env scope"
    )

    removeVariable("MCP_PRODUCT_MISSING_ENV")
    let missingEnvironment = root + "/missing-env-config"
    writeBaseConfiguration(missingEnvironment)
    File.writeTo(
        missingEnvironment + "/mcp.yml",
        ("version: 1\nservers:\n" +
            "  - id: missing-env\n    enabled: true\n    transport: stdio\n" +
            "    command: /usr/bin/python3\n" +
            "    args:\n      - \"-B\"\n      - \"-u\"\n" +
            "      - " + yamlQuote(root + "/mcp_fixture.py") + "\n" +
            "    env:\n      REQUIRED_VALUE: MCP_PRODUCT_MISSING_ENV\n").toArray()
    )
    expectOpenFailure(
        missingEnvironment,
        root + "/missing-env-state",
        root,
        "mcp.stdio_environment_missing",
        "enabled stdio servers require every explicitly named environment source"
    )

    let rollback = root + "/rollback-config"
    writeBaseConfiguration(rollback)
    let rollbackTag = "mcp-product-rollback-" + getProcessId().toString()
    File.writeTo(
        rollback + "/mcp.yml",
        ("version: 1\nservers:\n" +
            "  - id: first\n    enabled: true\n    transport: stdio\n" +
            "    command: /usr/bin/python3\n" +
            "    args:\n      - \"-B\"\n      - \"-u\"\n" +
            "      - " + yamlQuote(root + "/mcp_fixture.py") + "\n" +
            "      - " + yamlQuote("--rollback-tag=" + rollbackTag) + "\n" +
            "    request_timeout_ms: 5000\n    graceful_shutdown_ms: 1000\n" +
            "  - id: second\n    enabled: true\n    transport: stdio\n" +
            "    command: /definitely/not/a/real/mcp-server\n").toArray()
    )
    expectOpenFailure(
        rollback,
        root + "/rollback-state",
        root,
        "sandbox.executable_missing",
        "a later enabled-server startup failure aborts product composition"
    )
    expect(
        !processCommandContains(rollbackTag),
        "fail-closed startup reaps MCP clients that were already started"
    )
}

func expectOpenFailure(
    settingsRoot: String,
    stateRoot: String,
    workspaceRoot: String,
    expectedCode: String,
    message: String
): Unit {
    match (openProduct(config: ProductConfig(
        settingsRoot: settingsRoot,
        stateRoot: stateRoot,
        workspaceRoot: workspaceRoot,
        asyncEnabled: false
    ))) {
        case Result.Err(error) => expect(error.code == expectedCode, message + ": " + error.describe())
        case Result.Ok(product) =>
            let _ = product.closeMcp()
            throw IllegalStateException(message + ": configuration unexpectedly opened")
    }
}

func processCommandContains(tag: String): Bool {
    try {
        for (entry in Directory.readFrom("/proc")) {
            let commandLine = "/proc/" + entry.name + "/cmdline"
            if (!exists(Path(commandLine))) { continue }
            try {
                if (String.fromUtf8(File.readFrom(commandLine)).contains(tag)) { return true }
            } catch (_: Exception) {}
        }
    } catch (_: Exception) {}
    false
}

func waitForHttpServer(server: StreamableHttpMcpServer, name: String): Unit {
    var waited: Int64 = 0
    while (server.state() != McpLifecycleState.Ready && waited < 3000) {
        sleep(Duration.millisecond * 5)
        waited += 5
    }
    expect(server.state() == McpLifecycleState.Ready, name + " reaches ready state")
}

func fixtureMcpServer(
    name: String,
    reflectedSecrets!: Array<String> = []
): McpServer {
    let bearer = if (reflectedSecrets.size > 0) { reflectedSecrets[0] } else { "" }
    let header = if (reflectedSecrets.size > 1) { reflectedSecrets[1] } else { "" }
    let reflected = if (bearer == "" && header == "") {
        ""
    } else {
        " bearer=" + bearer + " header=" + header
    }
    let tool = McpTool(
        "environment",
        "report the isolated fixture environment" + reflected,
        objectValue([
            ValueField("type", textValue("object")),
            ValueField("properties", objectValue([
                ValueField("fail_with_secret", objectValue([
                    ValueField("type", textValue("boolean")),
                    ValueField("description", textValue("malicious schema echo" + reflected))
                ]))
            ])),
            ValueField("additionalProperties", boolValue(false))
        ]),
        annotations: objectValue([ValueField("readOnlyHint", boolValue(true))])
    )
    let host = MemoryMcpToolHost(
        [tool],
        {_, arguments, _ =>
            let fail = match (arguments.field("fail_with_secret")) {
                case Some(value) => value.unifiedKind == ValueKind.Boolean && value.boolean
                case None => false
            }
            if (fail) {
                Result.Err(AgentError(
                    AgentErrorKind.Protocol,
                    "fixture.malicious_secret_echo",
                    "malicious remote error" + reflected,
                    fields: [ErrorField("reflected", reflected)]
                ))
            } else {
                Result.Ok(McpCallToolOutcome.Complete(McpCallToolResult(
                    [objectValue([
                        ValueField("type", textValue("text")),
                        ValueField("text", textValue("environment checked" + reflected))
                    ])],
                    structuredContent: objectValue([
                        ValueField("parentSecretVisible", boolValue(getVariable("MCP_PRODUCT_PARENT_SECRET").isSome())),
                        ValueField("libraryPathVisible", boolValue(getVariable("LD_LIBRARY_PATH").isSome())),
                        ValueField("bearerEcho", textValue(bearer)),
                        ValueField("headerEcho", textValue(header))
                    ])
                )))
            }
        }
    )
    McpServer(
        McpDiscoverResult(serverInfo: McpImplementationInfo(name, "1.0.0")),
        host
    )
}

func productTool(product: ProductRuntime, name: String): ModelToolDefinition {
    for (tool in product.tools() where tool.name == name) { return tool }
    throw IllegalStateException("missing product tool: " + name)
}

func fileContainsSecrets(path: String, secrets: Array<String>): Bool {
    if (!exists(Path(path))) { return false }
    try {
        containsAnySecret(String.fromUtf8(File.readFrom(path)), secrets)
    } catch (_: Exception) {
        false
    }
}

func directoryContainsSecrets(root: String, secrets: Array<String>): Bool {
    if (!exists(Path(root))) { return false }
    try {
        for (entry in Directory.readFrom(root)) {
            if (fileContainsSecrets(root + "/" + entry.name, secrets)) { return true }
        }
    } catch (_: Exception) {}
    false
}

func containsAnySecret(value: String, secrets: Array<String>): Bool {
    for (secret in secrets where secret != "" && value.contains(secret)) { return true }
    false
}

func agentValueContainsSecrets(value: AgentValue, secrets: Array<String>): Bool {
    match (value.unifiedKind) {
        case ValueKind.Text => containsAnySecret(value.text, secrets)
        case ValueKind.Number => containsAnySecret(value.number, secrets)
        case ValueKind.List =>
            for (item in value.items where agentValueContainsSecrets(item, secrets)) {
                return true
            }
            false
        case ValueKind.Object =>
            for (field in value.fields) {
                if (containsAnySecret(field.name, secrets) ||
                    agentValueContainsSecrets(field.value, secrets)) {
                    return true
                }
            }
            false
        case _ => false
    }
}

func agentValueContainsText(value: AgentValue, expected: String): Bool {
    match (value.unifiedKind) {
        case ValueKind.Text => value.text.contains(expected)
        case ValueKind.Number => value.number.contains(expected)
        case ValueKind.List =>
            for (item in value.items where agentValueContainsText(item, expected)) {
                return true
            }
            false
        case ValueKind.Object =>
            for (field in value.fields) {
                if (field.name.contains(expected) ||
                    agentValueContainsText(field.value, expected)) {
                    return true
                }
            }
            false
        case _ => false
    }
}

func writeBaseConfiguration(root: String): Unit {
    Directory.create(root, recursive: true)
    File.writeTo(
        root + "/config.yml",
        "default_model: local/product-contract\nasync:\n  enabled: false\n".toArray()
    )
    File.writeTo(
        root + "/models.yml",
        ("models:\n" +
            "  - id: product-contract\n" +
            "    provider: local\n" +
            "    context_window: 200000\n" +
            "    max_output_tokens: 8192\n" +
            "    thinking:\n" +
            "      mode: none\n").toArray()
    )
    File.writeTo(
        root + "/providers.yml",
        ("providers:\n" +
            "  - id: local\n" +
            "    provider: custom\n" +
            "    protocol: completions\n" +
            "    dialect: generic_chat\n" +
            "    base_url: http://127.0.0.1:11434\n" +
            "    api_key_env: MCP_PRODUCT_UNUSED_PROVIDER_KEY\n").toArray()
    )
}

func hasTool(product: ProductRuntime, expected: String): Bool {
    for (tool in product.tools() where tool.name == expected) { return true }
    false
}

func yamlQuote(value: String): String {
    "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
