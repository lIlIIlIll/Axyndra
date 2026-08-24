package direct_runtime_sandbox_contract

import agent_domain.*
import agent_product.*
import model_adapters.*
import tool_runtime.*
import std.env.*
import std.fs.*

main(): Int64 {
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    let root = Directory.createTemp("target").toString()
    setVariable("DIRECT_RUNTIME_PARENT_SECRET", "direct-runtime-secret-9381")
    try {
        prepare(root)
        runFixtureSandboxEnforced(root)
        let product = openProduct(config: ProductConfig(
            settingsRoot: root + "/config",
            stateRoot: root + "/state",
            workspaceRoot: root + "/workspace",
            approvalMode: ApprovalMode.Yolo,
            asyncEnabled: false
        )).value().getOrThrow()
        runLsp(product, root + "/workspace")
        runDebug(product, root + "/workspace")
        runHub(product, root + "/workspace")
        expect(product.closeMcp().isOk(), "product closes outbound MCP runtime")
        println("direct runtime sandbox contract passed")
        0
    } finally {
        removeVariable("DIRECT_RUNTIME_PARENT_SECRET")
        let _ = removeIfExists(root, recursive: true)
    }
}

func runFixtureSandboxEnforced(root: String): Unit {
    let product = openProduct(config: ProductConfig(
        settingsRoot: root + "/config",
        stateRoot: root + "/disabled-state",
        workspaceRoot: root + "/workspace",
        fixture: true,
        approvalMode: ApprovalMode.Yolo,
        asyncEnabled: false
    )).value().getOrThrow()
    let protected = requireTool(product.invokeLocalTool(
        SessionId("direct-disabled"),
        "lsp",
        objectValue([
            ValueField("action", textValue("hover")),
            ValueField("file", textValue("sample.resource")),
            ValueField("line", integerValue(1)),
            ValueField("timeout", integerValue(5))
        ])),
        "fixture LSP hover"
    )
    let encoded = encodeAgentValue(protected.output)
    expect(
        encoded.contains("workspace_ro=true") &&
            encoded.contains("ambient_secret_absent=true") &&
            encoded.contains("resources_bounded=true") &&
            !exists(Path(root + "/workspace/lsp-illegal-write")),
        "fixture direct-process runtimes use the same enforced sandbox as production"
    )
    expect(product.closeMcp().isOk(), "fixture product closes")
}

func runLsp(product: ProductRuntime, workspace: String): Unit {
    let result = requireTool(product.invokeLocalTool(
        SessionId("direct-lsp"),
        "lsp",
        objectValue([
            ValueField("action", textValue("hover")),
            ValueField("file", textValue("sample.resource")),
            ValueField("line", integerValue(1)),
            ValueField("timeout", integerValue(10))
        ])
        ),
        "LSP hover"
    )
    let encoded = encodeAgentValue(result.output)
    expect(
        encoded.contains("workspace_ro=true") &&
            encoded.contains("ambient_secret_absent=true") &&
            encoded.contains("resources_bounded=true") &&
            !exists(Path(workspace + "/lsp-illegal-write")),
        "LSP runs read-only with no ambient secret inheritance and finite process resource limits"
    )
}

func runDebug(product: ProductRuntime, workspace: String): Unit {
    let launched = requireTool(product.invokeLocalTool(
        SessionId("direct-debug"),
        "debug",
        objectValue([
            ValueField("action", textValue("launch")),
            ValueField("program", textValue("debug-target")),
            ValueField("adapter", textValue("contract")),
            ValueField("timeout", integerValue(10))
        ])
        ),
        "DAP launch"
    )
    expect(
        encodeAgentValue(launched.output).contains("stopped") &&
            exists(Path(workspace + "/dap-adapter-proof")),
        "DAP adapter and runInTerminal debuggee run in the RW sandbox"
    )
    let output = requireTool(product.invokeLocalTool(
        SessionId("direct-debug"),
        "debug",
        objectValue([ValueField("action", textValue("output"))])
    ), "DAP output")
    let encodedOutput = encodeAgentValue(output.output)
    expect(
        encodedOutput.contains("adapter_ambient_secret_absent=true") &&
            encodedOutput.contains("debuggee_ambient_secret_absent=true") &&
            exists(Path(workspace + "/dap-debuggee-proof")) &&
            !exists(Path("/etc/axyndra-dap-debuggee-proof")),
        "DAP adapter and runInTerminal debuggee inherit no ambient secrets " +
            "and the debuggee remains inside the RW workspace sandbox"
    )
    let _ = requireTool(product.invokeLocalTool(
        SessionId("direct-debug"),
        "debug",
        objectValue([
            ValueField("action", textValue("terminate")),
            ValueField("timeout", integerValue(5))
        ])
        ),
        "DAP terminate"
    )
}

func runHub(product: ProductRuntime, workspace: String): Unit {
    let secret = "direct-runtime-secret-9381"
    let started = requireTool(product.invokeLocalTool(
        SessionId("direct-hub"),
        "hub",
        objectValue([
            ValueField("op", textValue("start")),
            ValueField("name", textValue("sandbox-contract")),
            ValueField("application", textValue("/bin/sh")),
            ValueField("args", listValue([
                textValue("-c"),
                textValue(
                    "printf 'direct-runtime-'; sleep 0.1; " +
                    "printf 'secret-9381\\n'; " +
                    "touch hub-workspace-proof; " +
                    "touch /etc/axyndra-direct-runtime-proof 2>/dev/null || true"
                )
            ])),
            ValueField("secret_env", objectValue([
                ValueField(
                    "APP_TOKEN",
                    textValue("DIRECT_RUNTIME_PARENT_SECRET")
                )
            ])),
            ValueField("pty", boolValue(false)),
            ValueField("network", boolValue(false))
        ])
        ),
        "Hub start"
    )
    expect(
        encodeAgentValue(started.output).contains("sandbox-contract"),
        "Hub starts the sandboxed process"
    )
    sleep(Duration.millisecond * 300)
    let logs = requireTool(product.invokeLocalTool(
        SessionId("direct-hub"),
        "hub",
        objectValue([
            ValueField("op", textValue("logs")),
            ValueField("name", textValue("sandbox-contract"))
        ])
        ),
        "Hub logs"
    ).output
    let encodedLogs = encodeAgentValue(logs)
    expect(
        encodedLogs.contains("[REDACTED]") && !encodedLogs.contains(secret) &&
            exists(Path(workspace + "/hub-workspace-proof")) &&
            !exists(Path("/etc/axyndra-direct-runtime-proof")),
        "Hub allows workspace writes, blocks host writes, and redacts split-safe secrets"
    )
    let described = requireTool(product.invokeLocalTool(
        SessionId("direct-hub"),
        "hub",
        objectValue([
            ValueField("op", textValue("describe")),
            ValueField("name", textValue("sandbox-contract"))
        ])
        ),
        "Hub describe"
    ).output
    let encodedDescription = encodeAgentValue(described)
    expect(
        encodedDescription.contains("DIRECT_RUNTIME_PARENT_SECRET") &&
            !encodedDescription.contains(secret),
        "Hub persists only secret source bindings, never resolved values"
    )
}

func prepare(root: String): Unit {
    let workspace = root + "/workspace"
    let settings = root + "/config"
    Directory.create(workspace + "/.omp", recursive: true)
    Directory.create(settings, recursive: true)
    let lsp = workspace + "/fake_lsp.py"
    let dap = workspace + "/fake_dap.py"
    File.writeTo(lsp, File.readFrom("fixtures/fake_lsp.py"))
    File.writeTo(dap, File.readFrom("fixtures/fake_dap.py"))
    File.writeTo(workspace + "/sample.resource", "resource\n".toArray())
    File.writeTo(workspace + "/debug-target", "debug\n".toArray())
    File.writeTo(
        workspace + "/lsp.json",
        ("{\"servers\":{\"contract\":{" +
            "\"command\":\"/usr/bin/python3\"," +
            "\"args\":[\"" + lsp + "\"]," +
            "\"fileTypes\":[\".resource\"]," +
            "\"languageId\":\"resource\"," +
            "\"rootMarkers\":[\".\"]}}}").toArray()
    )
    File.writeTo(
        workspace + "/.omp/dap.json",
        ("{\"adapters\":{\"contract\":{" +
            "\"command\":\"/usr/bin/python3\"," +
            "\"args\":[\"" + dap + "\"]," +
            "\"fileTypes\":[\".contract\"]," +
            "\"launchDefaults\":{\"stopOnEntry\":true}," +
            "\"attachDefaults\":{}}}}").toArray()
    )
    File.writeTo(
        settings + "/config.yml",
        "default_model: local/product-contract\nasync:\n  enabled: false\n".toArray()
    )
    File.writeTo(
        settings + "/models.yml",
        ("models:\n" +
            "  - id: product-contract\n" +
            "    provider: local\n" +
            "    context_window: 200000\n" +
            "    max_output_tokens: 8192\n" +
            "    thinking:\n" +
            "      mode: none\n").toArray()
    )
    File.writeTo(
        settings + "/providers.yml",
        ("providers:\n" +
            "  - id: local\n" +
            "    provider: custom\n" +
            "    protocol: completions\n" +
            "    dialect: generic_chat\n" +
            "    base_url: http://127.0.0.1:11434\n" +
            "    api_key_env: DIRECT_RUNTIME_UNUSED_PROVIDER_KEY\n").toArray()
    )
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}

func requireTool(result: Result<ToolResult>, operation: String): ToolResult {
    match (result) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(
            operation + " failed: " + error.describe()
        )
    }
}
