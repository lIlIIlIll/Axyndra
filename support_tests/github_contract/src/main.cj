package github_contract

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_ports.*
import agent_product.*
import std.collection.*
import std.fs.*
import tool_runtime.*

main(): Int64 {
    if (!exists(Path("target"))) {
        Directory.create("target", recursive: true)
    }
    let root = Directory.createTemp("target").toString()
    try {
        verifySchema(root)
        verifyRealCommandMapping(root)
        println("github contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func verifySchema(root: String): Unit {
    let product = openProduct(config: ProductConfig(
        settingsRoot: root + "/settings",
        stateRoot: root + "/state",
        workspaceRoot: root,
        fixture: true,
        approvalMode: ApprovalMode.Yolo,
        asyncEnabled: false
    )).value().getOrThrow()
    let definition = toolDefinition(product, "github")
    expect(
        sameStringSet(propertyNames(definition.inputSchema), [
            "op", "repo", "branch", "path", "pr", "force",
            "forceWithLease", "title", "body", "base", "head",
            "draft", "fill", "reviewer", "assignee", "label",
            "query", "since", "until", "dateField", "limit", "run",
            "tail"
        ]) &&
        sameStringSet(requiredNames(definition.inputSchema), ["op"]) &&
        sameStringSet(enumNames(
            definition.inputSchema.field("properties").getOrThrow()
                .field("op").getOrThrow()
        ), [
            "repo_view", "file_read", "pr_create", "pr_checkout",
            "pr_push", "search_issues", "search_prs", "search_code",
            "search_commits", "search_repos", "run_watch"
        ]),
        "github exposes the reviewed root schema and operation union"
    )
    let pr = definition.inputSchema.field("properties").getOrThrow()
        .field("pr").getOrThrow()
    expect(
        pr.field("anyOf").getOrThrow().items.size == 2,
        "github pr accepts one string or a string list"
    )
}

func verifyRealCommandMapping(root: String): Unit {
    let workspace = LocalWorkspace(root)
    let processes = RecordingGithubProcessPort()
    let runtime = ProductGithubRuntime(
        processes,
        ghExecutable: "/bin/echo",
        gitExecutable: "/bin/echo"
    )
    let context = ToolInvocationContext(
        RunId("github-run"),
        SessionId("github-session"),
        CapabilitySet(values: [
            Capability(CapabilityKind.NetworkAccess),
            Capability(CapabilityKind.WorkspaceWrite)
        ])
    )
    let viewed = invoke(runtime, context, call(
        "view",
        "repo_view",
        [
            ValueField("repo", textValue("acme/demo")),
            ValueField("branch", textValue("main"))
        ]
    ))
    expect(
        viewed.output.field("content").getOrThrow().text
            .startsWith("repo view acme/demo --branch main --json "),
        "repo_view executes the real gh repo view command"
    )
    let read = invoke(runtime, context, call(
        "read",
        "file_read",
        [
            ValueField("repo", textValue("acme/demo")),
            ValueField("branch", textValue("main")),
            ValueField("path", textValue("docs/guide.md"))
        ]
    ))
    expect(
        read.output.field("content").getOrThrow().text ==
            "api repos/acme/demo/contents/docs/guide.md?ref=main " +
                "-H Accept: application/vnd.github.raw+json",
        "file_read uses the GitHub contents API with a raw media type"
    )
    let created = invoke(runtime, context, call(
        "create",
        "pr_create",
        [
            ValueField("repo", textValue("acme/demo")),
            ValueField("title", textValue("Ship it")),
            ValueField("body", textValue("Validated")),
            ValueField("base", textValue("main")),
            ValueField("head", textValue("feature")),
            ValueField("draft", boolValue(true)),
            ValueField("reviewer", listValue([
                textValue("alice"), textValue("bob")
            ]))
        ]
    ))
    let createText = created.output.field("content").getOrThrow().text
    expect(
        createText.contains("pr create") &&
        createText.contains("--repo acme/demo") &&
        createText.contains("--title Ship it") &&
        createText.contains("--draft") &&
        createText.contains("--reviewer alice") &&
        createText.contains("--reviewer bob"),
        "pr_create maps all side-effecting options to gh"
    )
    let checkouts = invoke(runtime, context, ToolCall(
        "checkout",
        "github",
        objectValue([
            ValueField("op", textValue("pr_checkout")),
            ValueField("repo", textValue("acme/demo")),
            ValueField("pr", listValue([
                textValue("12"), textValue("feature")
            ])),
            ValueField("force", boolValue(true))
        ])
    ))
    expect(
        checkouts.output.field("targets").getOrThrow().items.size == 2 &&
        checkouts.output.field("content").getOrThrow().text
            .contains("pr checkout 12 --repo acme/demo --force") &&
        checkouts.output.field("content").getOrThrow().text
            .contains("pr checkout feature --repo acme/demo --force"),
        "pr_checkout executes every requested PR target"
    )
    let pushed = invoke(runtime, context, call(
        "push",
        "pr_push",
        [
            ValueField("branch", textValue("feature")),
            ValueField("forceWithLease", boolValue(true))
        ]
    ))
    expect(
        pushed.output.field("content").getOrThrow().text ==
            "-c credential.helper=!/bin/echo auth git-credential push " +
                "--force-with-lease --set-upstream origin feature",
        "pr_push uses git push with explicit force-with-lease"
    )
    let searched = invoke(runtime, context, call(
        "search",
        "search_issues",
        [
            ValueField("repo", textValue("acme/demo")),
            ValueField("query", textValue("bug")),
            ValueField("since", textValue("2026-01-01")),
            ValueField("until", textValue("2026-07-31")),
            ValueField("dateField", textValue("updated")),
            ValueField("limit", integerValue(5))
        ]
    ))
    let searchText = searched.output.field("content").getOrThrow().text
    expect(
        searchText.contains(
            "search issues bug updated:>=2026-01-01 " +
                "updated:<=2026-07-31"
        ) &&
        searchText.contains("--repo acme/demo --limit 5 --json"),
        "GitHub search applies repository, date and result bounds"
    )
    let watched = invoke(runtime, context, call(
        "watch",
        "run_watch",
        [
            ValueField("repo", textValue("acme/demo")),
            ValueField("run", textValue("123"))
        ]
    ))
    expect(
        watched.output.field("content").getOrThrow().text ==
            "run watch 123 --exit-status --repo acme/demo",
        "run_watch invokes the blocking Actions watch command"
    )
    expect(
        runtime.execute(
            context,
            call(
                "escape",
                "file_read",
                [
                    ValueField("repo", textValue("acme/demo")),
                    ValueField("path", textValue("../secret"))
                ]
            )
        ).isError() &&
        runtime.execute(
            context,
            call("missing-pr", "pr_checkout", [])
        ).isError(),
        "GitHub paths and required PR targets fail closed"
    )
    expect(
        processes.requests.size > 0 &&
            requestsHaveNetwork(processes.requests.toArray()) &&
            requestMode(processes.requests.toArray(), "github-checkout") ==
                ProcessSandboxMode.WorkspaceReadWrite &&
            requestMode(processes.requests.toArray(), "github-push") ==
                ProcessSandboxMode.WorkspaceReadWrite &&
            requestMode(processes.requests.toArray(), "github-view") ==
                ProcessSandboxMode.WorkspaceReadOnly &&
            requestsScopeGithubSecrets(processes.requests.toArray()),
        "GitHub process requests always use network, scope auth secrets, and grant writes only to checkout/push"
    )
    let failing = ProductGithubRuntime(
        RecordingGithubProcessPort(exitCode: 1),
        ghExecutable: "/bin/false",
        gitExecutable: "/bin/false"
    )
    expect(
        failing.execute(
            context,
            call("failure", "repo_view", [])
        ).isError(),
        "non-zero GitHub commands propagate a real tool failure"
    )
}

class RecordingGithubProcessPort <: ProcessPort {
    public let requests = ArrayList<ProcessRequest>()
    private let exitCode: Int64

    init(exitCode!: Int64 = 0) {
        this.exitCode = exitCode
    }

    public func execute(request: ProcessRequest): Result<ProcessResult> {
        requests.add(request)
        Result.Ok(ProcessResult(
            exitCode,
            stdout: if (exitCode == 0) {
                joinArguments(request.arguments) + "\n"
            } else {
                ""
            },
            stderr: if (exitCode == 0) { "" } else { "command failed" }
        ))
    }

    public func cancel(operationId: OperationId): Result<Unit> {
        let _ = operationId
        Result.Ok(())
    }
}

func joinArguments(arguments: Array<String>): String {
    var value = ""
    for (argument in arguments) {
        if (value != "") { value += " " }
        value += argument
    }
    value
}

func requestsHaveNetwork(requests: Array<ProcessRequest>): Bool {
    for (request in requests where !request.networkAccess) { return false }
    true
}

func requestMode(
    requests: Array<ProcessRequest>,
    operationId: String
): ProcessSandboxMode {
    for (request in requests where request.operationId.value == operationId) {
        return request.sandboxMode
    }
    ProcessSandboxMode.Host
}

func requestsScopeGithubSecrets(requests: Array<ProcessRequest>): Bool {
    for (request in requests) {
        if (!containsArgument(request.secretEnvironmentAllowlist, "GH_TOKEN") ||
            !containsArgument(request.secretEnvironmentAllowlist, "GITHUB_TOKEN")) {
            return false
        }
    }
    true
}

func containsArgument(values: Array<String>, expected: String): Bool {
    for (value in values where value == expected) { return true }
    false
}

func invoke(
    runtime: ProductGithubRuntime,
    context: ToolInvocationContext,
    call: ToolCall
): ToolResult {
    runtime.execute(context, call).value().getOrThrow()
}

func call(
    id: String,
    op: String,
    fields: Array<ValueField>
): ToolCall {
    let values = ArrayList<ValueField>()
    values.add(ValueField("op", textValue(op)))
    values.add(all: fields)
    ToolCall(id, "github", objectValue(values.toArray()))
}

func toolDefinition(
    product: ProductRuntime,
    name: String
): ModelToolDefinition {
    for (definition in product.tools() where definition.name == name) {
        return definition
    }
    throw IllegalStateException("missing product tool: " + name)
}

func propertyNames(schema: AgentValue): Array<String> {
    let names = ArrayList<String>()
    for (field in schema.field("properties").getOrThrow().fields) {
        names.add(field.name)
    }
    names.toArray()
}

func requiredNames(schema: AgentValue): Array<String> {
    let names = ArrayList<String>()
    for (value in schema.field("required").getOrThrow().items) {
        names.add(value.text)
    }
    names.toArray()
}

func enumNames(schema: AgentValue): Array<String> {
    let names = ArrayList<String>()
    for (value in schema.field("enum").getOrThrow().items) {
        names.add(value.text)
    }
    names.toArray()
}

func sameStringSet(left: Array<String>, right: Array<String>): Bool {
    if (left.size != right.size) { return false }
    for (candidate in left) {
        var found = false
        for (expected in right) {
            if (candidate == expected) { found = true; break }
        }
        if (!found) { return false }
    }
    true
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
